#!/usr/bin/env bash
set -euo pipefail

PULL_TIMEOUT="${PULL_TIMEOUT:-120s}"
WUD_URL="${WUD_URL:-http://127.0.0.1:3002/api/containers}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }; }
need docker
need timeout
need curl
need python3

# Colors (tput, fallback empty if not a tty)
if [[ -t 1 ]]; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; GRAY="$(tput setaf 8 2>/dev/null || true)"
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; GRAY=""; BOLD=""; RESET=""
fi

# Spinner: runs while a PID is alive
spinner() {
  local pid="$1"
  local msg="$2"
  local spin='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r[%c] %s" "${spin:$i:1}" "$msg"
    sleep 0.12
  done
}

echo "=== Docker Update Check ==="
echo "Timeout per pull: $PULL_TIMEOUT"
echo

mapfile -t CIDS < <(docker ps -aq)
[[ ${#CIDS[@]} -eq 0 ]] && { echo "Keine Container."; exit 0; }

declare -A REF_BY_CID=()
declare -A NAME_BY_CID=()
declare -A STATE_BY_CID=()
declare -A CURRID_BY_CID=()
declare -A COMPOSE_DIR_BY_CID=()
declare -A COMPOSE_SVC_BY_CID=()
declare -A WUD_WATCH_BY_CID=()

for cid in "${CIDS[@]}"; do
  NAME_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Name}}' | sed 's#^/##')"
  STATE_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.State.Status}}')"
  REF_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Config.Image}}')"   # desired repo:tag
  CURRID_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Image}}')"      # current image id
  COMPOSE_DIR_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  COMPOSE_SVC_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
  WUD_WATCH_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{ index .Config.Labels "wud.watch" }}' 2>/dev/null || true)"
done

# ------------------------------------------------------------
# WUD Update-Informationen laden
# ------------------------------------------------------------

declare -A WUD_PRESENT_BY_NAME=()
declare -A WUD_UPDATE_BY_NAME=()
declare -A WUD_KIND_BY_NAME=()
declare -A WUD_LOCAL_BY_NAME=()
declare -A WUD_TARGET_BY_NAME=()

WUD_OK=0

if WUD_TSV="$(
  curl -fsS --max-time 10 "$WUD_URL" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)

for c in data:
    name = c.get("name")
    if not name:
        continue

    available = c.get("updateAvailable")

    if available is True:
        state = "true"
    elif available is False:
        state = "false"
    else:
        state = "unknown"

    kind_data = c.get("updateKind") or {}
    result = c.get("result") or {}
    image = c.get("image") or {}
    tag = image.get("tag") or {}

    kind = kind_data.get("kind") or "-"
    local = kind_data.get("localValue") or tag.get("value") or "-"

    if available is True:
        if kind == "tag":
            target = (
                result.get("tag")
                or kind_data.get("remoteValue")
                or "-"
            )

        elif kind == "digest":
            digest = (
                result.get("digest")
                or kind_data.get("remoteValue")
            )

            if digest:
                target = "Digest " + digest.replace("sha256:", "")[:12]
            else:
                target = "neuer Digest"

        else:
            target = (
                result.get("tag")
                or kind_data.get("remoteValue")
                or result.get("digest")
                or "Update"
            )
    else:
        target = "-"

    print(
        f"{name}\t{state}\t{kind}\t{local}\t{target}"
    )
'
)"; then

  WUD_OK=1

  while IFS=$'\t' read -r name state kind local target; do
    [[ -z "$name" ]] && continue

    WUD_PRESENT_BY_NAME["$name"]=1
    WUD_UPDATE_BY_NAME["$name"]="$state"
    WUD_KIND_BY_NAME["$name"]="$kind"
    WUD_LOCAL_BY_NAME["$name"]="$local"
    WUD_TARGET_BY_NAME["$name"]="$target"
  done <<< "$WUD_TSV"

  echo "${GREEN}WUD API erreichbar${RESET}"
else
  echo "${YELLOW}WARNUNG: WUD API nicht erreichbar – Versionsprüfung eingeschränkt.${RESET}"
fi

echo

declare -A UNIQUE_ALL=()
declare -A UNIQUE=()

for cid in "${CIDS[@]}"; do
  ref="${REF_BY_CID[$cid]}"
  UNIQUE_ALL["$ref"]=1

  # Container mit wud.watch=false nicht gegen Registry prüfen
  if [[ "${WUD_WATCH_BY_CID[$cid],,}" == "false" ]]; then
    continue
  fi

  UNIQUE["$ref"]=1
done

echo "Containers: ${#CIDS[@]} | Unique image refs: ${#UNIQUE_ALL[@]} | Pull checks: ${#UNIQUE[@]}"
echo

declare -A LATEST_ID=()
declare -A PULL_RES=()   # ok/fail

total="${#UNIQUE[@]}"
idx=0

for ref in "${!UNIQUE[@]}"; do
  idx=$((idx+1))
  [[ -z "$ref" ]] && { echo "($idx/$total) <EMPTY REF> -> skip"; continue; }

  tmp_out="$(mktemp)"
  ( timeout "$PULL_TIMEOUT" docker pull "$ref" >"$tmp_out" 2>&1 ) &
  pull_pid=$!

  spinner "$pull_pid" "($idx/$total) pulling $ref"
  wait "$pull_pid" || true
  printf "\r\033[K"

  if [[ -s "$tmp_out" ]] && grep -qiE "Downloaded newer image|Pull complete|Status:" "$tmp_out"; then
    PULL_RES["$ref"]="ok"
    LATEST_ID["$ref"]="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null || echo "")"

    if grep -qi "Downloaded newer image" "$tmp_out"; then
      echo "($idx/$total) $ref  -> ${GREEN}ok${RESET} (newer downloaded)"
    else
      echo "($idx/$total) $ref  -> ${GREEN}ok${RESET}"
    fi
  else
    PULL_RES["$ref"]="fail"
    LATEST_ID["$ref"]=""
    echo "($idx/$total) $ref  -> ${RED}FAIL${RESET} (timeout/auth/registry)"
    tail -n 1 "$tmp_out" | sed 's/^/    /' || true
  fi

  rm -f "$tmp_out"
