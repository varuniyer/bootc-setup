#!/bin/sh
printf '\\set %s %s\n' "$1" "'$(sed "s/'/''/g")'"
