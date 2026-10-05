#!/bin/bash
# ab_run.sh <RUNID> — nstat 스냅샷 → run_load.sh (20/25 Mbps × 540s) → nstat 스냅샷
set -u
ID=$1; D=/home/stevekim/multi-fec/test-results/2026-10-05-vm-guard-calib
snap() { for h in 92 88 102; do echo "## .$h"; ssh root@192.168.100.$h 'nstat -az UdpInDatagrams UdpRcvbufErrors UdpSndbufErrors | tail -3'; done; }
mkdir -p $D/raw/$ID
snap > $D/raw/$ID/nstat_before.txt 2>&1
ssh root@192.168.100.92 'journalctl -u multi-fec-client -n 6 --no-pager | grep "path\["' > $D/raw/$ID/client_paths_before.txt 2>&1
cd $D && RUNID=$ID STEPS="20 25" DUR=540 ./run_load.sh > raw/$ID.out 2>&1
echo "rc=$?" >> raw/$ID.out
snap > $D/raw/$ID/nstat_after.txt 2>&1
