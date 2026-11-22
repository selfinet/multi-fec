#!/bin/bash
# run33 — speed.2 vs speed.1, 터널 3쌍(ECMP) + pin 0,1,2 + rps 8. netem 수신측 IFB(run31 조건). TCP -P 24/-P 8 상·하, 30 s, 2회. 2026-11-19 사용자 지시.
# 지연 값은 같다(enp4s0 src 172.31.10.peer 30 ms · 172.31.11.peer 54 ms, enp1s0 src 172.31.20.peer 54 ms) — 각 방향 지연을 송신 호스트 egress 대신 수신 호스트 ingress 에서 건다.
# 172.31.0.0/16 출발분만 IFB 로 돌린다(다른 주소 트래픽 무영향). 끝나면(trap) IFB 제거 + 원래 egress netem 복원·대조.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw33
echo "== setup $(date +%T)"
for h in $C $S; do
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo "$(hostname) $(md5sum multi-fec-dist.spd1 multi-fec-dist.spd2 | cut -c1-12 | paste -sd" ")"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq24.log 2>&1 < /dev/null &)'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)\""; done; }
NETEM_RESTORE='d=$(cat /root/rq/r30_dst); tc qdisc del dev enp4s0 root 2>/dev/null; tc qdisc del dev enp1s0 root 2>/dev/null
  tc qdisc add dev enp4s0 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev enp4s0 parent 1:1 handle 10: netem limit 20000 delay 30ms
  tc qdisc add dev enp4s0 parent 1:2 handle 20: netem limit 20000 delay 54ms
  tc filter add dev enp4s0 parent 1: protocol ip prio 1 u32 match ip dst 172.31.10.$d/32 flowid 1:1
  tc filter add dev enp4s0 parent 1: protocol ip prio 1 u32 match ip dst 172.31.11.$d/32 flowid 1:2
  tc qdisc add dev enp1s0 root handle 8003: netem limit 20000 delay 54ms
  tc qdisc show dev enp4s0 > /root/rq/r30_tc_after.txt; tc qdisc show dev enp1s0 >> /root/rq/r30_tc_after.txt
  tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r30_tc_after.txt
  if diff -q /root/rq/r30_tc_before.txt /root/rq/r30_tc_after.txt >/dev/null; then echo "$(hostname) netem 복원 일치"; else echo "$(hostname) netem 복원 불일치"; diff /root/rq/r30_tc_before.txt /root/rq/r30_tc_after.txt; fi'
ssh $J $C 'echo 1 > /root/rq/r30_dst'; ssh $J $S 'echo 2 > /root/rq/r30_dst'
IFB_UP='d=$(cat /root/rq/r30_dst); tc qdisc show dev enp4s0 > /root/rq/r31_tc_before.txt; tc qdisc show dev enp1s0 >> /root/rq/r31_tc_before.txt
  tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r31_tc_before.txt
  cp /root/rq/r31_tc_before.txt /root/rq/r30_tc_before.txt
  tc qdisc del dev enp4s0 root; tc qdisc del dev enp1s0 root
  ip link add ifb4 type ifb && ip link set ifb4 up; ip link add ifb1 type ifb && ip link set ifb1 up
  tc qdisc add dev ifb4 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev ifb4 parent 1:1 handle 10: netem limit 20000 delay 30ms
  tc qdisc add dev ifb4 parent 1:2 handle 20: netem limit 20000 delay 54ms
  tc filter add dev ifb4 parent 1: protocol ip prio 1 u32 match ip src 172.31.10.$d/32 flowid 1:1
  tc filter add dev ifb4 parent 1: protocol ip prio 1 u32 match ip src 172.31.11.$d/32 flowid 1:2
  tc qdisc add dev ifb1 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev ifb1 parent 1:1 handle 10: netem limit 20000 delay 54ms
  tc filter add dev ifb1 parent 1: protocol ip prio 1 u32 match ip src 172.31.20.$d/32 flowid 1:1
  tc qdisc add dev enp4s0 handle ffff: ingress
  tc filter add dev enp4s0 parent ffff: protocol ip prio 1 u32 match ip src 172.31.0.0/16 action mirred egress redirect dev ifb4
  tc qdisc add dev enp1s0 handle ffff: ingress
  tc filter add dev enp1s0 parent ffff: protocol ip prio 1 u32 match ip src 172.31.0.0/16 action mirred egress redirect dev ifb1
  echo "$(hostname) IFB: $(tc qdisc show dev ifb4 | grep -c netem)+$(tc qdisc show dev ifb1 | grep -c netem) netem, ingress $(tc qdisc show dev enp4s0 ingress | wc -l)/$(tc qdisc show dev enp1s0 ingress | wc -l), egress root $(tc qdisc show dev enp4s0 | head -1 | cut -c1-30)"'
