#!/bin/bash
# 18 런 종료를 PID 로 기다렸다가 다중 세션 소크를 이어서 띄운다.
set -u
O=/home/stevekim/multi-fec/test-results/2026-08-31-postfix-recheck
M=/home/stevekim/multi-fec/test-results/2026-09-02-multisession
P18=$(cat $O/run18.pid 2>/dev/null || echo 0)
while [ "$P18" != 0 ] && kill -0 "$P18" 2>/dev/null; do sleep 20; done
echo "[$(date '+%H:%M:%S')] 18 런 종료 확인 — 60초 안정화 후 다중 세션 시작"
sleep 60
setsid bash -c "echo \$\$ > $M/run_multi.pid; exec env N=4 MBPS=4 SECS=3600 OUT=$M/raw $M/mf_multi_soak.sh" > $M/run_multi.log 2>&1 &
sleep 5
PM=$(cat $M/run_multi.pid 2>/dev/null || echo 0)
echo "[$(date '+%H:%M:%S')] 다중 세션 pid=$PM"
while [ "$PM" != 0 ] && kill -0 "$PM" 2>/dev/null; do sleep 20; done
echo "[$(date '+%H:%M:%S')] 다중 세션 종료"
