#!/bin/bash
# run40 — speed.2 터널 3쌍(ECMP) + pin 0,1,2 + rps 8, netem 수신측 IFB(run33 조건) 에서 CAKE 90 % 유무 처리량 비교. 2026-11-21 사용자 "J1900에서 터널 3개 + CAKE 90% 처리량 시험해 줘".
# 1) 보정: CAKE 없이 터널마다 직접 TCP(10.89.k.1:520k, 터널당 -P 8, 3터널 동시, 20 s) 상·하 ×2 → 터널·방향별 평균 × 0.9 = CAKE rate.
# 2) 본시험 nocake/cake 교대 ×2: ECMP(ue→hq) -P 24·-P 8 상·하 30 s(동시 ping 0.2 s) + 터널 직접 동시 -P 8 상·하 20 s.
#    CAKE: .92 rq-wgN egress dual-srchost(상향), .93 rq-wgN egress dual-dsthost(하향), besteffort. 끝나면 rq-wgN root 삭제(원래 noqueue)·IFB 제거·netem 복원 대조.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw40
echo "== setup $(date +%T)"
for h in $C $S; do
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
    for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done
    echo "$(hostname) spd2 $(md5sum multi-fec-dist.spd2 | cut -c1-12) qdisc $(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev $i | head -1 | cut -d" " -f2; done | paste -sd/)"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq40.log 2>&1 < /dev/null &)
  for k in 0 1 2; do (setsid timeout 3600 iperf3 -s -B 10.89.$k.1 -p 520$k > iperf_t$k.log 2>&1 < /dev/null &); done'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
CAKE_OFF='for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done; true'
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "$CAKE_OFF; cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist) iperf=\$(pgrep -xc iperf3) qdisc=\$(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev \$i | head -1 | cut -d' ' -f2; done | paste -sd/)\""; done; }
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
echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
ssh $J $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'

setrps 8; route 3
for pair in "$S server" "$C client"; do set -- $pair
  cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
  for k in 0 1 2; do cmd="$cmd; setsid timeout 2400 ./multi-fec-dist.spd2 --config /root/rq/${2}_P$k.conf --pin-cpu $k > ${2}_P${k}_r40.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
  ssh $J $1 "$cmd"; done
sleep 10
ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; for k in 0 1 2; do echo -n \"P\$k \$(taskset -pc \$(pgrep -P \$(cat /root/rq/client_P\$k.pid)) | awk '{print \$NF}') \"; ping -c 2 -q 10.89.\$k.1 | tail -1; done; cat /sys/class/net/lo/queues/rx-0/rps_cpus"

mbps() { awk '/SUM.*receiver/{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){v=$(i-1); if($i ~ /^G/) v*=1000; if($i ~ /^K/) v/=1000; print v}}' "$1" | tail -1; }
# 터널 직접 동시: $1 이름, $2 "" 또는 -R, $3 초
direct() { local name=$1 A=$2 t=$3
  ssh $J $C "cd /root/rq; for k in 0 1 2; do iperf3 -c 10.89.\$k.1 -p 520\$k -P 8 -t $t $A > r40_${name}_t\$k.txt 2>&1 & done; wait"
  for k in 0 1 2; do ssh $J $C "cat /root/rq/r40_${name}_t$k.txt" > raw40/${name}_t$k.txt; done
  echo "$(mbps raw40/${name}_t0.txt) $(mbps raw40/${name}_t1.txt) $(mbps raw40/${name}_t2.txt)"; }

echo "== 보정 (CAKE 없음, 터널 직접 동시 -P 8) $(date +%T)"
for r in 1 2; do
  u=$(direct cal${r}_up "" 20); sleep 3; d=$(direct cal${r}_dn "-R" 20); sleep 3
  echo "  cal$r up $u | dn $d"; echo "$u" >> raw40/cal_up.txt; echo "$d" >> raw40/cal_dn.txt; done
read -ra RU <<< "$(awk '{for(k=1;k<=3;k++) s[k]+=$k} END{for(k=1;k<=3;k++) printf "%d ", 0.9*s[k]/NR*1000}' raw40/cal_up.txt)"
read -ra RD <<< "$(awk '{for(k=1;k<=3;k++) s[k]+=$k} END{for(k=1;k<=3;k++) printf "%d ", 0.9*s[k]/NR*1000}' raw40/cal_dn.txt)"
echo "  CAKE rate kbit 상향(.92) ${RU[*]} / 하향(.93) ${RD[*]}"
[ "${RU[0]:-0}" -gt 10000 ] && [ "${RD[0]:-0}" -gt 10000 ] || { echo "보정 실패 — 중단"; exit 1; }

