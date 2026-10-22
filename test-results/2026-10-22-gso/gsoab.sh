#!/bin/bash
# gsoab.sh — perf(1.5-perf) vs UDP GSO·GRO 프로토타입(1.5-gso) 실터널 A/B (2026-10-22, 테스트망 전용)
#   c·s 만 교체(r 은 1.4.0 그대로). 가드는 하위 스크립트가 각자 선기동(GW_NET=new).
#   rep1: steady 15·20 + 절단(cut1·cut0) 15 + strace 15 + mpstat 15 / rep2: steady 15·20
#   끝나면(중단돼도) c·s .v1.4.0 복원
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; S=root@192.168.100.102
setver() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@server"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@client"
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
  echo "  설치 c=$(ssh $C 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12') s=$(ssh $S 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12')"; sleep 20
}
restore() { echo "[$(date +%T)] ===== 1.4.0 복원"; setver 1.4.0; for h in $C $S; do ssh $h 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@server 2>/dev/null | tr "\n" " ")"'; done; }
trap restore EXIT
sub() { # dir script — 하위 하네스를 버전별 디렉터리에서 돌린다(G 경로 한 단계 깊게)
  mkdir -p "$1"; cp "$2" "$1/"; sed -i 's#^G=../2026-08-02-50mbps-soak#G=../../2026-08-02-50mbps-soak#' "$1/$2"
  (cd "$1" && ./"$2" | tail -4)
}
for rep in 1 2; do for v in 1.5-perf 1.5-gso; do
  t=${v//[.-]/}
  echo "[$(date +%T)] ##### rep$rep v$v"; setver $v
  RUNID=st_${t}_$rep RATES="15 20" REPS=1 DUR=90 SCEN=steady ./tunnel_regress.sh | grep -E '^\[run\] steady|트립|기동 실패' || exit 3
  if [ $rep = 1 ]; then
    RUNID=cut_${t}_$rep RATES=15 REPS=1 DUR=90 SCEN="cut1 cut0" ./tunnel_regress.sh | grep -E '^\[run\] cut|트립|기동 실패' || exit 3
    sub st_$t strace_run.sh
    sub mp_$t mpstat_run.sh
  fi
done; done
echo "[$(date +%T)] GSOAB_DONE"
