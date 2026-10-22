#!/bin/bash
# run_lo.sh — 2500 pps(≈8 Mbps), WAN 지연(A 25ms·B 30ms), B 10초 절단, 3 버전 번갈아 20회
cd /root/aggtest
for i in $(seq 1 20); do
  for b in mf131 mf140 mf141b; do
    o=$(ADELAY=25 BIN=./$b python3 ./tpf_wan.py --single duplicate 0 30 10 2500 100000 2>&1)
    echo "lo-$b run$i | $(echo "$o" | grep -oE "유실 [0-9]+ \([0-9.]+%\)") | $(echo "$o" | grep UDPERR) | eagain $(grep -ac EAGAIN /tmp/mf_cli.log) qfull $(grep -ac "pending queue full" /tmp/mf_cli.log)" | tee -a out/results.txt
  done
done
echo LO_DONE >> out/results.txt
