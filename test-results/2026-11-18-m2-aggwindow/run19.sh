#!/bin/bash
# client(.92) perf 상세 — 바이너리 .lazylog(1.4.4+SSSE3+no-peek+로그 지연평가), 조건 run16~18 과 같음(P0, aggregate, 30/54 ms, 손실 0).
# 부하별(TCP -P 8 상향 / UDP 200M 상향 / TCP -P 8 하향) : 20 s perf record -g (커널 콜체인) + 10 s perf stat 시스템콜·컨텍스트 스위치.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw19
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null; md5sum multi-fec-static.lazylog | cut -c1-12'; done
ssh $J $S 'cd /root/rq; (setsid timeout 1800 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s19.log 2>&1 < /dev/null &)'
for pair in "$S server" "$C client"; do set -- $pair
  ssh $J $1 "cd /root/rq; setsid timeout 1200 ./multi-fec-static.lazylog --config /root/rq/${2}_P0.conf > ${2}_r19.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"
prof() { local name=$1 A=$2
  echo "== $name ($A) $(date +%T)"
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A -t 36" > raw19/iperf_$name.txt 2>&1 &
  ssh $J $C "cd /root/rq; sleep 4; mf=\$(cat client_P0.pid); mf=\$(pgrep -P \$mf -x multi-fec-stati || echo \$mf)
    perf record -F 999 -g -p \$mf -o perf19_$name.data -- sleep 20 > /dev/null 2>&1
    LC_ALL=C perf stat -e raw_syscalls:sys_enter,context-switches,cpu-clock -p \$mf -- sleep 10 2> pstat19_$name.txt > /dev/null
    perf trace -s -p \$mf -- sleep 5 2> ptrace19_$name.txt > /dev/null
    perf report -i perf19_$name.data --stdio --no-children --sort dso 2>/dev/null | grep -E '^ +[0-9]|Samples' | head -12 > rep19_${name}_dso.txt
    perf report -i perf19_$name.data --stdio --no-children --sort sym -g none 2>/dev/null | grep -E '^ +[0-9]|Samples' | head -45 > rep19_${name}_self.txt
    perf report -i perf19_$name.data --stdio --children --sort sym -g none 2>/dev/null | grep -E '^ +[0-9]|Samples' | head -60 > rep19_${name}_children.txt"
  wait; }
prof tcp_up   "-P 8"
prof udp_up   "-u -b 200M -l 1200"
prof tcp_down "-P 8 -R"
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; done
scp -q $J "$C:/root/rq/rep19_*" "$C:/root/rq/pstat19_*" "$C:/root/rq/ptrace19_*" "$C:/root/rq/client_r19.log" raw19/
echo "done $(date +%T)"
