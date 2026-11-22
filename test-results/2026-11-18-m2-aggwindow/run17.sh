#!/bin/bash
# 서버 수신 MSG_PEEK 제거 A/B — 같은 바이너리(1.4.4 + SSSE3 + no-peek), 서버에 MF_PEEK=1 이면 기존 peek 루프.
# 조건 = run13/14 base: P0 터널 1개, aggregate, enp4s0 30 ms + enp1s0 54 ms, 손실 0.
# 변형마다: TCP -P 8 상·하향 30 s, UDP 200 Mbps 상·하향 20 s. 순서 peek·nopeek·peek·nopeek. 끝에 서버 perf(상향 UDP 20 s) 변형별 1회.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
BIN=/tmp/claude-1000/-home-stevekim-multi-fec/e0768082-ad60-4361-88b8-c886cc679895/scratchpad/wt-simd/multi-fec-static
cd "$(dirname "$0")"; mkdir -p raw17
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J $BIN $h:/root/rq/multi-fec-static.nopeek
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    md5sum multi-fec-static.nopeek | cut -c1-12'; done
ssh $J $S 'cd /root/rq; pkill -x iperf3; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s16x.log 2>&1 < /dev/null &)'

start() { local v=$1 envp=$2
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      $envp setsid timeout 1200 ./multi-fec-static.nopeek --config /root/rq/${2}_P0.conf > ${2}_r17_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2 perf=$3
  for h in $C $S; do n=${h##*.}; ssh $J $h "cd /root/rq; nstat -n; p=\$(cat *_P0.pid | head -1); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p)
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r17_${name}_pid.txt 2>&1 < /dev/null &
      ${perf:+[ $n = 92 ] && setsid timeout 22 perf record -F 999 -p \$mf -o /root/rq/perf16_${name}.data > /dev/null 2>&1 < /dev/null &}
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw17/iperf_$name.txt 2>&1
  sleep 3
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /multi-fec/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r17_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw17/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw17/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  else
    rx=$(grep -E "SUM.*receiver" raw17/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw17/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  fi; sleep 4; }
variant() { local v=$1 envp=$2 perf=$3; echo "== $v ($envp) $(date +%T)"; start $v "$envp"
  run ${v}_tcp_up   "-P 8 -t 30" $perf
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r17_$v.log) \$(grep 'pending queue full' /root/rq/client_r17_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }

variant peek1   "MF_PEEK=1"
variant nopeek1 ""
variant peek2   "MF_PEEK=1"
variant nopeek2 ""
# 서버 perf: 변형별로 다시 띄우고 상향 UDP 200M 동안 20 s 기록 (스크립트 안 perf 가 샘플 86개로 실패했던 run16 교훈 — 전경에서 기록)
for v in peek nopeek; do e=""; [ $v = peek ] && e="MF_PEEK=1"; start perf_$v "$e"
  ssh $J $C "sleep 2; iperf3 -c 10.89.0.1 -p 5201 -u -b 200M -l 1200 -t 26" > raw17/iperf_perf_$v.txt 2>&1 &
  ssh $J $S "cd /root/rq; sleep 4; p=\$(cat server_P0.pid); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p); perf record -F 999 -p \$mf -o perf17_\$(echo $v).data -- sleep 20 > /dev/null 2>&1; perf report -i perf17_$v.data --stdio --sort symbol 2>/dev/null | grep -E '^ +[0-9]|Samples' | head -25 > perf17_$v.txt"
  wait; done
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw17/${h##*.}; scp -q $J "$h:/root/rq/*_r17_*" "$h:/root/rq/r17_*" raw17/${h##*.}/ 2>/dev/null; done
scp -q $J "$S:/root/rq/perf17_*.txt" raw17/ 2>/dev/null
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; done
echo "done $(date +%T)"
