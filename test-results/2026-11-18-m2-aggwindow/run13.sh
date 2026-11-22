#!/bin/bash
# 터널 1개(P0)에서 이용률·비용 개선안: sock-buf 축소 · WG 에 CAKE · FEC 비율. 30/54 ms, 손실 0, iperf3 -P 8 직접.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw13
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'cd /root/rq; for f in *_P?.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
  tc qdisc del dev rq-wg root 2>/dev/null; echo "$(hostname): $(tc qdisc show | grep -oE "netem [0-9a-f]+: .*delay [0-9.]+ms( loss [0-9]+%)?" | paste -sd" ")"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s13.log 2>&1 < /dev/null &)'

# start VARIANT EXTRA_CONF_LINES CAKE_RATE(빈값=없음)
start() { local v=$1 extra=$2 cake=$3
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      { cat ${2}_P0.conf; printf '%b' '$extra'; } > ${2}_r13_$v.conf
      tc qdisc del dev rq-wg root 2>/dev/null; [ -n '$cake' ] && tc qdisc replace dev rq-wg root cake bandwidth $cake
      setsid timeout 1200 ./multi-fec-static.v144 --config /root/rq/${2}_r13_$v.conf > ${2}_r13_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8
  ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1; grep -hE 'fec|sock' /root/rq/client_r13_$v.conf; tc qdisc show dev rq-wg | head -1"; }
run() { local name=$1 A=$2
  for h in $C $S; do ssh $J $h "nstat -n"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 -P 8 -t 30 $A" > raw13/iperf_$name.txt 2>&1
  sleep 2
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  rx=$(grep -E 'SUM.*receiver' raw13/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1)}')
  rt=$(grep -E 'SUM.*sender' raw13/iperf_$name.txt | awk '{print $(NF-1)}')
  echo "  $name recv $rx Mbps | retr $rt | rcvbufErr c/s $ub"; sleep 4; }
variant() { local v=$1; echo "== $v $(date +%T)"; start "$@"
  run ${v}_up1 ""; run ${v}_down1 "-R"; run ${v}_up2 ""; run ${v}_down2 "-R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r13_$v.log) \$(grep 'pending queue full' /root/rq/client_r13_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }

variant base   ""                         ""
variant sb1024 "sock-buf = 1024\n"        ""
variant sb512  "sock-buf = 512\n"         ""
variant cake120 ""                        "120Mbit"
variant cake100 ""                        "100Mbit"
variant f202   "fec = 20:2\n"             ""
variant combo  "sock-buf = 1024\nfec = 20:2\n" "120Mbit"
for h in $C $S; do ssh $J $h "tc qdisc del dev rq-wg root 2>/dev/null"; mkdir -p raw13/${h##*.}; scp -q $J "$h:/root/rq/*_r13_*" raw13/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
