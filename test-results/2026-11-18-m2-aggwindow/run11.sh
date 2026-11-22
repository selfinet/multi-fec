#!/bin/bash
# RTT 85 ms + 손실 1 % (두 경로·양방향 각 1 %): (A) 경로별 WG + ECMP  (B) multi-fec 3터널 + ECMP. 사용자 관점 ue → hq.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw11
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'tc qdisc change dev enp4s0 parent 1:1 handle 10: netem delay 42.5ms loss 1% limit 20000
  tc qdisc change dev enp4s0 parent 1:2 handle 20: netem delay 42.5ms loss 1% limit 20000
  tc qdisc replace dev enp1s0 root netem delay 42.5ms loss 1% limit 20000
  echo "$(hostname): $(tc qdisc show | grep -oE "netem [0-9a-f]+: .*loss [0-9]+%" | paste -sd" ")"'; done
ssh $J $S 'cd /root/rq; pkill -x iperf3; sleep 1; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq11.log 2>&1 < /dev/null &)'
ssh $J $C 'for a in 10.91.1.1 10.91.2.1; do echo "$a $(ping -c 4 -i 0.3 -q $a | tail -1)"; done'

ROUTE() { ssh $J $C "ip route replace 10.90.0.0/24 $1"; ssh $J $S "ip route replace 10.88.1.0/24 $1"; }
run() { local name=$1 P=$2 A=$3; local IFS_LIST="$IFL"
  echo "== $name (P$P $A) $(date +%T)"
  CNT="for i in $IFL; do echo -n \"\$(cat /sys/class/net/\$i/statistics/tx_packets) \$(cat /sys/class/net/\$i/statistics/rx_packets) \"; done"
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -n; (mpstat -P ALL 1 32 > r11_${name}_mpstat.txt 2>&1 &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw11/iperf_$name.txt 2>&1
  sleep 3; a=$(ssh $J $C "$CNT")
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  rx=$(grep receiver raw11/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw11/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); n=split(x[1],B," "); split(x[2],E," "); k=n/2;
    o=(d=="-R")?2:1; t=0; for(i=0;i<k;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]}
    for(i=0;i<k;i++) printf "%.0f/", 100*v[i]/t}')
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2==\"all\"{printf \"%.0f\", \$NF}' /root/rq/r11_${name}_mpstat.txt"; echo -n " "; done)
  echo "  recv $rx | share $sh | retr $rt | rcvbufErr c/s $ub | idle c/s $idle"; sleep 5; }

# (A) 경로별 WG
IFL="wgp1 wgp2"
ROUTE "dev wgp1"; run wg_p1only_up 8 ""; run wg_p1only_down 8 "-R"
ROUTE "nexthop dev wgp1 nexthop dev wgp2"
run wg_ecmp24_up 24 ""; run wg_ecmp24_down 24 "-R"; run wg_ecmp8_up 8 ""; run wg_ecmp8_down 8 "-R"; run wg_ecmp1_up 1 ""; run wg_ecmp1_down 1 "-R"

# (B) multi-fec 3터널
for pair in "$S server" "$C client"; do set -- $pair; ssh $J $1 "cd /root/rq; for k in 0 1 2; do kill \$(cat ${2}_P\$k.pid) 2>/dev/null; done; sleep 1; for k in 0 1 2; do setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/${2}_P\$k.conf > ${2}_P\${k}_r11.log 2>&1 < /dev/null & echo \$! > ${2}_P\$k.pid; done"; done
sleep 10; ssh $J $C 'for k in 0 1 2; do echo "pair$k $(ping -c 4 -i 0.3 -q 10.89.$k.1 | tail -1)"; done; grep -h "path\[" /root/rq/client_P0_r11.log | tail -2'
IFL="rq-wg rq-wg2 rq-wg3"
ROUTE "dev rq-wg"; run mf_1tun_up 8 ""; run mf_1tun_down 8 "-R"
ROUTE "nexthop dev rq-wg nexthop dev rq-wg2 nexthop dev rq-wg3"
run mf_ecmp24_up 24 ""; run mf_ecmp24_down 24 "-R"; run mf_ecmp8_up 8 ""; run mf_ecmp8_down 8 "-R"; run mf_ecmp1_up 1 ""; run mf_ecmp1_down 1 "-R"

for h in $C $S; do mkdir -p raw11/${h##*.}; scp -q $J "$h:/root/rq/r11_*" "$h:/root/rq/*_r11.log" raw11/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
