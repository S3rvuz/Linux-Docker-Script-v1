#!/bin/bash

echo "=============================="
echo " DOCKER + NAMESPACES OVERVIEW"
echo "=============================="
echo

echo "---- Docker running containers ----"
docker ps
echo

echo "---- All Docker containers ----"
docker ps -a
echo

echo "---- Docker images ----"
docker images
echo

echo "---- Docker networks ----"
docker network ls
echo

echo "---- Docker volumes ----"
docker volume ls
echo


echo "=============================="
echo " LINUX NAMESPACES"
echo "=============================="
echo

echo "---- Active namespaces ----"
sudo lsns
echo

echo "---- Network namespaces ----"
ip netns list
echo


echo "=============================="
echo " CGROUPS (v2)"
echo "=============================="
echo

echo "---- Existing cgroups ----"
ls /sys/fs/cgroup
echo

echo "---- CPU limits ----"
find /sys/fs/cgroup -name cpu.max 2>/dev/null | while read file
do
    echo "$file -> $(cat $file)"
done
echo


echo "=============================="
echo " SYSTEM INFO"
echo "=============================="

echo "CPU cores:"
nproc
echo

echo "Memory:"
free -h
echo

echo "Load:"
uptime
echo

echo "=============================="
echo " DONE"
echo "=============================="