done

echo
echo "=== Result per container ==="

COLS="$(tput cols 2>/dev/null || echo 148)"

W_NAME=20
W_STATE=8
W_IMAGE=30
W_UPD=34
W_SVC=12
W_PATH=$(( COLS - (W_NAME + 1) - (W_STATE + 1) - (W_IMAGE + 1) - (W_UPD + 1) - (W_SVC + 1) ))
(( W_PATH < 30 )) && W_PATH=30

printf "%-${W_NAME}s %-${W_STATE}s %-${W_IMAGE}s %-${W_UPD}s %-${W_PATH}s %-${W_SVC}s\n" \
  "NAME" "STATE" "IMAGE(ref)" "UPDATE?" "COMPOSE_DIR" "SERVICE"
printf "%*s\n" "$COLS" "" | tr ' ' '-'

updates=0
unknown=0
ignored=0

for cid in "${CIDS[@]}"; do
  name="${NAME_BY_CID[$cid]}"
  state="${STATE_BY_CID[$cid]}"
  ref="${REF_BY_CID[$cid]}"
  curr="${CURRID_BY_CID[$cid]}"
  latest="${LATEST_ID[$ref]:-}"
  cdir="${COMPOSE_DIR_BY_CID[$cid]:-}"
  csvc="${COMPOSE_SVC_BY_CID[$cid]:-}"

  [[ -z "$cdir" ]] && cdir="-"
  [[ -z "$csvc" ]] && csvc="-"

    verdict="unknown"
  update_target=""

  # 1. Bewusst ausgeschlossen
  if [[ "${WUD_WATCH_BY_CID[$cid]:-}" == "false" ]]; then
    verdict="ignored"
    ignored=$((ignored+1))

  # 2. WUD kennt ein echtes Versionsupdate
  elif [[ "${WUD_PRESENT_BY_NAME[$name]:-0}" == "1" &&
          "${WUD_UPDATE_BY_NAME[$name]:-unknown}" == "true" ]]; then

    verdict="update"
    update_target="${WUD_TARGET_BY_NAME[$name]:-}"
    updates=$((updates+1))

  # 3. docker pull konnte nicht geprüft werden
  elif [[ "${PULL_RES[$ref]:-fail}" != "ok" || -z "$latest" ]]; then
    verdict="unknown"
    unknown=$((unknown+1))

  # 4. Gleicher Tag, aber neues Image dahinter
  elif [[ "$curr" != "$latest" ]]; then
    verdict="update"
    update_target="neuer Digest"
    updates=$((updates+1))

  # 5. Wirklich aktuell
  else
    verdict="no"
  fi

  # verdict text + color
    case "$verdict" in
    no)
      verdict_text="${GREEN}Aktuell${RESET}"
      ;;

    update)
      if [[ -n "$update_target" ]]; then
        verdict_text="${YELLOW}Update -> $update_target${RESET}"
      else
        verdict_text="${YELLOW}Update${RESET}"
      fi
      ;;

    ignored)
      verdict_text="${BLUE}Ignoriert${RESET}"
      ;;

    unknown)
      verdict_text="${GRAY}Unbekannt${RESET}"
      ;;

    *)
      verdict_text="$verdict"
      ;;
  esac

  # IMPORTANT: verdict field must NOT be truncated with .W_UPD because it contains ANSI codes
  printf "%-${W_NAME}.${W_NAME}s %-${W_STATE}.${W_STATE}s %-${W_IMAGE}.${W_IMAGE}s " \
    "$name" "$state" "$ref"
  printf "%-${W_UPD}s " "$verdict_text"
  printf "%-${W_PATH}.${W_PATH}s %-${W_SVC}.${W_SVC}s\n" \
    "$cdir" "$csvc"
done

echo
echo "=== Containers that should be updated (recreate) ==="
shown=0
for cid in "${CIDS[@]}"; do
  if [[ "${WUD_WATCH_BY_CID[$cid],,}" == "false" ]]; then
    continue
  fi
  ref="${REF_BY_CID[$cid]}"
  curr="${CURRID_BY_CID[$cid]}"
  latest="${LATEST_ID[$ref]:-}"

  if [[ "${PULL_RES[$ref]:-fail}" == "ok" && -n "$latest" && "$curr" != "$latest" ]]; then
    name="${NAME_BY_CID[$cid]}"
    cdir="${COMPOSE_DIR_BY_CID[$cid]:-}"
    csvc="${COMPOSE_SVC_BY_CID[$cid]:-}"

    if [[ -n "$cdir" && -n "$csvc" ]]; then
      echo "- ${YELLOW}$name${RESET} (image: $ref) -> cd \"$cdir\" && docker compose up -d $csvc"
    else
      echo "- ${YELLOW}$name${RESET} (image: $ref) -> (kein Compose-Path/Service gefunden)"
    fi
    shown=1
  fi
done
[[ $shown -eq 0 ]] && echo "Keine."

echo
echo "Summary: update needed=${YELLOW}${updates}${RESET} | ignored=${BLUE}${ignored}${RESET} | unknown=${GRAY}${unknown}${RESET}"
echo
echo "Zum updaten (Compose):"
echo "  cd COMPOSE_DIR"
echo "  docker compose pull"
echo "  docker compose up -d"
echo "  docker compose ps"
