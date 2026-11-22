#!/bin/bash
# run49 — run48 의 창 제한 끔(--win-unlimited)이 경로 대역이 좁을 때 손해를 내는지. 경로별 속도 제한: path 172.31.10 (RTT 60) 100 Mbit, 172.31.20 (RTT 108) 50 Mbit,
# netem rate + limit(전파 지연분 + 약 50 ms 큐), 양방향(각 호스트 ingress IFB). 2026-11-22 사용자 "다음 시험 진행해 줘".
# 변형: mtbase · mtfifo_unl · mtfifo_w4(--pend-fifo --win-floor 4) · one(정식 단일 프로세스 spd2). 무손실 ×2, 손실 1 % ×1.
# run 줄 끝에 경로별 netem 큐 폐기(dropped)·전달량 MB 를 c(하향 수신)/s(상향 수신)로 붙인다.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw49
echo "== setup $(date +%T)"
for h in $C $S; do
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
    for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done
    echo "$(hostname) spd2 $(md5sum multi-fec-dist.spd2 | cut -c1-12) mt $(md5sum mmulti-fec-dist | cut -c1-12) $(./mmulti-fec-dist --version | head -1)"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 7200 ip netns exec hq iperf3 -s > iperf_hq49.log 2>&1 < /dev/null &)'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
CAKE_OFF='for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done; true'
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "$CAKE_OFF; cd /root/rq; for f in *_P?.pid *_MT.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)+\$(pgrep -c mmulti-fec-dist) iperf=\$(pgrep -xc iperf3) qdisc=\$(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev \$i | head -1 | cut -d' ' -f2; done | paste -sd/)\""; done; }
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
stopall() { for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid *_MT.pid; do kill \$(cat \$f) 2>/dev/null; rm -f \$f; done; sleep 2; echo -n"; done; }
start() { local v=$1 kind=$2; stopall
  case $kind in
    mt*) setrps 8; route 1
         case $kind in mtbase) XA="";; mtfifo) XA="--pend-fifo";; mtfifo_w2) XA="--pend-fifo --win-floor 2";; mtfifo_unl) XA="--pend-fifo --win-unlimited";; mtfifo_w4) XA="--pend-fifo --win-floor 4";; esac
         for pair in "$S server" "$C client"; do set -- $pair
           ssh $J $1 "cd /root/rq; setsid timeout 1500 ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 $XA > ${2}_MT_r49_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done ;;
    ecmp) setrps 8; route 3
         for pair in "$S server" "$C client"; do set -- $pair
           cmd="cd /root/rq"; for k in 0 1 2; do cmd="$cmd; setsid timeout 1500 ./multi-fec-dist.spd2 --config /root/rq/${2}_P$k.conf --pin-cpu $k > ${2}_P${k}_r49_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
           ssh $J $1 "$cmd"; done ;;
    one) setrps e; route 1
         for pair in "$S server" "$C client"; do set -- $pair
           ssh $J $1 "cd /root/rq; setsid timeout 1500 ./multi-fec-dist.spd2 --config /root/rq/${2}_P0.conf --pin-cpu 0 > ${2}_P0_r49_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done ;;
  esac
  sleep 10
  ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c multi-fec-dist)+\$(pgrep -c mmulti-fec-dist) cpus \$(for p in \$(pgrep -f 'multi-fec-dist'); do taskset -pc \$p | awk '{print \$NF}'; done | paste -sd,)\""; }
