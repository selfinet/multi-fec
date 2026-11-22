#!/bin/bash
# 경로 2 를 enp1s0(172.31.20.x, 별도 물리 링크)로 옮기고 병렬 터널 1·2·3 쌍 측정.
#  쌍 k: client 127.0.0.1:5180(1+k) / server 0.0.0.0:44(3+k) / WG rq-wg(k+1) 10.89.k.x / iperf3 :520(1+k)
#  path1 172.31.10.1 (enp4s0, netem 30 ms 기존), path2 172.31.20.1 (enp1s0, netem 54 ms 신규)
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw7

echo "== setup $(date +%T)"
ssh $J $S 'bash -s' <<'EOF'
cd /root/rq
tc qdisc replace dev enp1s0 root netem delay 54ms limit 20000
PK=$(wg show rq-wg peers | head -1)
for k in 1 2; do n=rq-wg$((k+1)); ip link del $n 2>/dev/null; ip link add $n type wireguard
  wg set $n private-key <(wg show rq-wg private-key) listen-port $((51809+k)) peer $PK allowed-ips 10.89.$k.2/32
  ip addr add 10.89.$k.1 peer 10.89.$k.2 dev $n; ip link set $n mtu 1300 up; done
for k in 0 1 2; do sed -e "s/^listen .*/listen         = 0.0.0.0:$((443+k))/" -e "s/^wg .*/wg             = 127.0.0.1:$((51809+k))/" server.conf > server_P$k.conf
  setsid timeout 3000 ./multi-fec-static.v144 --config /root/rq/server_P$k.conf > server_P$k.log 2>&1 < /dev/null & echo $! > server_P$k.pid
  setsid timeout 3000 iperf3 -s -B 10.89.$k.1 -p $((5201+k)) > iperf_s$k.log 2>&1 < /dev/null & done
sleep 1; grep -hE "^(listen|wg|path)" server_P*.conf; ip -br a | grep rq-wg
EOF
ssh $J $C 'bash -s' <<'EOF'
cd /root/rq
tc qdisc replace dev enp1s0 root netem delay 54ms limit 20000
PK=$(wg show rq-wg peers | head -1)
for k in 1 2; do n=rq-wg$((k+1)); ip link del $n 2>/dev/null; ip link add $n type wireguard
  wg set $n private-key <(wg show rq-wg private-key) peer $PK endpoint 127.0.0.1:$((51801+k)) allowed-ips 10.89.$k.1/32 persistent-keepalive 25
  ip addr add 10.89.$k.2 peer 10.89.$k.1 dev $n; ip link set $n mtu 1300 up; done
for k in 0 1 2; do sed -e "s/^listen .*/listen         = 127.0.0.1:$((51801+k))/" -e "s/172.31.10.1:443/172.31.10.1:$((443+k))/" -e "s/172.31.11.1:443/172.31.20.1:$((443+k))/" client.conf > client_P$k.conf
  setsid timeout 3000 ./multi-fec-static.v144 --config /root/rq/client_P$k.conf > client_P$k.log 2>&1 < /dev/null & echo $! > client_P$k.pid; done
sleep 1; grep -hE "^(listen|path)" client_P*.conf; ip -br a | grep rq-wg
EOF
sleep 10
ssh $J $C 'for k in 0 1 2; do echo "pair$k $(ping -c 5 -i 0.3 -q 10.89.$k.1 | tail -1)"; done
  echo "path1 $(ping -c 3 -q 172.31.10.1 | tail -1)"; echo "path2 $(ping -c 3 -q 172.31.20.1 | tail -1)"
  ip route get 172.31.20.1 | head -1; grep -h "path\[" /root/rq/client_P0.log | tail -2'

MON='cd /root/rq; nstat -n; P=$(for f in *_P?.pid; do pgrep -P $(cat $f) -x multi-fec-stati; done | paste -sd,)
 for f in *_P?.pid; do echo "$f $(pgrep -P $(cat $f) -x multi-fec-stati)"; done > r7_NAME_pidmap.txt
 (mpstat -P ALL 1 32 > r7_NAME_mpstat.txt 2>&1 &); (pidstat -u -p $P 1 32 > r7_NAME_pid.txt 2>&1 &)'
run() { local name=$1 n=$2 A=$3
  echo "== $name $(date +%T)"
  for h in $C $S; do ssh $J $h "${MON//NAME/$name}"; done
  ssh $J $C "cd /root/rq; for k in \$(seq 0 $((n-1))); do iperf3 -c 10.89.\$k.1 -p \$((5201+k)) -P 8 -t 30 $A > r7_${name}_\$k.txt 2>&1 & done; wait"
  sleep 3
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -z UdpRcvbufErrors UdpInErrors TcpRetransSegs > r7_${name}_nstat.txt; sleep 0"; done
  local tot=0
  for k in $(seq 0 $((n-1))); do
    v=$(ssh $J $C "grep -E 'SUM.*receiver' /root/rq/r7_${name}_$k.txt" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1)}')
    echo "  pair$k ${v} Mbps"; tot=$(echo "$tot + ${v:-0}" | bc); done
  echo "  TOTAL $tot Mbps"; sleep 5; }

for n in 1 2 3; do for r in up1 down1 up2 down2; do A=""; [[ $r == down* ]] && A="-R"; run n${n}_$r $n "$A"; done; done

for h in $C $S; do mkdir -p raw7/${h##*.}; scp -q $J "$h:/root/rq/r7_*" "$h:/root/rq/*_P?.log" raw7/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
