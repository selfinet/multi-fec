#!/bin/bash
# run.sh — 1.4.1-v5 3모드(duplicate·aggregate·failover) 실터널 (2026-10-23, 테스트망 전용)
# 구성: c·s vCPU 4 + virtio 큐 4(10-23 Proxmox 변경), r1·rs2 2 vCPU. 시간 동기 4대 모두 chrony(s 기준).
# 모드마다: 제한 없는 계단 10~60 Mbps(60초) + 15 Mbps 경로 절단(cut1=rs2, cut0=r) ×2.
# 시험 동안만 c·s multipath-mode 변경(원본 *.bak-3modes-2026-10-23). 끝나면(중단돼도) duplicate 원복 + 4대 .v1.4.0.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
V=${V:-1.4.1-v5}; MODES=${MODES:-"duplicate aggregate failover"}; RATES=${RATES:-"10 20 30 40 50 60"}
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 15; }
setmode() { local mode=$1; for h in "$C client" "$S server"; do set -- $h
  ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.bak-3modes-2026-10-23 ] || cp \$f \$f.bak-3modes-2026-10-23; sed -i 's/^multipath-mode = .*/multipath-mode = $mode/' \$f; grep multipath \$f"; done; }
fin() { echo "[$(date +%T)] ===== 정리 · duplicate 원복 · 1.4.0 복원"
  for h in "$C client" "$S server"; do set -- $h
    ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.bak-3modes-2026-10-23 ] && cp \$f.bak-3modes-2026-10-23 \$f; grep multipath \$f"; done
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'; }
trap fin EXIT
for m in $MODES; do
  echo "[$(date +%T)] ##### mode=$m v$V"
  setmode $m >/dev/null; setall $V
  ssh $C "journalctl -u multi-fec@client --since '-40s' --no-pager | grep -o 'client mode started (multipath=[a-z-]*)' | tail -1"
  for r in $RATES; do
    out=$(RUNID=st_${m}_$r RATES=$r REPS=1 DUR=60 GAP=1 SCEN=steady ./tunnel_regress.sh 2>&1)
    echo "$out" | grep -E '^\[run\] steady|트립|기동 실패' | sed "s/^/  [$m] /"
    echo "$out" | grep -q '트립\|기동 실패' && { echo "  [$m] $r Mbps 에서 중단"; break; }
  done
  out=$(RUNID=cut_$m RATES=15 REPS=2 DUR=60 CUT_AT=20 UP_AT=45 GAP=3 SCEN="cut1 cut0" ./tunnel_regress.sh 2>&1)
  echo "$out" | grep -E '^\[run\] cut|트립|기동 실패' | sed "s/^/  [$m] /"
done
echo "[$(date +%T)] 3MODES_DONE"
