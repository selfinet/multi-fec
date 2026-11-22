#!/bin/bash
# 사용자 관점 ECMP: .92 netns ue(10.88.1.10) → ECMP 3 터널 → .93 netns hq(10.90.0.10), 양쪽 장비가 포워딩.
# 구성은 run7 그대로(경로1 enp4s0 30 ms, 경로2 enp1s0 54 ms, 터널 3쌍). 모두 런타임 설정.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw8
echo "== setup $(date +%T)"
ssh $J $S 'bash -s' <<'EOF'
cd /root/rq
for f in server_P?.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
for k in 0 1 2; do setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/server_P$k.conf > server_P${k}_r8.log 2>&1 < /dev/null & echo $! > server_P$k.pid; done
sysctl -qw net.ipv4.fib_multipath_hash_policy=1 net.ipv4.ip_forward=1
ip netns del hq 2>/dev/null; ip netns add hq
ip link add hq0 mtu 1300 type veth peer name eth0 mtu 1300 netns hq
ip addr add 10.90.0.1/24 dev hq0; ip link set hq0 up
ip -n hq addr add 10.90.0.10/24 dev eth0; ip -n hq link set eth0 up; ip -n hq link set lo up; ip -n hq route add default via 10.90.0.1
PK=$(wg show rq-wg peers | head -1)
for k in 0 1 2; do n=rq-wg; [ $k -gt 0 ] && n=rq-wg$((k+1)); wg set $n peer $PK allowed-ips 10.89.$k.2/32,10.88.1.0/24; done
ip route replace 10.88.1.0/24 nexthop dev rq-wg nexthop dev rq-wg2 nexthop dev rq-wg3
setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq.log 2>&1 < /dev/null &
sleep 1; echo "S: $(sysctl -n net.ipv4.fib_multipath_hash_policy) fwd=$(sysctl -n net.ipv4.ip_forward) FORWARD=$(iptables -S FORWARD | head -1)"; ip route show 10.88.1.0/24
EOF
ssh $J $C 'bash -s' <<'EOF'
cd /root/rq
for f in client_P?.pid; do kill $(cat $f) 2>/dev/null; done; sleep 1
for k in 0 1 2; do setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/client_P$k.conf > client_P${k}_r8.log 2>&1 < /dev/null & echo $! > client_P$k.pid; done
sysctl -qw net.ipv4.fib_multipath_hash_policy=1
ip netns del ue 2>/dev/null; ip netns add ue
ip link add ue0 mtu 1300 type veth peer name eth0 mtu 1300 netns ue
ip addr add 10.88.1.1/24 dev ue0; ip link set ue0 up
ip -n ue addr add 10.88.1.10/24 dev eth0; ip -n ue link set eth0 up; ip -n ue link set lo up; ip -n ue route add default via 10.88.1.1
PK=$(wg show rq-wg peers | head -1)
for k in 0 1 2; do n=rq-wg; [ $k -gt 0 ] && n=rq-wg$((k+1)); wg set $n peer $PK allowed-ips 10.89.$k.1/32,10.90.0.0/24; done
ip route replace 10.90.0.0/24 nexthop dev rq-wg nexthop dev rq-wg2 nexthop dev rq-wg3
echo "C: hash=$(sysctl -n net.ipv4.fib_multipath_hash_policy) FORWARD=$(iptables -S FORWARD | head -1)"; ip route show 10.90.0.0/24
for a in 172.31.10.1 172.31.20.1; do ip route get $a | head -1; done
EOF
sleep 10
ssh $J $C 'ip netns exec ue ping -c 5 -i 0.3 -q 10.90.0.10 | tail -2'

ROUTE() { ssh $J $C "ip route replace 10.90.0.0/24 $1"; ssh $J $S "ip route replace 10.88.1.0/24 $1"; }
CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  echo "== $name (P$P $A) $(date +%T)"
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -n; (mpstat -P ALL 1 32 > r8_${name}_mpstat.txt 2>&1 &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw8/iperf_$name.txt 2>&1
  sleep 3
  a=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -z UdpRcvbufErrors > r8_${name}_nstat.txt"; done
  rx=$(grep receiver raw8/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw8/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  # 상향은 .92 TX, 하향은 .92 RX 를 터널별로
  echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); n=split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]}
    printf "  tunnel share(pkts) A %.0f%% B %.0f%% C %.0f%%  ", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}'
  echo "| recv $rx | retr $rt"; sleep 5; }

ROUTE "dev rq-wg"
run base8_up 8 ""; run base8_down 8 "-R"
ROUTE "nexthop dev rq-wg nexthop dev rq-wg2 nexthop dev rq-wg3"
run ecmp24_up1 24 ""; run ecmp24_down1 24 "-R"; run ecmp24_up2 24 ""; run ecmp24_down2 24 "-R"
run ecmp8_up 8 ""; run ecmp8_down 8 "-R"
run ecmp1_up 1 ""; run ecmp1_down 1 "-R"

for h in $C $S; do mkdir -p raw8/${h##*.}; scp -q $J "$h:/root/rq/r8_*" "$h:/root/rq/*_r8.log" raw8/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
