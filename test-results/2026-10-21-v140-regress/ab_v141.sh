#!/bin/bash
# ab_v141.sh — 1.4.1(rate 는 손실 >25% 일 때만 감소) vs 1.4.0 실터널 A/B (2026-10-21, 테스트망 전용)
# ⚠️ 2026-10-23 이후 사용 금지 — path[1] 이 rs2 로 옮겨져 setver 가 rs2 를 교체하지 않는다(기록용으로 둔다).
#
# 회차마다 두 버전을 번갈아 3대에 깔고 tunnel_regress.sh 를 같은 조건으로 돌린다(시간대 편향 제거).
#   작업: /usr/sbin/multi-fec-dist 를 .v1.4.1 / .v1.4.0 사본으로 install → multi-fec@* 재시작 (server → relay → client)
#   영향: 테스트망 터널이 교체마다 1초 안팎 끊김
#   되돌리기: 끝나면(중단돼도) .v1.4.0 으로 복원·재시작 — 서비스망과 같은 상태
#
#   REPS=3 ./ab_v141.sh
set -u
cd "$(dirname "$0")"
REPS=${REPS:-3}
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102

setver() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@relay multi-fec@relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@client"
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
  for h in $C $R $S; do ssh "$h" '/usr/sbin/multi-fec-dist --version | head -1'; done | sort | uniq -c | tr '\n' ' '; echo
  sleep 20                                       # 경로 RUNNING · rate 초기 램프 지나기
}
restore() {
  echo "[$(date +%T)] ===== 1.4.0 복원"
  setver 1.4.0
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@relay-b multi-fec@server 2>/dev/null | tr "\n" " ")"'
  done
}
trap restore EXIT

for rep in $(seq 1 $REPS); do
  for v in 1.4.1 1.4.0; do
    echo "[$(date +%T)] ##### rep$rep v$v"; setver $v
    RUNID=ab_v${v//./}_$rep RATES=20 REPS=1 ./tunnel_regress.sh | grep -E '^\[run\] (steady|cut|가드)|트립' || exit 3
  done
done
echo "[$(date +%T)] ##### v1.4.1 10 Mbps 회귀 확인"; setver 1.4.1
RUNID=ab_v141_10 RATES=10 REPS=1 ./tunnel_regress.sh | grep -E '^\[run\] (steady|cut)|트립'
echo "[$(date +%T)] AB_DONE"
