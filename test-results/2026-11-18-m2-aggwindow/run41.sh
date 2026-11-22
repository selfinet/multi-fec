#!/bin/bash
# run41 — 사용자 30명 모사: 하향을 많이 받는 PC 3대(각 -P 8) + 가벼운 사용자 27명, 서버(.93) 쪽 CAKE 만 유무 비교.
# 2026-11-21 사용자 "Server쪽에 Cake를 걸고, download에 문제가 생기지 않는지, 나머지 27명에 대해 문제가 발생하는지 확인".
# 조건 run40 과 같음(speed.2 터널 3쌍 ECMP, pin 0,1,2, rps 8, IFB netem 60/108 ms). 사용자 = ue netns 보조 IP 10.88.1.11~40(H 11~13, L 14~40), hq iperf3 포트 5211~5240.
# CAKE: .93 rq-wgN egress dual-dsthost besteffort, rate = run40 보정 하향 × 0.9 (73575/83520/59850 kbit). .92 는 CAKE 없음.
# 단계: A heavy_only(H 3대 30 s) · B mix_cap(H 40 s + 5 s 뒤 L 27명 각 1연결 4 Mbit/s 30 s) · C mix_free(L 제한 없음). L 9명(14,17,…,38)이 ping 0.2 s.
# 순서 nocake_1 → cake_1 → cake_2 → nocake_2. 끝나면 IP 제거·CAKE 삭제·IFB 제거·netem 복원 대조.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw41
echo "== setup $(date +%T)"
for h in $C $S; do
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
    for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done
    echo "$(hostname) spd2 $(md5sum multi-fec-dist.spd2 | cut -c1-12) qdisc $(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev $i | head -1 | cut -d" " -f2; done | paste -sd/)"'; done
ssh $J $S 'cd /root/rq; for p in $(seq 5211 5240); do (setsid timeout 3600 ip netns exec hq iperf3 -s -p $p > /dev/null 2>&1 < /dev/null &); done; sleep 1; echo "  hq iperf3 서버 $(pgrep -xc iperf3)"'
IPS_ADD='for j in $(seq 11 40); do ip netns exec ue ip addr add 10.88.1.$j/24 dev eth0; done; echo "  ue 주소 $(ip netns exec ue ip -4 -o addr show dev eth0 | wc -l)"'
IPS_DEL='for j in $(seq 11 40); do ip netns exec ue ip addr del 10.88.1.$j/24 dev eth0 2>/dev/null; done; echo "$(hostname) ue 주소 $(ip netns exec ue ip -4 -o addr show dev eth0 | wc -l)(원래 1)"'

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
restore2() { restore; ssh $J $C "$IPS_DEL"; for h in $C $S; do ssh $J $h "$IFB_DOWN"; ssh $J $h "$NETEM_RESTORE"; done; }
trap restore2 EXIT
for h in $C $S; do ssh $J $h "$IFB_UP"; done
echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
ssh $J $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'

setrps 8; route 3
for pair in "$S server" "$C client"; do set -- $pair
  cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
  for k in 0 1 2; do cmd="$cmd; setsid timeout 2400 ./multi-fec-dist.spd2 --config /root/rq/${2}_P$k.conf --pin-cpu $k > ${2}_P${k}_r41.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
  ssh $J $1 "$cmd"; done
sleep 10
ssh $J $C "$IPS_ADD; ip netns exec ue ping -c 3 -i 0.3 -q -I 10.88.1.40 10.90.0.10 | tail -1"
RD=(73575 83520 59850)
cake_on() { ssh $J $S "tc qdisc replace dev rq-wg root cake bandwidth ${RD[0]}kbit dual-dsthost besteffort; tc qdisc replace dev rq-wg2 root cake bandwidth ${RD[1]}kbit dual-dsthost besteffort; tc qdisc replace dev rq-wg3 root cake bandwidth ${RD[2]}kbit dual-dsthost besteffort
  echo \"  \$(hostname) \$(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev \$i | head -1 | grep -o 'bandwidth [0-9a-zA-Z]*'; done | paste -sd' ')\""
  ssh $J $C 'echo "  $(hostname) qdisc $(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev $i | head -1 | cut -d" " -f2; done | paste -sd/)"'; }
cake_off() { for h in $C $S; do ssh $J $h "$CAKE_OFF"; done; }
phase() { local name=$1 kind=$2 B=""
  [ "$kind" = cap ] && B="-b 4M"
  for h in $C $S; do ssh $J $h "nstat -n; cd /root/rq; (LC_ALL=C mpstat -P ALL 1 38 > r41_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  if [ "$kind" = heavy ]; then
    ssh $J $C "cd /root/rq; mkdir -p r41; rm -f r41/${name}_*
      for i in 1 2 3; do ip netns exec ue iperf3 -c 10.90.0.10 -p 521\$i -B 10.88.1.1\$i -P 8 -R -t 30 -i 1 > r41/${name}_H\$i.txt 2>&1 & done
      sleep 3; ip netns exec ue ping -I 10.88.1.14 -i 0.2 -c 120 -W 2 10.90.0.10 > r41/${name}_P14.txt 2>&1 & wait"
  else
    ssh $J $C "cd /root/rq; mkdir -p r41; rm -f r41/${name}_*
      for i in 1 2 3; do ip netns exec ue iperf3 -c 10.90.0.10 -p 521\$i -B 10.88.1.1\$i -P 8 -R -t 40 -i 1 > r41/${name}_H\$i.txt 2>&1 & done
      sleep 5
      for j in \$(seq 14 40); do ip netns exec ue iperf3 -c 10.90.0.10 -p 52\$j -B 10.88.1.\$j -P 1 -R -t 30 $B > r41/${name}_L\$j.txt 2>&1 & done
      sleep 2; for j in 14 17 20 23 26 29 32 35 38; do ip netns exec ue ping -I 10.88.1.\$j -i 0.2 -c 135 -W 2 10.90.0.10 > r41/${name}_P\$j.txt 2>&1 & done
      wait"
  fi
  sleep 2
  echo "  $name rcvbuf c/s $(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n /; done) idle c/s $(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r41_${name}_mpstat.txt"; echo -n '/ '; done)"
  sleep 3; }
variant() { local v=$1
  echo "== $v $(date +%T)"; if [[ $v == cake* ]]; then cake_on; else cake_off; fi
  phase ${v}_heavy heavy; phase ${v}_cap cap; phase ${v}_free free
  [[ $v == cake* ]] && ssh $J $S 'for i in rq-wg rq-wg2 rq-wg3; do echo "  $(hostname) $i $(tc -s qdisc show dev $i | grep -m1 -oE "Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+")"; done'
  true; }
variant nocake_1; variant cake_1; variant cake_2; variant nocake_2
cake_off
for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done"; done
mkdir -p raw41/92 raw41/93
scp -q $J -r "$C:/root/rq/r41" raw41/92/ ; scp -q $J "$C:/root/rq/r41_*" "$C:/root/rq/*_r41.log" raw41/92/ 2>/dev/null; scp -q $J "$S:/root/rq/r41_*" raw41/93/ 2>/dev/null
echo "done $(date +%T)"
