#!/bin/bash
# tagchk.sh — 하향 경로 태그 수정(server 1.4.1-v3) 실터널 회귀 확인 (2026-10-23, 테스트망 전용)
#   c=.v1.4.1-v2(같은 기반) · s=.v1.4.1-v3 — server 차이만 본다. r 무변경. 끝나면(중단돼도) c·s 1.4.0 복원
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; S=root@192.168.100.102
put() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$2 /usr/sbin/multi-fec-dist && systemctl restart $3"; }
restore() { echo "[$(date +%T)] ===== 1.4.0 복원"; put $S 1.4.0 multi-fec@server; put $C 1.4.0 multi-fec@client; sleep 15
  for h in $C $S; do ssh $h 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@server 2>/dev/null | tr "\n" " ")"'; done; }
trap restore EXIT
put $S 1.4.1-v3 multi-fec@server; put $C 1.4.1-v2 multi-fec@client
for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
echo "  설치 c=$(ssh $C 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12') s=$(ssh $S 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12')"; sleep 20
RUNID=tag_st RATES="15 20" REPS=1 DUR=90 SCEN=steady ./tunnel_regress.sh | grep -E '^\[run\]|트립|기동 실패' || exit 3
RUNID=tag_cut RATES=15 REPS=1 DUR=90 SCEN="cut1 cut0" ./tunnel_regress.sh | grep -E '^\[run\]|트립|기동 실패' || exit 3
echo "[$(date +%T)] TAGCHK_DONE"
