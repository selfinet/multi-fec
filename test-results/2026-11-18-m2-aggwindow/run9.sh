#!/bin/bash
# multi-fec 없이: 경로별 WG(wgp1 = path1 enp4s0 30 ms, wgp2 = path2 enp1s0 54 ms) + ECMP, 사용자 관점(ue → hq).
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw9
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'cd /root/rq; for f in *_P?.pid; do kill $(cat $f) 2>/dev/null; done; [ -f wgp.key ] || { wg genkey > wgp.key; chmod 600 wgp.key; }; wg pubkey < wgp.key'; done > raw9/pubs.txt
CPUB=$(sed -n 1p raw9/pubs.txt); SPUB=$(sed -n 2p raw9/pubs.txt)
ssh $J $S "bash -s" <<EOF
cd /root/rq
for k in 1 2; do n=wgp\$k; ip link del \$n 2>/dev/null; ip link add \$n type wireguard
  wg set \$n private-key wgp.key listen-port \$((51900+k)) peer $CPUB allowed-ips 10.91.\$k.2/32,10.88.1.0/24
  ip addr add 10.91.\$k.1 peer 10.91.\$k.2 dev \$n; ip link set \$n mtu 1420 up; done
ip route replace 10.88.1.0/24 nexthop dev wgp1 nexthop dev wgp2
pgrep -x iperf3 >/dev/null || (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq9.log 2>&1 < /dev/null &)
echo "S mf=\$(pgrep -c -x multi-fec-stati) hash=\$(sysctl -n net.ipv4.fib_multipath_hash_policy) fwd=\$(sysctl -n net.ipv4.ip_forward)"; ip route show 10.88.1.0/24
EOF
ssh $J $C "bash -s" <<EOF
cd /root/rq
E1=172.31.10.1; E2=172.31.20.1
for k in 1 2; do n=wgp\$k; eval ep=\\\$E\$k; ip link del \$n 2>/dev/null; ip link add \$n type wireguard
  wg set \$n private-key wgp.key peer $SPUB endpoint \$ep:\$((51900+k)) allowed-ips 10.91.\$k.1/32,10.90.0.0/24 persistent-keepalive 25
  ip addr add 10.91.\$k.2 peer 10.91.\$k.1 dev \$n; ip link set \$n mtu 1420 up; done
ip route replace 10.90.0.0/24 nexthop dev wgp1 nexthop dev wgp2
echo "C mf=\$(pgrep -c -x multi-fec-stati) hash=\$(sysctl -n net.ipv4.fib_multipath_hash_policy)"; ip route show 10.90.0.0/24
for a in 172.31.10.1 172.31.20.1; do ip route get \$a | head -1; done
EOF
sleep 3
ssh $J $C 'for k in 1 2; do echo "wgp$k $(ping -c 4 -i 0.3 -q 10.91.$k.1 | tail -1)"; done; ip netns exec ue ping -c 4 -i 0.3 -q 10.90.0.10 | tail -1
  wg show wgp1 endpoints; wg show wgp2 endpoints'

ROUTE() { ssh $J $C "ip route replace 10.90.0.0/24 $1"; ssh $J $S "ip route replace 10.88.1.0/24 $1"; }
CNT='for i in wgp1 wgp2; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  echo "== $name (P$P $A) $(date +%T)"
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; (mpstat -P ALL 1 32 > r9_${name}_mpstat.txt 2>&1 &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw9/iperf_$name.txt 2>&1
  sleep 3; a=$(ssh $J $C "$CNT")
  rx=$(grep receiver raw9/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw9/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<2;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]}
    printf "  share wgp1 %.0f%% wgp2 %.0f%%  ", 100*v[0]/t, 100*v[1]/t}'
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2==\"all\"{printf \"%.0f\", \$NF}' /root/rq/r9_${name}_mpstat.txt"; echo -n " "; done)
  echo "| recv $rx | retr $rt | idle c/s $idle"; sleep 5; }

ROUTE "dev wgp1";  run p1only_up 8 ""; run p1only_down 8 "-R"
ROUTE "dev wgp2";  run p2only_up 8 ""; run p2only_down 8 "-R"
ROUTE "nexthop dev wgp1 nexthop dev wgp2"
run ecmp24_up1 24 ""; run ecmp24_down1 24 "-R"; run ecmp24_up2 24 ""; run ecmp24_down2 24 "-R"
run ecmp8_up 8 ""; run ecmp8_down 8 "-R"
run ecmp1_up 1 ""; run ecmp1_down 1 "-R"
for h in $C $S; do mkdir -p raw9/${h##*.}; scp -q $J "$h:/root/rq/r9_*" raw9/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