IFB_DOWN='tc qdisc del dev enp4s0 ingress 2>/dev/null; tc qdisc del dev enp1s0 ingress 2>/dev/null; ip link del ifb4 2>/dev/null; ip link del ifb1 2>/dev/null
  echo "$(hostname) IFB 제거: ifb $(ip -br link show type ifb | wc -l) ingress $(tc qdisc show dev enp4s0 ingress | wc -l)/$(tc qdisc show dev enp1s0 ingress | wc -l)"'
restore2() { restore; for h in $C $S; do ssh $J $h "$IFB_DOWN"; ssh $J $h "$NETEM_RESTORE"; done; }
trap restore2 EXIT
for h in $C $S; do ssh $J $h "$IFB_UP"; done
echo "-- 하부 ping (기대 RTT 60 / 108 ms, run30 전 egress 와 같아야 함)"
ssh $J $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'

start() { local v=$1 n=$2 pins=$3 bin=$4 envp=$5
  read -ra P <<< "$pins"
  for pair in "$S server" "$C client"; do set -- $pair
    cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
    for k in $(seq 0 $((n-1))); do pc=""; [ -n "${P[$k]:-}" ] && pc="--pin-cpu ${P[$k]}"
      cmd="$cmd; $envp setsid timeout 1200 ./multi-fec-dist.$bin --config /root/rq/${2}_P$k.conf $pc > ${2}_P${k}_r33_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
    ssh $J $1 "$cmd"; done
  sleep 10
  ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; for k in \$(seq 0 $((n-1))); do echo -n \"P\$k \$(taskset -pc \$(pgrep -P \$(cat /root/rq/client_P\$k.pid)) | awk '{print \$NF}') \"; done; echo; cat /sys/class/net/lo/queues/rx-0/rps_cpus"; }

CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "nstat -n; ip -s link show enp4s0 | awk 'NR==4{print \$4}' > /root/rq/r33_d0; ip -s link show enp1s0 | awk 'NR==4{print \$4}' >> /root/rq/r33_d0"; done
  for h in $C $S; do ssh $J $h "cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > r33_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw33/iperf_$name.txt 2>&1
  sleep 3
  a=$(ssh $J $C "$CNT")
  drops=$(for h in $C $S; do ssh $J $h "u=\$(nstat -z UdpRcvbufErrors | awk '/Udp/{print \$2}'); n1=\$(ip -s link show enp4s0 | awk 'NR==4{print \$4}'); n2=\$(ip -s link show enp1s0 | awk 'NR==4{print \$4}'); read a0 < /root/rq/r33_d0; b0=\$(sed -n 2p /root/rq/r33_d0); echo -n \"rcvbuf=\$u nicdrop=\$((n1-a0+n2-b0))\""; echo -n " / "; done)
  rx=$(grep receiver raw33/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw33/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r33_${name}_mpstat.txt"; echo -n "/ "; done)
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]} if(t==0)t=1;
    printf "%.0f/%.0f/%.0f", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}')
  echo "  $name recv $rx | retr $rt | share $sh | idle c/s $idle | drops c/s $drops"; sleep 4; }

variant() { local v=$1 n=$2 pins=$3 mask=$4 bin=$5 envp=$6
  echo "== $v ($bin ${envp:-env없음}, 터널 $n, pin '${pins:-없음}', rps $mask) $(date +%T)"
  setrps $mask; route $n; start $v $n "$pins" $bin "$envp"
  run ${v}_p24_up 24 ""; run ${v}_p24_dn 24 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  for hh in $C $S; do ssh $J $hh "grep -h '] batch gso' /root/rq/*_P?_r33_$v.log | tail -1 | sed 's/^/  \$(hostname) /'"; done
  ssh $J $C "cd /root/rq; for k in \$(seq 0 $((n-1))); do echo -n \"  P\$k EAGAIN=\$(grep -c EAGAIN client_P\${k}_r33_$v.log) pin=\$(grep -o 'pinned to CPU [0-9]*' client_P\${k}_r33_$v.log | head -1 | awk '{print \$NF}') \"; done; echo"; }

for r in 1 2; do
  variant s1t3_$r 3 "0 1 2" 8 spd1 ""
  variant g11t3_$r 3 "0 1 2" 8 spd2 ""
done
for h in $C $S; do mkdir -p raw33/${h##*.}; scp -q $J "$h:/root/rq/r33_*" "$h:/root/rq/*_r33_*" raw33/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
