#!/bin/bash
# ab3.sh — 실터널 3버전 A/B (2026-10-22, 테스트망 전용): 1.4.0 · 1.4.1(A안, multi-fec-00) · 1.4.1-v2(fix/mud-rate-agg)
# 회차마다 세 버전을 번갈아 3대에 깔고 tunnel_regress.sh(multi-fec-00 작성, 무수정)를 15·20 Mbps 로 돌린다.
#   작업: /usr/sbin/multi-fec-dist 를 .v<버전> 사본으로 install → multi-fec@* 재시작 (server → relay → client)
#   영향: 테스트망 터널이 교체마다 1초 안팎 끊김. 가드는 tunnel_regress.sh 가 띄운다.
#   되돌리기: 끝나면(중단돼도) .v1.4.0 으로 복원·재시작
set -u
cd "$(dirname "$0")"
REPS=${REPS:-3}
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
setver() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@relay multi-fec@relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@client"
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
  for h in $C $R $S; do ssh "$h" 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12'; done | sort | uniq -c | tr '\n' ' '; echo
  sleep 20
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
  for v in 1.4.0 1.4.1 1.4.1-v2; do
    echo "[$(date +%T)] ##### rep$rep v$v"; setver $v
    RUNID=ab3_v${v//[.-]/}_$rep RATES="${RATES:-15 20}" REPS=1 ./tunnel_regress.sh | grep -E '^\[run\] (steady|cut|가드)|트립' || exit 3
  done
done
echo "[$(date +%T)] AB3_DONE"
