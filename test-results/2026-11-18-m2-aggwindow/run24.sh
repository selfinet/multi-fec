#!/bin/bash
# 속도 특별 버전 ① — 다중 인스턴스 + 코어 분산 (1.4.5 dist, 2026-11-19 사용자 지시 "다중 인스턴스 측정 진행해 줘").
# 구성 run8 그대로: .92 netns ue(10.88.1.10) → ECMP rq-wg/2/3 → .93 netns hq(10.90.0.10). 쌍 k: client :5180(1+k) / server :44(3+k).
# 경로 30/54 ms(enp4s0/enp1s0), 손실 0, aggregate. hash policy 1.
# 변형(양쪽 같은 값):
#   n1pin  터널 1  pin 0        rps e   (run23 기준 ~112)
#   n2pin  터널 2  pin 0,1      rps c
#   n3pin  터널 3  pin 0,1,2    rps 8
#   n3free 터널 3  pin 없음     rps 0   (run8 과 같은 방식, 1.4.4 152~189)
# 각 변형: TCP -P 24 상·하, -P 8 상·하, 30 s. 순서 ×2.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
BIN=$HOME/multi-fec/dist/multi-fec-dist-v1.4.5
cd "$(dirname "$0")"; mkdir -p raw24
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J $BIN $h:/root/rq/multi-fec-dist.v145
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo "$(hostname) $(md5sum multi-fec-dist.v145 | cut -c1-12) $(./multi-fec-dist.v145 --version | sed -n 2p)"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq24.log 2>&1 < /dev/null &)'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)\""; done; }
trap restore EXIT

start() { local v=$1 n=$2 pins=$3
  read -ra P <<< "$pins"
  for pair in "$S server" "$C client"; do set -- $pair
    cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
    for k in $(seq 0 $((n-1))); do pc=""; [ -n "${P[$k]:-}" ] && pc="--pin-cpu ${P[$k]}"
      cmd="$cmd; setsid timeout 1200 ./multi-fec-dist.v145 --config /root/rq/${2}_P$k.conf $pc > ${2}_P${k}_r24_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
    ssh $J $1 "$cmd"; done
  sleep 10
  ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; for k in \$(seq 0 $((n-1))); do echo -n \"P\$k \$(taskset -pc \$(pgrep -P \$(cat /root/rq/client_P\$k.pid)) | awk '{print \$NF}') \"; done; echo; cat /sys/class/net/lo/queues/rx-0/rps_cpus"; }

CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > r24_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw24/iperf_$name.txt 2>&1
  sleep 3
  a=$(ssh $J $C "$CNT")
  rx=$(grep receiver raw24/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw24/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r24_${name}_mpstat.txt"; echo -n "/ "; done)
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]} if(t==0)t=1;
    printf "%.0f/%.0f/%.0f", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}')
  echo "  $name recv $rx | retr $rt | share $sh | idle c/s $idle"; sleep 4; }

variant() { local v=$1 n=$2 pins=$3 mask=$4
  echo "== $v (터널 $n, pin '${pins:-없음}', rps $mask) $(date +%T)"
  setrps $mask; route $n; start $v $n "$pins"
  run ${v}_p24_up 24 ""; run ${v}_p24_dn 24 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  ssh $J $C "cd /root/rq; for k in \$(seq 0 $((n-1))); do echo -n \"  P\$k EAGAIN=\$(grep -c EAGAIN client_P\${k}_r24_$v.log) pin=\$(grep -o 'pinned to CPU [0-9]*' client_P\${k}_r24_$v.log | head -1 | awk '{print \$NF}') \"; done; echo"; }

for r in 1 2; do
  variant n1pin_$r  1 "0"     e
  variant n2pin_$r  2 "0 1"   c
  variant n3pin_$r  3 "0 1 2" 8
  variant n3free_$r 3 ""      0
done
for h in $C $S; do mkdir -p raw24/${h##*.}; scp -q $J "$h:/root/rq/r24_*" "$h:/root/rq/*_r24_*" raw24/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
