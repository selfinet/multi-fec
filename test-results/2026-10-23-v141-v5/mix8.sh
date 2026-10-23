#!/bin/bash
# mix8.sh — 1.4.0 ↔ 1.4.1-v3(fix/dup-path-tag) 혼용 (2026-10-23, 테스트망 전용, 4대: c · r+rs2 · s)
# 조합마다 해당 호스트만 .v<버전> 으로 install → 재시작, tunnel_regress.sh(4대용)로 10 Mbps 60초 steady·cut1(rs2)·cut0(r).
#   relay 는 r·rs2 를 같은 버전으로 묶는다. 영향: 교체마다 터널 1초 안팎 끊김. 되돌리기: 끝나면(중단돼도) 4대 .v1.4.0 복원
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
A=1.4.0; B=${B:-1.4.1-v5}
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
restore() {
  echo "[$(date +%T)] ===== 1.4.0 복원"
  inst $S multi-fec@server $A; inst $R multi-fec@relay $A; inst $R2 multi-fec@relay $A; inst $C multi-fec@client $A
  sleep 8
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'
}
[ "${NO_RESTORE:-0}" = 1 ] || trap restore EXIT
for cv in $A $B; do for rv in $A $B; do for sv in $A $B; do
  tag=c${cv//[.-]/}_r${rv//[.-]/}_s${sv//[.-]/}
  echo "[$(date +%T)] ##### c=$cv relay=$rv s=$sv"
  inst $S multi-fec@server $sv; inst $R multi-fec@relay $rv; inst $R2 multi-fec@relay $rv; inst $C multi-fec@client $cv
  ok=0; for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
  echo "  터널 $([ $ok = 1 ] && echo 정상 || echo 불통)  sha c/r/rs2/s $(for h in $C $R $R2 $S; do ssh $h 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-8'; done | tr '\n' ' ')"
  [ $ok = 1 ] || continue
  sleep 15
  RUNID=$tag RATES=10 REPS=1 DUR=60 CUT_AT=20 UP_AT=45 SCEN="steady cut1 cut0" ./tunnel_regress.sh | grep -E '^\[run\] (steady|cut)|트립|기동 실패' || exit 3
done; done; done
echo "[$(date +%T)] MIX_DONE"
