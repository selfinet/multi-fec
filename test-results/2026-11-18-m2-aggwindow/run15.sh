#!/bin/bash
# 절체 시험 (v1.4.4, aggregate): 사용자가 케이블을 직접 뽑고 꽂는다.
#  path1 172.31.10.1 = enp4s0 (netem 30 ms), path2 172.31.20.1 = enp1s0 (netem 54 ms), 손실 0.
#  측정: TCP iperf3 -P 8 상향(.92→.93) 초당 + 타임스탬프, .92 링크 carrier 0.1초 폴링, client 경로 로그(report 1초).
# 사용: ./run15.sh setup      # 터널 기동·확인
#       ./run15.sh go [초]     # 측정 시작 (기본 600초) — 이 동안 케이블을 뽑고 꽂는다
#       ./run15.sh collect    # 원자료 회수
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw15
case "$1" in
setup)
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1
      tc qdisc del dev rq-wg root 2>/dev/null
      sed -e 's/^report .*/report         = 1/' ${2}_P0.conf > ${2}_r15.conf
      setsid timeout 3600 ./multi-fec-static.v144 --config /root/rq/${2}_r15.conf > ${2}_r15.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s15.log 2>&1 < /dev/null &)'
  sleep 8
  ssh $J $C 'ping -c 5 -i 0.3 -q 10.89.0.1 | tail -1; for i in enp4s0 enp1s0; do echo "$i carrier=$(cat /sys/class/net/$i/carrier)"; done
    grep -h "path\[" /root/rq/client_r15.log | tail -2; /root/rq/multi-fec-static.v144 --version | head -1' ;;
go)
  D=${2:-600}
  # 링크 상태 변화 기록 (.92, 0.1초)
  ssh $J $C "cd /root/rq; (setsid timeout $((D+20)) bash -c 'p=\"\"; while :; do s=\"\$(cat /sys/class/net/enp4s0/carrier)\$(cat /sys/class/net/enp1s0/carrier)\"; [ \"\$s\" != \"\$p\" ] && echo \"\$(date +%T.%N | cut -c1-12) enp4s0=\${s:0:1} enp1s0=\${s:1:1}\"; p=\$s; sleep 0.1; done' > r15_carrier.txt 2>&1 < /dev/null &)"
  ssh $J $S "cd /root/rq; (setsid timeout $((D+20)) bash -c 'p=\"\"; while :; do s=\"\$(cat /sys/class/net/enp4s0/carrier)\$(cat /sys/class/net/enp1s0/carrier)\"; [ \"\$s\" != \"\$p\" ] && echo \"\$(date +%T.%N | cut -c1-12) enp4s0=\${s:0:1} enp1s0=\${s:1:1}\"; p=\$s; sleep 0.1; done' > r15_carrier.txt 2>&1 < /dev/null &)"
  echo "== 측정 시작 $(date +%T), ${D}초 — 지금부터 케이블을 뽑고 꽂으면 된다"
  ssh $J $C "cd /root/rq; iperf3 -c 10.89.0.1 -p 5201 -P 8 -t $D --timestamps='%T ' --forceflush 2>&1 | grep -E 'SUM|error' > r15_iperf.txt"
  echo "== 측정 끝 $(date +%T)" ;;
collect)
  for h in $C $S; do mkdir -p raw15/${h##*.}; scp -q $J "$h:/root/rq/r15_*" "$h:/root/rq/*_r15.log" raw15/${h##*.}/ 2>/dev/null; done
  ls raw15/* ;;
*) sed -n '2,9p' "$0" ;;
esac
