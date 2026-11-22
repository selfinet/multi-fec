#!/bin/bash
# 원인 분리: 1.4.4 로 (1) 두 경로 지연 같게 42/42 ms (2) 경로 하나만(path1 차단)
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw3
restart_tag() { T=$1; for pair in "$S server" "$C client"; do set -- $pair $T; ssh $J $1 "cd /root/rq; kill \$(cat $2.pid) 2>/dev/null; sleep 1
    setsid timeout 3600 ./multi-fec-dist.v144 --config /root/rq/$2.conf > ${2}_$3.log 2>&1 < /dev/null & echo \$! > $2.pid" ; done; sleep 8; }
delay() { for h in $C $S; do ssh $J $h "tc qdisc change dev enp4s0 parent 1:1 handle 10: netem delay $1 limit 20000; tc qdisc change dev enp4s0 parent 1:2 handle 20: netem delay $2 limit 20000"; done; }
run() { echo "== $1 $(date +%T)"; ssh $J $C "iperf3 -c 10.89.0.1 -P 8 -t 30 -i 1 $2" > raw3/iperf_$1.txt 2>&1; grep -E "SUM.*(sender|receiver)" raw3/iperf_$1.txt; sleep 4; }
delay 42ms 42ms; restart_tag eq42
ssh $J $C "ping -c 4 -q 172.31.10.1 | tail -1; ping -c 4 -q 172.31.11.1 | tail -1"
run eq42_up ""; run eq42_down "-R"
delay 30ms 54ms; restart_tag single
ssh $J $C "iptables -I OUTPUT -o enp4s0 -p udp -d 172.31.11.1 --dport 443 -j DROP"; sleep 4
run single_p0_up ""; run single_p0_down "-R"
ssh $J $C "iptables -L OUTPUT -v -n | grep 172.31.11.1; iptables -D OUTPUT -o enp4s0 -p udp -d 172.31.11.1 --dport 443 -j DROP; iptables -S OUTPUT | grep -c 172.31.11.1"
for h in $C $S; do scp -q $J "$h:/root/rq/*_eq42.log" "$h:/root/rq/*_single.log" raw3/; done
echo done
