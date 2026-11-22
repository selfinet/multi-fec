#!/bin/bash
# 비용 분해 (1.4.4, 기호 포함 static 빌드 = dist 와 같은 코드): base / nofec / noobfs / fec20:2 / nofec+noobfs
# 각 변형 상·하향 TCP 8연결 30 s ×2 회. base 상향 중 client·server perf record.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw4
restart() { T=$1; X="$2"; for pair in "$S server" "$C client"; do set -- $pair; ssh $J $1 "cd /root/rq; kill \$(cat $2.pid) 2>/dev/null; sleep 1
    setsid timeout 1800 ./multi-fec-static.v144 --config /root/rq/$2.conf $X > ${2}_r4_$T.log 2>&1 < /dev/null & echo \$! > $2.pid"; done; sleep 8
  ssh $J $C "ping -c 5 -i 0.3 -q 10.89.0.1 | tail -1"; }
snap() { for h in $C $S; do ssh $J $h "nstat -az UdpRcvbufErrors UdpInErrors UdpSndbufErrors | tail -n +2" | sed "s/^/${h##*.} /"; done; }
run() { echo "== $1 $(date +%T)"; snap > raw4/nstat_$1_a.txt
  for h in $C $S; do n=${h##*.}; ssh $J $h "cd /root/rq; p=\$(cat client.pid server.pid 2>/dev/null | head -1); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p);
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r4_$1_pid_$n.txt 2>&1 < /dev/null &
      ${3:+setsid timeout 25 perf record -F 999 -g -p \$mf -o /root/rq/perf_$1_$n.data > /dev/null 2>&1 < /dev/null &}"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -P 8 -t 30 -i 1 $2" > raw4/iperf_$1.txt 2>&1
  snap > raw4/nstat_$1_b.txt
  grep -E "SUM.*receiver" raw4/iperf_$1.txt; sleep 4; }
for h in $C $S; do scp -q $J /tmp/claude-1000/-home-stevekim-multi-fec/e0768082-ad60-4361-88b8-c886cc679895/scratchpad/wt144/multi-fec-static $h:/root/rq/multi-fec-static.v144; done
ssh $J $S "cd /root/rq; pgrep -x iperf3 >/dev/null || { setsid timeout 3600 iperf3 -s -B 10.89.0.1 > iperf_s.log 2>&1 < /dev/null & echo \$! > iperf.pid; }"
for v in "base:" "nofec:--disable-fec" "noobfs:--disable-obfs" "f202:-f 20:2" "bare:--disable-fec --disable-obfs"; do
  tag=${v%%:*}; X=${v#*:}; echo "#### $tag ($X)"; restart $tag "$X"
  for r in 1 2; do P=""; [ $tag = base ] && [ $r = 1 ] && P=1
    run ${tag}_up$r "" $P; run ${tag}_down$r "-R"; done
done
for h in $C $S; do scp -q $J "$h:/root/rq/*_r4_*.log" "$h:/root/rq/r4_*" raw4/; done
echo done
