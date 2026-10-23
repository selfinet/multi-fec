#!/bin/bash
cd "$(dirname "$0")"
./mix8.sh > mix8.out 2>&1
./soak.sh > soak.out 2>&1
echo ALL_DONE >> soak.out
