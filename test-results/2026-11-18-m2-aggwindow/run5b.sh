#!/bin/bash
# 손실 위치 2: 같은 계측으로 (a) 두 경로 지연 42/42 ms (b) 경로 하나(path1 차단, 30 ms)
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"
SNAP=$(sed -n "/^SNAP=/,/transfer'$/p" run5.sh | sed "1s/^SNAP='//; \$s/'$//")
snap() { for h in $C $S; do ssh $J $h "$SNAP" > raw5/snap_$1_$2_${h##*.}.txt 2>&1; done; }
delay() { for h in $C $S; do ssh $J $h "tc qdisc change dev enp4s0 parent 1:1 handle 10: netem delay $1 limit 20000; tc qdisc change dev enp4s0 parent 1:2 handle 20: netem delay $2 limit 20000"; done; }
restart() { T=$3; for pair in "$S server" "$C client"; do set -- $pair; ssh $J $1 "cd /root/rq; kill \$(cat $2.pid) 2>/dev/null; sleep 1
  setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/$2.conf > ${2}_r5$T.log 2>&1 < /dev/null & echo \$! > $2.pid" ; done; sleep 8; }
run() { echo "== $1 $(date +%T)"; snap $1 a; ssh $J $C "iperf3 -c 10.89.0.1 -P 8 -t 30 -i 1 $2" > raw5/iperf_$1.txt 2>&1
  sleep 2; snap $1 b; grep -E "SUM.*(sender|receiver)" raw5/iperf_$1.txt; sleep 4; }
delay 42ms 42ms; restart 0 0 eq; run eq_up ""; run eq_down "-R"
delay 30ms 54ms; restart 0 0 single
ssh $J $C "iptables -I OUTPUT -o enp4s0 -p udp -d 172.31.11.1 --dport 443 -j DROP"; sleep 4
run single_up ""; run single_down "-R"
ssh $J $C "iptables -D OUTPUT -o enp4s0 -p udp -d 172.31.11.1 --dport 443 -j DROP; echo rules=\$(iptables -S OUTPUT | grep -c 172.31.11.1)"
for h in $C $S; do ssh $J $h "tc qdisc show dev enp4s0 | grep netem"; scp -q $J "$h:/root/rq/*_r5eq.log" "$h:/root/rq/*_r5single.log" raw5/; done
echo done
