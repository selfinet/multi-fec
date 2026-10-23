#!/bin/bash
cd "$(dirname "$0")"
until grep -q ALL_DONE soak.out 2>/dev/null; do sleep 20; done
./restart.sh > restart.out 2>&1
./agg.sh > agg.out 2>&1
echo NEXT_DONE >> agg.out
