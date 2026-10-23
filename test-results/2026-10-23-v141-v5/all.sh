#!/bin/bash
# all.sh — 1.4.1-v5(fix/agg-balance) 검증 일괄 (2026-10-23, 테스트망 전용, 사용자 지시)
#   ① 경로별 속도 제한(각 방향 30 Mbps) 계단: aggregate 1.4.0 · v4 · v5×2, duplicate v5
#   ② 제한 없는 계단 30~60: v5 duplicate · aggregate
#   ③ 안정성: 혼용 8조합(1.4.0↔v5) · 재시작 복구 · v5 60분 소크
# 각 단계 하네스가 끝날 때 4대 1.4.0·duplicate 로 복원한다. ① 의 속도 제한은 끝나면(중단돼도) netem.conf.bak-ratelimit 로 원복.
set -u
cd "$(dirname "$0")"
R=root@192.168.100.88; R2=root@192.168.100.131; C=root@192.168.100.92
lad() { # dir V MODES RATES
  mkdir -p "$1"; cp ladder.sh tunnel_regress.sh "$1/"
  sed -i 's#^G=../2026-08-02-50mbps-soak#G=../../2026-08-02-50mbps-soak#' "$1/tunnel_regress.sh"
  (cd "$1" && V=$2 MODES="$3" RATES="$4" ./ladder.sh > ladder.out 2>&1)
  echo "== $1"; grep -E '\[run\]|트립|중단' "$1/ladder.out"
}
netem_restore() { for h in $R $R2; do ssh $h 'cp /etc/multi-fec/netem.conf.bak-ratelimit /etc/multi-fec/netem.conf && systemctl restart mf-netem && journalctl -u mf-netem -n 3 --no-pager | grep "mf-netem:" | tail -1'; done; }
trap netem_restore EXIT
echo "[$(date +%T)] ##### ① 속도 제한 30 Mbps"
for h in $R $R2; do ssh $h "grep -q '^P0_RATE=' /etc/multi-fec/netem.conf || echo 'P0_RATE=30mbit   # 2026-10-23 v5 검증 — 끝나면 .bak-ratelimit 로 원복' >> /etc/multi-fec/netem.conf; systemctl restart mf-netem; tc qdisc show dev ens18 | grep 'netem 10:'"; done
RL="15 20 25 30 35 40"
lad rl_140_agg   1.4.0    aggregate "$RL"
lad rl_v4_agg    1.4.1-v4 aggregate "$RL"
lad rl_v5_agg_1  1.4.1-v5 aggregate "$RL"
lad rl_v5_agg_2  1.4.1-v5 aggregate "$RL"
lad rl_v5_dup    1.4.1-v5 duplicate "$RL"
netem_restore; trap - EXIT
echo "[$(date +%T)] ##### ② 제한 없는 계단"
lad ul_v5 1.4.1-v5 "duplicate aggregate" "30 35 40 50 60"
echo "[$(date +%T)] ##### ③ 안정성"
./mix8.sh > mix8.out 2>&1; echo "== mix8"; grep -E '#####|터널|\[run\]|트립' mix8.out
./restart.sh > restart.out 2>&1; echo "== restart"; grep -E '^\[rst\]|트립' restart.out
./soak.sh > soak.out 2>&1; echo "== soak"; grep -E '\[run\]|트립' soak.out
echo "[$(date +%T)] ALL_DONE"
