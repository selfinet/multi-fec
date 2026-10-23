#!/bin/bash
# run.sh — 경로별 속도 제한 계단 (2026-10-23, 테스트망 전용, 사용자 승인)
# r(path[0])·rs2(path[1]) netem 에 경로당 각 방향 RATE(기본 30mbit, 대기열 300 패킷)를 시험 동안만 건다.
# 그 위에서 ladder.sh(1.4.1-v4, duplicate·aggregate 10~40 Mbps). 끝나면(중단돼도) netem.conf.bak-ratelimit 복원·재적용.
set -u
cd "$(dirname "$0")"
R=root@192.168.100.88; R2=root@192.168.100.131; C=root@192.168.100.92
RATE=${RATE:-30mbit}
restore() { echo "[$(date +%T)] ===== netem 원복"
  for h in $R $R2; do ssh $h 'cp /etc/multi-fec/netem.conf.bak-ratelimit /etc/multi-fec/netem.conf && systemctl restart mf-netem && journalctl -u mf-netem -n 3 --no-pager | grep "mf-netem:" | tail -1'; done
  ssh $C 'ping -c 20 -i 0.2 -q 10.9.20.1 | tail -1'; }
trap restore EXIT
for h in $R $R2; do ssh $h "grep -q '^P0_RATE=' /etc/multi-fec/netem.conf || echo 'P0_RATE=$RATE   # 2026-10-23 속도 제한 시험 — 끝나면 .bak-ratelimit 로 원복' >> /etc/multi-fec/netem.conf; systemctl restart mf-netem; journalctl -u mf-netem -n 3 --no-pager | grep 'mf-netem:' | tail -1; tc qdisc show dev ens18 | grep 'netem 10:'; tc qdisc show dev ifb0 | grep 'netem 10:'"; done
V=1.4.1-v4 MODES="duplicate aggregate" RATES="${RATES:-10 15 20 25 30 35 40}" ./ladder.sh
echo "[$(date +%T)] RATELIMIT_DONE"
