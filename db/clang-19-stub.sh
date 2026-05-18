#!/bin/sh
# Stub clang-19 for pgxs JIT bitcode step.
# pg_cron is a background worker; .bc JIT files are never loaded at runtime.
# Scan args for -o <output>, create an empty file there, exit 0.
NEXT=0
for arg in "$@"; do
    if [ "$NEXT" = "1" ]; then
        touch "$arg"
        NEXT=0
    elif [ "$arg" = "-o" ]; then
        NEXT=1
    fi
done
