#!/bin/bash
# 속도 특별 버전 ③ UDP GSO/GRO A/B — spd1(1.4.5-speed.1) vs spd2(1.4.5-speed.2 = + mud GSO 송신·GRO 수신, dist e324110e, 미커밋).
# 터널 1개 pin 0 rps e, ue→hq(run26·27 과 같음), 30/54 ms, 손실 0, aggregate. -P 1·-P 8 상·하 30 s, 교대 ×3.
# 주의: netem 이 회선 송신 쪽에 있어 GSO 덩어리가 쪼개지기 전에 netem 을 지난다(손실 0 이라 버림은 없음).
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw29
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J /home/stevekim/mf-speed/multi-fec-dist $h:/root/rq/multi-fec-dist.spd2
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo "$(hostname) $(md5sum multi-fec-dist.spd1 multi-fec-dist.spd2 | cut -c1-12 | paste -sd" ")"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq24.log 2>&1 < /dev/null &)'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)\""; done; }
trap restore EXIT

start() { local v=$1 n=$2 pins=$3 bin=$4
  read -ra P <<< "$pins"
  for pair in "$S server" "$C client"; do set -- $pair
    cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
    for k in $(seq 0 $((n-1))); do pc=""; [ -n "${P[$k]:-}" ] && pc="--pin-cpu ${P[$k]}"
      cmd="$cmd; setsid timeout 1200 ./multi-fec-dist.$bin --config /root/rq/${2}_P$k.conf $pc > ${2}_P${k}_r29_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
    ssh $J $1 "$cmd"; done
  sleep 10
  ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; for k in \$(seq 0 $((n-1))); do echo -n \"P\$k \$(taskset -pc \$(pgrep -P \$(cat /root/rq/client_P\$k.pid)) | awk '{print \$NF}') \"; done; echo; cat /sys/class/net/lo/queues/rx-0/rps_cpus"; }

CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > r29_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw29/iperf_$name.txt 2>&1
  sleep 3
  a=$(ssh $J $C "$CNT")
  rx=$(grep receiver raw29/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw29/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r29_${name}_mpstat.txt"; echo -n "/ "; done)
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]} if(t==0)t=1;
    printf "%.0f/%.0f/%.0f", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}')
  echo "  $name recv $rx | retr $rt | share $sh | idle c/s $idle"; sleep 4; }

variant() { local v=$1 n=$2 pins=$3 mask=$4 bin=$5
  echo "== $v ($bin, 터널 $n, pin '${pins:-없음}', rps $mask) $(date +%T)"
  setrps $mask; route $n; start $v $n "$pins" $bin
  run ${v}_p1_up 1 ""; run ${v}_p1_dn 1 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  for hh in $C $S; do ssh $J $hh "grep -h '] batch gso' /root/rq/*_P0_r29_$v.log | tail -1 | sed 's/^/  \$(hostname) /'"; done
  ssh $J $C "cd /root/rq; for k in \$(seq 0 $((n-1))); do echo -n \"  P\$k EAGAIN=\$(grep -c EAGAIN client_P\${k}_r29_$v.log) pin=\$(grep -o 'pinned to CPU [0-9]*' client_P\${k}_r29_$v.log | head -1 | awk '{print \$NF}') \"; done; echo"; }

for r in 1 2 3; do
  variant n1spd2_$r 1 "0" e spd2
  variant n1spd1_$r 1 "0" e spd1
done
for h in $C $S; do mkdir -p raw29/${h##*.}; scp -q $J "$h:/root/rq/r29_*" "$h:/root/rq/*_r29_*" raw29/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
