#!/usr/bin/env bash


# Nur bei interaktiven SSH-Sessions anzeigen
echo "--------------------------------------------------------------------------------------------------------------------------------------------------------"

fastfetch

[[ -z "$SSH_CONNECTION" ]] && return
[[ -z "$PS1" ]] && return

# Nur einmal pro SSH-Session
[[ -n "${HOMESRV_BANNER_SHOWN:-}" ]] && return
export HOMESRV_BANNER_SHOWN=1

# -------- Terminal / Farben --------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RST="$(tput sgr0)"
  RED="$(tput setaf 1)"; GRN="$(tput setaf 2)"; YEL="$(tput setaf 3)"; BLU="$(tput setaf 4)"
else
  BOLD=""; DIM=""; RST=""
  RED=""; GRN=""; YEL=""; BLU=""
fi

# -------- Werte --------
HOST="$(hostname 2>/dev/null || echo "n/a")"
UPTIME="$(uptime -p 2>/dev/null || echo "n/a")"
LOAD="$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null || echo "n/a")"
USERS="$(who 2>/dev/null | wc -l | tr -d ' ')"

# Client-IP (von wo du kommst)
FROM="$(awk '{print $1}' <<<"$SSH_CONNECTION" 2>/dev/null)"
[[ -z "$FROM" ]] && FROM="n/a"

# LAN-IP über Default-Route (robust)
IP_LAN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -z "$IP_LAN" ]] && IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$IP_LAN" ]] && IP_LAN="n/a"

# Disk /
DISK_PCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%",""); print $5}')"
DISK_USED="$(df -h / 2>/dev/null | awk 'NR==2{print $3}')"
DISK_SIZE="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
if [[ -n "$DISK_PCT" && -n "$DISK_USED" && -n "$DISK_SIZE" ]]; then
  DISK_LINE="${DISK_PCT}% (${DISK_USED}/${DISK_SIZE})"
else
  DISK_LINE="n/a"
fi

# Docker Status
DOCKER_STATE="$(systemctl is-active docker 2>/dev/null || echo "n/a")"
DOCKER_LINE="$DOCKER_STATE"
if [[ "$DOCKER_STATE" == "active" ]] && command -v docker >/dev/null 2>&1; then
  RUNNING="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
  TOTAL="$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')"
  DOCKER_LINE="active (${RUNNING}/${TOTAL})"
fi

# Updates pending (ohne apt update)
UPD_LINE="n/a"
if command -v /usr/lib/update-notifier/apt-check >/dev/null 2>&1; then
  APTC="$(/usr/lib/update-notifier/apt-check 2>/dev/null || true)"  # "<updates>;<security>"
  U="$(cut -d';' -f1 <<<"$APTC" 2>/dev/null)"
  S="$(cut -d';' -f2 <<<"$APTC" 2>/dev/null)"
  if [[ "$U" =~ ^[0-9]+$ && "$S" =~ ^[0-9]+$ ]]; then
    if (( U == 0 )); then
      UPD_LINE="${GRN}0${RST}"
    else
      UPD_LINE="${YEL}${U}${RST}"
    fi
    if (( S > 0 )); then
      UPD_LINE="${UPD_LINE} ${RED}(sec: ${S})${RST}"
    else
      UPD_LINE="${UPD_LINE} ${DIM}(sec: 0)${RST}"
    fi
  fi
fi
# -------- Weather: Open-Meteo --------
WEATHER_JSON="$(
  curl -fsS \
    --connect-timeout 2 \
    --max-time 4 \
    'https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.405&current=temperature_2m,weather_code,wind_speed_10m,precipitation&timezone=Europe%2FBerlin' \
    2>/dev/null
)"

WEATHER="n/a"

if [[ -n "$WEATHER_JSON" ]] && command -v jq >/dev/null 2>&1; then
  TEMP="$(jq -r '.current.temperature_2m // "n/a"' <<< "$WEATHER_JSON")"
  WIND="$(jq -r '.current.wind_speed_10m // "n/a"' <<< "$WEATHER_JSON")"
  RAIN="$(jq -r '.current.precipitation // "n/a"' <<< "$WEATHER_JSON")"
  CODE="$(jq -r '.current.weather_code // -1' <<< "$WEATHER_JSON")"

  # WMO-Wettercode → Symbol
  case "$CODE" in
    0)          ICON="☀️" ;;
    1|2)        ICON="🌤️" ;;
    3)          ICON="☁️" ;;
    45|48)      ICON="🌫️" ;;
    51|53|55)   ICON="🌦️" ;;
    56|57)      ICON="🌧️" ;;
    61|63|65)   ICON="🌧️" ;;
    66|67)      ICON="🌧️" ;;
    71|73|75|77) ICON="🌨️" ;;
    80|81|82)   ICON="🌦️" ;;
    85|86)      ICON="🌨️" ;;
    95|96|99)   ICON="⛈️" ;;
    *)          ICON="🌡️" ;;
  esac

  WEATHER="${ICON} ${TEMP} °C, Wind ${WIND} km/h, Niederschlag ${RAIN} mm"
fi

# -------- Output: Status-Kasten --------
echo ""
echo "${BOLD}${BLU}┌─ ${HOST}---------------───────────────────────────────────────────────┐${RST}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "From:"    "${FROM}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "LAN IP:"  "${IP_LAN}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Uptime:"  "${UPTIME}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Load:"    "${LOAD}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Weather:" "${WEATHER}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Users:"   "${USERS}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Disk /:"  "${DISK_LINE}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Docker:"  "${DOCKER_LINE}"
printf "${BOLD}${BLU}│${RST} %-10s %s\n" "Updates:" "${UPD_LINE}"
echo "${BOLD}${BLU}└---------------────────────────────────────────────────────────────────┘${RST}"

# -------- Fastfetch: mit Logo, ohne Dopplungen --------
if command -v fastfetch >/dev/null 2>&1; then
  echo ""
  fastfetch \
    --logo auto \
    --color-keys blue \
    --disable gpu \
    --disable bluetooth \
    --disable sound \
    --disable disk \
    --disable uptime \
    --disable localip \
    --structure "OS:Kernel:CPU:Memory:Shell:Terminal" \
    2>/dev/null
fi

echo ""

