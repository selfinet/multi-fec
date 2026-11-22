#!/bin/bash
# run57 — 30세션 aging 전 설정 고르기: worker 3개(rps 8, 터널 1개)에서 -P 30, 상·하향 각 2회, nr(무제한 무손실).
#   A = 기본(--win-mult 2) · B = A + --pend-fifo · C = A + --pend-fifo --win-unlimited. dist mt.2 10b361ea (bd216ec).
# 2026-11-23 사용자 "그대로 진행해줘". 선택: 처리량 최고, 5 % 이내면 재전송 적은 쪽.
RUN=r57; RAW=raw57
cd "$(dirname "$0")"; . ./lib.sh
echo "== setup $(date +%T)"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; (setsid timeout 7200 ip netns exec hq iperf3 -s > iperf_hq_${RUN}.log 2>&1 < /dev/null &)"
env_up

# 변형 정의 — 바꿀 곳
start() { local v=$1 kind=$2 XA pair; stopall; setrps 8; route 1
  case $kind in A) XA="";; B) XA="--pend-fifo";; C) XA="--pend-fifo --win-unlimited";; esac
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; setsid timeout 1500 ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 $XA > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 10
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c multi-fec-dist)+\$(pgrep -c mmulti-fec-dist) cpus \$(for p in \$(pgrep -f 'multi-fec-dist'); do taskset -pc \$p | awk '{print \$NF}'; done | paste -sd,)\""; }
variant() { local v=$1 kind=$2
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  run ${v}_p30_up 30 ""; run ${v}_p30_dn 30 "-R"; run ${v}_p30_up2 30 ""; run ${v}_p30_dn2 30 "-R"
  logsum $v; }

setnet 0 0
for k in A B C; do variant nr_$k $k; done
stopall
rget
echo "done $(date +%T)"
