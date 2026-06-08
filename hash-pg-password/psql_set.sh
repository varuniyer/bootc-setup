#!/bin/sh
escaped=$(cat | sed "s/'/''/g")
printf "\\\\set %s '%s'\n" "$1" "$escaped"
