#!/bin/bash
# agg.sh — aggregate 모드 실터널 1.4.0 vs 1.4.1-v3 (2026-10-23, 테스트망 전용, 4대)
# 시험 동안만 c·s instances/*.conf 의 multipath-mode 를 aggregate 로 바꾼다(원본 *.bak-agg-2026-10-23).
# 버전마다 tunnel_regress.sh 10 Mbps 60초 steady·cut1(rs2)·cut0(r) × REPS.
# 끝나면(중단돼도) 설정 원복(duplicate) + 4대 .v1.4.0 복원.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
REPS=${REPS:-2}; VERS=${VERS:-"1.4.0 1.4.1-v3"}
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 15; }
fin() { echo "[$(date +%T)] ===== 정리 · duplicate 원복 · 1.4.0 복원"
  ssh $C 'f=/etc/multi-fec/instances/client.conf; [ -f $f.bak-agg-2026-10-23 ] && cp $f.bak-agg-2026-10-23 $f; grep multipath $f'
  ssh $S 'f=/etc/multi-fec/instances/server.conf; [ -f $f.bak-agg-2026-10-23 ] && cp $f.bak-agg-2026-10-23 $f; grep multipath $f'
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'; }
trap fin EXIT
ssh $C 'f=/etc/multi-fec/instances/client.conf; cp $f $f.bak-agg-2026-10-23; sed -i "s/^multipath-mode = duplicate/multipath-mode = aggregate/" $f; grep multipath $f'
ssh $S 'f=/etc/multi-fec/instances/server.conf; cp $f $f.bak-agg-2026-10-23; sed -i "s/^multipath-mode = duplicate/multipath-mode = aggregate/" $f; grep multipath $f'
for rep in $(seq 1 $REPS); do for v in $VERS; do
  echo "[$(date +%T)] ##### aggregate v$v rep$rep"; setall $v
  ssh $C 'journalctl -u multi-fec@client --since "-30s" --no-pager | grep -o "multipath[^ ]*mode[^,]*" | tail -1'
  RUNID=agg_${v//[.-]/}_$rep RATES=10 REPS=1 DUR=60 CUT_AT=20 UP_AT=45 SCEN="steady cut1 cut0" ./tunnel_regress.sh | grep -E '^\[run\] (steady|cut)|트립|기동 실패' || exit 3
done; done
echo "[$(date +%T)] AGG_DONE"
