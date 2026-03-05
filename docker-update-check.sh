#!/usr/bin/env bash
set -euo pipefail

PULL_TIMEOUT="${PULL_TIMEOUT:-120s}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }; }
need docker
need timeout

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
    # Compose metadata (falls Container via docker compose erstellt wurde)
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

  # run pull in background so spinner can animate
  tmp_out="$(mktemp)"
  ( timeout "$PULL_TIMEOUT" docker pull "$ref" >"$tmp_out" 2>&1 ) &
  pull_pid=$!

  spinner "$pull_pid" "($idx/$total) pulling $ref"
  wait "$pull_pid" || true

  # clear spinner line
  printf "\r\033[K"

  if [[ -s "$tmp_out" ]] && grep -qiE "Downloaded newer image|Pull complete|Status:" "$tmp_out"; then
    # pull finished (success or at least produced normal output)
    if grep -qi "Downloaded newer image" "$tmp_out"; then
      PULL_RES["$ref"]="ok"
      LATEST_ID["$ref"]="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null || true)"
      echo "($idx/$total) $ref  -> ok (newer downloaded)"
    else
      # could be "Image is up to date" or normal status lines
      PULL_RES["$ref"]="ok"
      LATEST_ID["$ref"]="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null || true)"
      echo "($idx/$total) $ref  -> ok"
    fi
  else
    # timeout or auth/registry error
    PULL_RES["$ref"]="fail"
    LATEST_ID["$ref"]=""
    echo "($idx/$total) $ref  -> FAIL (timeout/auth/registry)"
    # optional: show last line for quick clue
    tail -n 1 "$tmp_out" | sed 's/^/    /' || true
  fi

  rm -f "$tmp_out"
done

echo
echo "=== Result per container ==="
printf "%-22s %-10s %-28s %-16s %-45s %-18s\n" "NAME" "STATE" "IMAGE(ref)" "UPDATE?" "COMPOSE_DIR" "SERVICE"
echo "-------------------------------------------------------------------------------------------------------------------------------"

updates=0
unknown=0

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

for cid in "${CIDS[@]}"; do
  name="${NAME_BY_CID[$cid]}"
  state="${STATE_BY_CID[$cid]}"
  ref="${REF_BY_CID[$cid]}"
  curr="${CURRID_BY_CID[$cid]}"
  latest="${LATEST_ID[$ref]:-}"
  cdir="${COMPOSE_DIR_BY_CID[$cid]}"
  csvc="${COMPOSE_SVC_BY_CID[$cid]}"

  [[ -z "$cdir" ]] && cdir="-"
  [[ -z "$csvc" ]] && csvc="-"


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

# erst die festen Spalten
  printf "%-22s %-10s %-28s %-16s %-45s %-18s\n" \
    "${name:0:22}" "${state:0:10}" "${ref:0:28}" "$status_text" "${cdir:0:45}" "${csvc:0:18}"
# dann verdict farbig (und sauber interpretiert)
case "$verdict" in
  no)      printf "%b\n" "${GREEN}Aktuell${RESET}" ;;
  update)  printf "%b\n" "${YELLOW}Update verfügbar${RESET}" ;;
  unknown) printf "%b\n" "${GRAY}Umbekannt${RESET}" ;;
  fail)    printf "%b\n" "${RED}Fehler${RESET}" ;;
  *)       printf "%s\n" "$verdict" ;;
esac

done

echo
cdir="${COMPOSE_DIR_BY_CID[$cid]}"
csvc="${COMPOSE_SVC_BY_CID[$cid]}"

if [[ -n "$cdir" && -n "$csvc" ]]; then
  echo "- ${NAME_BY_CID[$cid]}  (image: $ref)  -> cd \"$cdir\" && docker compose up -d $csvc"
else
  echo "- ${NAME_BY_CID[$cid]}  (image: $ref)  -> (kein Compose-Path/Service gefunden)"
fi
  shown=1
done
[[ $shown -eq 0 ]] && echo "Keine."

echo
echo "Summary: update needed=$updates | unknown=$unknown"
echo
echo "Summary: update needed=$updates | unknown=$unknown"
