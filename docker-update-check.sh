#!/usr/bin/env bash
set -euo pipefail

PULL_TIMEOUT="${PULL_TIMEOUT:-120s}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }; }
need docker
need timeout

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

for cid in "${CIDS[@]}"; do
  NAME_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Name}}' | sed 's#^/##')"
  STATE_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.State.Status}}')"
  REF_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Config.Image}}')"   # desired repo:tag
  CURRID_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{.Image}}')"      # current image id
  COMPOSE_DIR_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  COMPOSE_SVC_BY_CID["$cid"]="$(docker inspect "$cid" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
done

declare -A UNIQUE=()
for cid in "${CIDS[@]}"; do
  UNIQUE["${REF_BY_CID[$cid]}"]=1
done

echo "Containers: ${#CIDS[@]} | Unique image refs: ${#UNIQUE[@]}"
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
W_UPD=16
W_SVC=12
W_PATH=$(( COLS - (W_NAME + 1) - (W_STATE + 1) - (W_IMAGE + 1) - (W_UPD + 1) - (W_SVC + 1) ))
(( W_PATH < 30 )) && W_PATH=30

printf "%-${W_NAME}s %-${W_STATE}s %-${W_IMAGE}s %-${W_UPD}s %-${W_PATH}s %-${W_SVC}s\n" \
  "NAME" "STATE" "IMAGE(ref)" "UPDATE?" "COMPOSE_DIR" "SERVICE"
printf "%*s\n" "$COLS" "" | tr ' ' '-'

updates=0
unknown=0

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
  if [[ "${PULL_RES[$ref]:-fail}" != "ok" || -z "$latest" ]]; then
    verdict="unknown"
    unknown=$((unknown+1))
  else
    if [[ "$curr" == "$latest" ]]; then
      verdict="no"
    else
      verdict="update"
      updates=$((updates+1))
    fi
  fi

  # verdict text + color
  case "$verdict" in
    no)      verdict_text="${GREEN}Aktuell${RESET}" ;;
    update)  verdict_text="${YELLOW}Update${RESET}" ;;
    unknown) verdict_text="${GRAY}Unbekannt${RESET}" ;;
    *)       verdict_text="$verdict" ;;
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
echo "Summary: update needed=${YELLOW}${updates}${RESET} | unknown=${GRAY}${unknown}${RESET}"
echo
echo "Zum updaten (Compose):"
echo "  cd COMPOSE_DIR"
echo "  docker compose pull"
echo "  docker compose up -d"
echo "  docker compose ps"
