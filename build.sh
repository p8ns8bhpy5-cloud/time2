#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ "$#" -eq 0 ]; then
    set -- rootless
elif [ "$#" -eq 1 ] && [ "$1" = all ]; then
    set -- rootful rootless roothide
fi

: "${THEOS:?Set THEOS first}"
for scheme in "$@"; do
    package_scheme="$scheme"
    if [ "$scheme" = rootful ]; then package_scheme=""; fi
    printf '\nBuilding %s\n' "$scheme"
    make clean THEOS_PACKAGE_SCHEME="$package_scheme"
    make package THEOS_PACKAGE_SCHEME="$package_scheme"
done
