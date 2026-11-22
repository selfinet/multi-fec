#!/bin/bash
# 손실 위치: 1.4.4 기본(aggregate) 터널 TCP 8연결 30 s 상·하향 ×2, 각 런 앞뒤로 모든 층 카운터 스냅샷.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw5
SNAP='date +%s.%N; echo "#NSTAT"; nstat -asz; echo "#TC_ENP"; tc -s qdisc show dev enp4s0; echo "#TC_WG"; tc -s qdisc show dev rq-wg;
 echo "#LINK_ENP"; ip -s -s link show enp4s0; echo "#LINK_WG"; ip -s -s link show rq-wg; echo "#UDP"; cat /proc/net/udp;
 echo "#ETH"; ethtool -S enp4s0 2>/dev/null | grep -iE "drop|miss|err|fifo|no_buf|rx_packets|tx_packets"; echo "#WG"; wg show rq-wg transfer'
snap() { for h in $C $S; do ssh $J $h "$SNAP" > raw5/snap_$1_$2_${h##*.}.txt 2>&1; done; }
for pair in "$S server" "$C client"; do set -- $pair; ssh $J $1 "cd /root/rq; kill \$(cat $2.pid) 2>/dev/null; sleep 1
  setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/$2.conf > ${2}_r5.log 2>&1 < /dev/null & echo \$! > $2.pid"; done
ssh $J $S "cd /root/rq; pgrep -x iperf3 >/dev/null || { setsid timeout 3600 iperf3 -s -B 10.89.0.1 > iperf_s.log 2>&1 < /dev/null & echo \$! > iperf.pid; }"
sleep 8; ssh $J $C "ping -c 5 -i 0.3 -q 10.89.0.1 | tail -1"
for r in up1 down1 up2 down2; do A=""; [[ $r == down* ]] && A="-R"
  echo "== $r $(date +%T)"; snap $r a
  ssh $J $C "iperf3 -c 10.89.0.1 -P 8 -t 30 -i 1 $A" > raw5/iperf_$r.txt 2>&1
  sleep 2; snap $r b; grep -E "SUM.*(sender|receiver)" raw5/iperf_$r.txt; sleep 4; done
for h in $C $S; do scp -q $J "$h:/root/rq/*_r5.log" raw5/; done
echo done
