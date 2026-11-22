#!/bin/bash
# run56 — worker 3개(mmulti --workers 3 --worker-cpus 0,1,2, rps 8, 터널 1개 = run48 mt 구성)에서 d2(옵션 없음 = --win-mult 2) vs d1(--win-mult 1). dist 3c965d14.
# 2026-11-23 사용자 "worker 3개로 d2/d1 비교 시험 진행해줘". 질문: 2배 송신 창의 상향 이득이 worker 3개에서도 있는가. 참고 run48 mtbase -P1 상 223·186 / -P8 상 292·256.
RUN=r56; RAW=raw56
cd "$(dirname "$0")"; . ./lib.sh
echo "== setup $(date +%T)"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; (setsid timeout 7200 ip netns exec hq iperf3 -s > iperf_hq_${RUN}.log 2>&1 < /dev/null &)"
env_up

# 변형 정의 — 바꿀 곳
start() { local v=$1 kind=$2 XA pair; stopall; setrps 8; route 1
  case $kind in d2) XA="";; d1) XA="--win-mult 1";; esac
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; setsid timeout 1500 ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 $XA > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 10
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c multi-fec-dist)+\$(pgrep -c mmulti-fec-dist) cpus \$(for p in \$(pgrep -f 'multi-fec-dist'); do taskset -pc \$p | awk '{print \$NF}'; done | paste -sd,)\""; }
variant() { local v=$1 kind=$2
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  run ${v}_p1_up 1 ""; run ${v}_p1_dn 1 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  logsum $v; }

V="d2 d1"
setnet 0 0
for r in 1 2 3; do for k in $V; do variant nr_${k}_$r $k; done; done
setnet 0 1
echo "-- 하부 ping (속도 제한 후)"
rsh $C 'for a in 172.31.10.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'
for r in 1 2 3; do for k in $V; do variant nl_${k}_$r $k; done; done
stopall
rget
echo "done $(date +%T)"
