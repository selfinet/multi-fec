#!/bin/bash
# run39: IFB(ingress netem) 조건에서 speed.2 GSO 켬/끔 5회 교대 (2026-11-20 사용자 "IFB 조건에서 GSO 켬/끔 5회 비교해 줘").
# run38 하네스(P0 터널 1, aggregate, rps 0, 1초 계측 빌드 bin37/mfspd2i) + run32 의 IFB 구성(지연 값 같음, 수신 호스트 ingress 에서 건다, 172.31.0.0/16 출발분만).
# 끝나면(trap) mf·iperf3 종료, IFB 제거, 원래 egress netem 복원·대조.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw39
restore() { echo "== restore $(date +%T)"
  for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; pkill -x iperf3; pkill -f '^bash /root/rq/udpsamp39' ; echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus; sleep 1
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) mf=\$(pgrep -fc '^./mf39') iperf=\$(pgrep -xc iperf3) samp=\$(pgrep -fc '^bash /root/rq/udpsamp39')\""; done; }
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
echo "== setup $(date +%T)"
for h in $C $S; do
  scp -q $J bin37/mfspd2i $h:/root/rq/mf39.spd2i
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus
    printf "%s\n" "while :; do echo \"\$(date +%s%3N) \$(awk '"'"'/^Udp:/{getline; print \$6, \$7}'"'"' /proc/net/snmp)\"; sleep 1; done" > udpsamp39
    for v in spd2i; do echo "$(hostname) $v $(sha256sum mf39.$v | cut -c1-8) $(./mf39.$v --version | sed -n 1p)"; done'; done
for h in $C $S; do ssh $J $h "$IFB_UP"; done
echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
ssh $J $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s39.log 2>&1 < /dev/null &)'
start() { local v=$1 bin=$2 env=$3
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      env $env setsid timeout 1200 ./mf39.$bin --config /root/rq/${2}_P0.conf > ${2}_r39_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8
  for h in $S $C; do ssh $J $h "p=\$(pgrep -P \$(cat /root/rq/*_P0.pid | head -1)); echo \"  \$(hostname) running \$(/proc/\$p/exe --version | head -1) env=\$(tr '\\0' '\\n' < /proc/\$p/environ | grep -c MF_UDP_GSO=0)\""; done
  ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2
  for h in $C $S; do ssh $J $h "cd /root/rq; (setsid timeout 45 bash /root/rq/udpsamp39 > r39_${name}_udp.txt 2>&1 < /dev/null &)"; done
  echo "  $name start $(date +%s%3N)"
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 -i 1 --get-server-output $A" > raw39/iperf_$name.txt 2>&1
  echo "  $name end   $(date +%s%3N) $(grep -E 'SUM.*receiver|receiver' raw39/iperf_$name.txt | tail -1 | grep -oE '[0-9.]+ Mbits/sec')"; sleep 6; }
variant() { local v=$1 bin=$2 env=$3; echo "== $v ($bin $env) $(date +%T)"; start $v $bin "$env"
  run ${v}_p8_up "-P 8 -t 30"; run ${v}_p8_dn "-P 8 -t 30 -R"; run ${v}_p1_up "-P 1 -t 30"; run ${v}_p1_dn "-P 1 -t 30 -R"; }
for r in 1 2 3 4 5; do
  if [ $((r % 2)) = 1 ]; then variant on_$r spd2i ""; variant off_$r spd2i "MF_UDP_GSO=0"; else variant off_$r spd2i "MF_UDP_GSO=0"; variant on_$r spd2i ""; fi
done
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw39/${h##*.}; scp -q $J "$h:/root/rq/*_r39_*.log" "$h:/root/rq/r39_*" raw39/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
