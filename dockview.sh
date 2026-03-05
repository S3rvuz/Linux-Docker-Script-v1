#!/usr/bin/env bash
set -euo pipefail

# Simple output helpers
hr() { printf "\n%s\n" "----------------------------------------"; }
h1() { printf "\n%s\n" "=== $1 ==="; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehlt: $1 (bitte installieren)" >&2
    exit 1
  }
}

need docker
need awk
need sed
need grep

# Optional tools (if missing, we degrade gracefully)
HAS_LSNS=0; command -v lsns >/dev/null 2>&1 && HAS_LSNS=1
HAS_IP=0;   command -v ip   >/dev/null 2>&1 && HAS_IP=1

h1 "SUMMARY"
echo "Host: $(hostname)  | CPUs: $(nproc) | RAM: $(free -h | awk '/Mem:/ {print $2 " total, " $3 " used, " $4 " free"}')"
echo "Docker running: $(docker ps -q | wc -l)  | Docker all: $(docker ps -aq | wc -l)"
echo "Networks: $(docker network ls -q | wc -l) | Volumes: $(docker volume ls -q | wc -l)"

hr
h1 "DOCKER: RUNNING CONTAINERS (compact)"
# ID, Name, Image, Status, Ports
docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

hr
h1 "DOCKER: CONTAINER -> PID / NETNS / CGROUP (admin view)"
printf "%-16s %-18s %-22s %-8s %-14s %s\n" "CONTAINER" "NAME" "IMAGE" "PID" "NETNS" "CGROUP"
echo "---------------------------------------------------------------------------------------------------------------"

# Iterate running containers only
while read -r cid; do
  name=$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')
  image=$(docker inspect -f '{{.Config.Image}}' "$cid")
  pid=$(docker inspect -f '{{.State.Pid}}' "$cid")

  netns="n/a"
  if [[ -e "/proc/$pid/ns/net" ]]; then
    # inode of netns
    netns=$(readlink "/proc/$pid/ns/net" | sed 's/.*\[\([0-9]\+\)\].*/\1/')
  fi

  cgrp="n/a"
  if [[ -e "/proc/$pid/cgroup" ]]; then
    # cgroup v2 unified path in field 3, e.g. 0::/system.slice/docker-....scope
    cgrp=$(awk -F: '($1==0){print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
  fi

  printf "%-16s %-18s %-22s %-8s %-14s %s\n" "${cid:0:12}" "${name:0:18}" "${image:0:22}" "$pid" "$netns" "$cgrp"
done < <(docker ps -q)

hr
h1 "DOCKER: NETWORKS"
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'

hr
h1 "DOCKER: VOLUMES (count + first 15)"
count=$(docker volume ls -q | wc -l)
echo "Volumes total: $count"
docker volume ls -q | head -n 15 | sed 's/^/ - /'

hr
h1 "NAMESPACES: ONLY RELEVANT (docker / unshare)"
if [[ $HAS_LSNS -eq 1 ]]; then
  # Show only net/pid/mnt/uts for processes matching docker/containerd/unshare
  # (keeps output short)
  sudo lsns -o NS,TYPE,NPROCS,PID,USER,COMMAND 2>/dev/null | \
    awk 'NR==1 || $6 ~ /(docker|containerd|unshare)/' | \
    awk '$2 ~ /(net|pid|mnt|uts)/ || NR==1'
else
  echo "lsns nicht vorhanden."
fi

hr
h1 "CGROUPS (v2): CUSTOM LIMITS ONLY"
# Show only cpu.max that are NOT default "max 100000" and skip noisy mounts/scopes
if [[ -d /sys/fs/cgroup ]]; then
  # Find cpu.max, filter meaningful changes, and skip systemd mount units
  while IFS= read -r f; do
    val=$(cat "$f" 2>/dev/null || true)
    # Show only if not default unlimited (max 100000) and not empty
    if [[ -n "$val" && "$val" != "max 100000" ]]; then
      # Keep it readable: shorten long paths
      short=${f#/sys/fs/cgroup/}
      printf "%-70s -> %s\n" "$short" "$val"
    fi
  done < <(find /sys/fs/cgroup -name cpu.max 2>/dev/null | grep -v '\.mount/' | grep -v 'session-' | sort)
else
  echo "/sys/fs/cgroup nicht gefunden."
fi

hr
h1 "DONE"
