#!/bin/bash

docker ps -a  --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

COUNT=$(docker ps -q | wc -l)

echo "=================================================================>
echo "Aktive Docker Container: $COUNT"
echo " "

echo "Mögliche Updates (1)"

read WAHL
if [ "$WAHL" -eq 1 ]; then
	echo "hallo"
else
	echo "tot"
fi 