mbps() { awk '/SUM.*receiver/{f=1} /receiver/{l=$0} END{print l}' "$1" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){v=$(i-1); if($i ~ /^G/) v*=1000; if($i ~ /^K/) v/=1000; print v}}'; }
idle() { for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r49_$1_mpstat.txt"; echo -n "/ "; done; }
QS='for d in ifb4 ifb1; do tc -s qdisc show dev $d parent 1:1 | awk "/Sent/{b=\$2; for(i=1;i<=NF;i++) if(\$i==\"(dropped\") {x=\$(i+1); sub(\",\",\"\",x)}} END{printf \"%s %s \", b, x}"; done'
qsnap() { for h in $C $S; do ssh $J $h "$QS"; done; }
run() { local name=$1 P=$2 A=$3; local q0; q0=$(qsnap)
  for h in $C $S; do ssh $J $h "nstat -n; cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > r49_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  ssh $J $C "cd /root/rq; (ip netns exec ue ping -i 0.2 -c 150 -W 2 10.90.0.10 > r49_${name}_ping.txt 2>&1 &)"
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw49/iperf_$name.txt 2>&1
  sleep 3; ssh $J $C "cat /root/rq/r49_${name}_ping.txt" > raw49/ping_$name.txt
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  rt=$(grep -E "sender" raw49/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  pg=$(grep -o 'time=[0-9.]*' raw49/ping_$name.txt | cut -d= -f2 | sort -n | awk '{v[NR]=$1} END{if(NR) printf "p50 %.0f p99 %.0f n=%d", v[int(NR*0.5)+1], v[(int(NR*0.99)>0)?int(NR*0.99):1], NR}')
  q1=$(qsnap); qd=$(echo $q0 $q1 | awk '{printf "c drop %d/%d MB %.0f/%.0f  s drop %d/%d MB %.0f/%.0f", $10-$2,$12-$4,($9-$1)/1e6,($11-$3)/1e6, $14-$6,$16-$8,($13-$5)/1e6,($15-$7)/1e6}')
  echo "  $name recv $(mbps raw49/iperf_$name.txt) | retr $rt | ping $pg | idle c/s $(idle $name)| rcvbuf c/s $ub | q(A100/B50) $qd"; sleep 4; }
setloss() { local x=$1
  for h in $C $S; do ssh $J $h "tc qdisc change dev ifb4 parent 1:1 handle 10: netem limit 750 delay 30ms rate 100mbit loss $x%; tc qdisc change dev ifb4 parent 1:2 handle 20: netem limit 20000 delay 54ms loss $x%; tc qdisc change dev ifb1 parent 1:1 handle 10: netem limit 500 delay 54ms rate 50mbit loss $x%; echo \"  \$(hostname) \$(tc qdisc show dev ifb4 parent 1:1 | grep -oE 'rate [0-9A-Za-z]+|limit [0-9]+' | paste -sd' ') / \$(tc qdisc show dev ifb1 parent 1:1 | grep -oE 'rate [0-9A-Za-z]+|limit [0-9]+' | paste -sd' ')\"; echo \"  \$(hostname) loss \$(tc qdisc show dev ifb4 | grep -o 'loss [0-9.]*%' | paste -sd,)/\$(tc qdisc show dev ifb1 | grep -o 'loss [0-9.]*%')\""; done; }
variant() { local v=$1 kind=$2
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  run ${v}_p1_up 1 ""; run ${v}_p1_dn 1 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  for h in $C $S; do ssh $J $h "cd /root/rq; grep -aE 'pending enq' *_MT_r49_$v.log | tail -3 | sed 's/\x1b\[[0-9;]*m//g' | cut -c22- | sed 's/^/  '\$(hostname)' /'"; done
  ssh $J $C "cd /root/rq; echo \"  client EAGAIN \$(cat *_r49_$v.log | grep -c EAGAIN) pendfull \$(cat *_r49_$v.log | grep -c 'pending queue full') err \$(cat *_r49_$v.log | grep -cE 'ERROR|FATAL')\""; }
for h in $C $S; do scp -q $J ~/mmulti-fec/mmulti-fec-dist $h:/root/rq/mmulti-fec-dist; done
for h in $C $S; do ssh $J $h 'cd /root/rq; echo "$(hostname) spd2 $(md5sum multi-fec-dist.spd2 | cut -c1-12) mt $(md5sum mmulti-fec-dist | cut -c1-12) $(./mmulti-fec-dist --version | head -1)"'; done
setloss 0
echo "-- 하부 ping (속도 제한 후)"
ssh $J $C 'for a in 172.31.10.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'
for r in 1 2; do for k in mtbase mtfifo_unl mtfifo_w4 one; do variant nl_${k}_$r $k; done; done
setloss 1
for k in mtbase mtfifo_unl mtfifo_w4 one; do variant l1_${k}_1 $k; done
stopall
mkdir -p raw49/92 raw49/93
for h in $C $S; do scp -q $J "$h:/root/rq/r49_*" "$h:/root/rq/*_r49_*" raw49/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