cake_on() {
  ssh $J $C "tc qdisc replace dev rq-wg root cake bandwidth ${RU[0]}kbit dual-srchost besteffort; tc qdisc replace dev rq-wg2 root cake bandwidth ${RU[1]}kbit dual-srchost besteffort; tc qdisc replace dev rq-wg3 root cake bandwidth ${RU[2]}kbit dual-srchost besteffort"
  ssh $J $S "tc qdisc replace dev rq-wg root cake bandwidth ${RD[0]}kbit dual-dsthost besteffort; tc qdisc replace dev rq-wg2 root cake bandwidth ${RD[1]}kbit dual-dsthost besteffort; tc qdisc replace dev rq-wg3 root cake bandwidth ${RD[2]}kbit dual-dsthost besteffort"
  for h in $C $S; do ssh $J $h 'echo "  $(hostname) $(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev $i | head -1 | grep -o "bandwidth [0-9a-zA-Z]*"; done | paste -sd" ")"'; done; }
cake_off() { for h in $C $S; do ssh $J $h "$CAKE_OFF"; done; }

CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
idle() { for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r40_$1_mpstat.txt"; echo -n "/ "; done; }
mpst() { for h in $C $S; do ssh $J $h "cd /root/rq; (LC_ALL=C mpstat -P ALL 1 $2 > r40_$1_mpstat.txt 2>&1 < /dev/null &)"; done; }
ecmp() { local name=$1 P=$2 A=$3
  b=$(ssh $J $C "$CNT"); for h in $C $S; do ssh $J $h "nstat -n"; done; mpst $name 32
  ssh $J $C "cd /root/rq; (ip netns exec ue ping -i 0.2 -c 150 -W 2 10.90.0.10 > r40_${name}_ping.txt 2>&1 &)"
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw40/iperf_$name.txt 2>&1
  sleep 3; a=$(ssh $J $C "$CNT"); ssh $J $C "cat /root/rq/r40_${name}_ping.txt" > raw40/ping_$name.txt
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  rt=$(grep -E "SUM.*sender" raw40/iperf_$name.txt | awk '{print $(NF-1)}')
  pg=$(grep -o 'time=[0-9.]*' raw40/ping_$name.txt | cut -d= -f2 | sort -n | awk '{v[NR]=$1} END{if(NR) printf "p50 %.0f p99 %.0f n=%d", v[int(NR*0.5)+1], v[(int(NR*0.99)>0)?int(NR*0.99):1], NR}')
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]} if(t==0)t=1; printf "%.0f/%.0f/%.0f", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}')
  echo "  $name recv $(mbps raw40/iperf_$name.txt) | retr $rt | share $sh | ping $pg | idle c/s $(idle $name)| rcvbuf c/s $ub"; sleep 4; }
dirrun() { local name=$1 A=$2
  local vv; mpst $name 22; vv=$(direct $name "$A" 20); sleep 2
  echo "  $name 터널별 $vv 합 $(echo $vv | awk '{printf "%.0f", $1+$2+$3}') | idle c/s $(idle $name)"; sleep 4; }
variant() { local v=$1
  echo "== $v $(date +%T)"; if [[ $v == cake* ]]; then cake_on; else cake_off; fi
  ecmp ${v}_p24_up 24 ""; ecmp ${v}_p24_dn 24 "-R"; ecmp ${v}_p8_up 8 ""; ecmp ${v}_p8_dn 8 "-R"
  dirrun ${v}_dir_up ""; dirrun ${v}_dir_dn "-R"
  [[ $v == cake* ]] && for h in $C $S; do ssh $J $h 'for i in rq-wg rq-wg2 rq-wg3; do echo "  $(hostname) $i $(tc -s qdisc show dev $i | grep -m1 -oE "Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+")"; done'; done; }
variant nocake_1; variant cake_1; variant cake_2; variant nocake_2
cake_off
ssh $J $C "cd /root/rq; for k in 0 1 2; do echo -n \"  P\$k EAGAIN=\$(grep -c EAGAIN client_P\${k}_r40.log) pin=\$(grep -o 'pinned to CPU [0-9]*' client_P\${k}_r40.log | head -1 | awk '{print \$NF}') \"; done; echo"
for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done"; mkdir -p raw40/${h##*.}; scp -q $J "$h:/root/rq/r40_*" "$h:/root/rq/*_r40.log" raw40/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
