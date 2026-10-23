#!/bin/bash
# ladder.sh — duplicate vs aggregate 최대 처리량 계단 (2026-10-23, 테스트망 전용, 4대 rs2 구성, 1.4.1-v3)
# 모드마다 WG 위 mfgen 양방향 RATES 계단, 단계당 60초 steady. 가드(GW_NET=new) 트립 → 그 모드 중단.
# aggregate 는 시험 동안만 c·s instances/*.conf multipath-mode 변경(원본 *.bak-aggwin-2026-10-23).
# 끝나면(중단돼도) duplicate 원복 + 4대 .v1.4.0 복원.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
V=${V:-1.4.1-v3}; RATES=${RATES:-"10 15 20 25 30 35 40"}; MODES=${MODES:-"duplicate aggregate"}
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 15; }
setmode() { local mode=$1; for h in "$C client" "$S server"; do set -- $h
  ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.bak-aggwin-2026-10-23 ] || cp \$f \$f.bak-aggwin-2026-10-23; sed -i 's/^multipath-mode = .*/multipath-mode = $mode/' \$f; grep multipath \$f" ; done; }
fin() { echo "[$(date +%T)] ===== 정리 · duplicate 원복 · 1.4.0 복원"
  for h in "$C client" "$S server"; do set -- $h
    ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.bak-aggwin-2026-10-23 ] && cp \$f.bak-aggwin-2026-10-23 \$f; grep multipath \$f"; done
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'; }
trap fin EXIT
for m in $MODES; do
  echo "[$(date +%T)] ##### mode=$m v$V"
  setmode $m; setall $V
  for r in $RATES; do
    out=$(RUNID=lad_${m}_$r RATES=$r REPS=1 DUR=60 GAP=1 SCEN=steady ./tunnel_regress.sh 2>&1)
    echo "$out" | grep -E '^\[run\] steady|트립|기동 실패' | sed "s/^/  [$m $r] /"
    if echo "$out" | grep -q '트립\|기동 실패'; then echo "  [$m] $r Mbps 에서 중단"; grep 트립 raw/lad_${m}_$r/guard.log | tail -1; break; fi
  done
done
echo "[$(date +%T)] LADDER_DONE"
