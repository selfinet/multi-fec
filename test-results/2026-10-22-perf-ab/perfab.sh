#!/bin/bash
# perfab.sh — 1.4.1-v2 vs 1.5-perf (MSG_PEEK 제거 + WG sendmmsg) 실터널 CPU·시스템 호출 (2026-10-22, 테스트망 전용)
#   c·s 만 교체(r 은 1.4.0). CPU: tunnel_regress.sh steady 15·20 Mbps(hostsamp mf_cpu) — strace 없이.
#   시스템 호출: strace_run.sh 15 Mbps. 끝나면(중단돼도) c·s .v1.4.0 복원
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
for rep in 1 2; do for v in 1.4.1-v2 1.5-perf; do
  echo "[$(date +%T)] ##### rep$rep v$v"; setver $v
  RUNID=cpu_${v//[.-]/}_$rep RATES="15 20" REPS=1 DUR=90 SCEN=steady ./tunnel_regress.sh | grep -E '^\[run\] steady|트립|기동 실패' || exit 3
  if [ $rep = 1 ]; then mkdir -p st_${v//[.-]/}; (cd st_${v//[.-]/} && cp ../strace_run.sh . && sed -i 's#^G=../2026-08-02-50mbps-soak#G=../../2026-08-02-50mbps-soak#' strace_run.sh && ./strace_run.sh | tail -4); fi
done; done
echo "[$(date +%T)] PERFAB_DONE"
