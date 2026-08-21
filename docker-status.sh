#!/usr/bin/env bash
set -u

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

declare -A WEB_URLS=(
  ["nextcloud-app-1"]="https://marvincloud.duckdns.org"
  ["grafana"]="https://grafana.marvincloud.duckdns.org"
  ["grafana-logs"]="https://logs.marvincloud.duckdns.org"
  ["adguard"]="https://adguard.marvincloud.duckdns.org"
  ["dashy"]="https://dashy.marvincloud.duckdns.org"
  ["vaultwarden"]="https://vaultwarden.marvincloud.duckdns.org"
)

die() {
  printf '%sFehler:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "Docker wurde nicht gefunden."
docker info >/dev/null 2>&1 || die "Docker ist nicht erreichbar. Prüfe den Docker-Dienst und deine Berechtigungen."

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-127.0.0.1}"

status_label() {
  case "$1" in
    running) printf '%sONLINE%s' "$GREEN" "$RESET" ;;
    exited|dead) printf '%sOFFLINE%s' "$RED" "$RESET" ;;
    paused) printf '%sPAUSIERT%s' "$YELLOW" "$RESET" ;;
    restarting) printf '%sNEUSTART%s' "$YELLOW" "$RESET" ;;
    created) printf '%sERSTELLT%s' "$BLUE" "$RESET" ;;
    removing) printf '%sWIRD ENTFERNT%s' "$YELLOW" "$RESET" ;;
    *) printf '%s%s%s' "$YELLOW" "${1^^}" "$RESET" ;;
  esac
}

port_urls() {
  local container="$1" bindings line host_ip host_port container_port

  if [[ -n "${WEB_URLS[$container]:-}" ]]; then
    printf '    Web:       %s\n' "${WEB_URLS[$container]}"
  fi

  bindings="$(docker port "$container" 2>/dev/null || true)"
  [[ -z "$bindings" ]] && return 0

  while IFS= read -r line; do
    container_port="${line%%/*}"
    host_ip="$(sed -E 's/^.* -> (\[[^]]+\]|[^:]+):([0-9]+)$/\1/' <<< "$line")"
    host_port="$(sed -E 's/^.* -> (\[[^]]+\]|[^:]+):([0-9]+)$/\2/' <<< "$line")"
    [[ "$host_port" =~ ^[0-9]+$ ]] || continue

    case "$host_ip" in
      0.0.0.0|"::"|"[::]") host_ip="$HOST_IP" ;;
      127.0.0.1) ;;
      *) host_ip="${host_ip#[}"; host_ip="${host_ip%]}" ;;
    esac

    case "$container_port" in
      443|8443) printf '    Lokal:     https://%s:%s\n' "$host_ip" "$host_port" ;;
      80|3000|3001|3100|4000|4001|5000|5601|8000|8080|8081|8090|8096|8123|9000|9090)
        printf '    Lokal:     http://%s:%s\n' "$host_ip" "$host_port"
        ;;
    esac
  done <<< "$bindings"
}

print_commands() {
  cat <<CMDS

${BOLD}${CYAN}Verfügbare Befehle${RESET}

Container starten:
  docker start CONTAINERNAME

Container stoppen:
  docker stop CONTAINERNAME

Container neu starten:
  docker restart CONTAINERNAME

${DIM}CONTAINERNAME durch den Namen aus der Übersicht ersetzen.${RESET}
CMDS
}

clear 2>/dev/null || true
printf '%s%sDocker-Containerübersicht%s\n' "$BOLD" "$CYAN" "$RESET"
printf 'Host: %s | Zeit: %s\n' "$(hostname)" "$(date '+%d.%m.%Y %H:%M:%S')"
printf 'LAN-IP: %s\n\n' "$HOST_IP"

mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' | sort)

if (( ${#CONTAINERS[@]} == 0 )); then
  printf '%sKeine Docker-Container gefunden.%s\n' "$YELLOW" "$RESET"
  print_commands
  exit 0
fi

online=0; offline=0; other=0

for name in "${CONTAINERS[@]}"; do
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || printf 'unknown')"
  image="$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || printf 'unbekannt')"
  status_text="$(docker ps -a --filter "name=^/${name}$" --format '{{.Status}}')"
  ports="$(docker ps -a --filter "name=^/${name}$" --format '{{.Ports}}')"

  case "$state" in
    running) ((online+=1)) ;;
    exited|dead) ((offline+=1)) ;;
    *) ((other+=1)) ;;
  esac

  printf '%s%s%s  [%s]\n' "$BOLD" "$name" "$RESET" "$(status_label "$state")"
  printf '    Image:     %s\n' "$image"
  printf '    Status:    %s\n' "${status_text:-unbekannt}"
  printf '    Ports:     %s\n' "${ports:-keine veröffentlichten Ports}"
  port_urls "$name"
  printf '\n'
done

printf '%sZusammenfassung:%s %s%d online%s | %s%d offline%s' "$BOLD" "$RESET" "$GREEN" "$online" "$RESET" "$RED" "$offline" "$RESET"
if (( other > 0 )); then
  printf ' | %s%d sonstige%s' "$YELLOW" "$other" "$RESET"
fi
printf '\n'

print_commands
