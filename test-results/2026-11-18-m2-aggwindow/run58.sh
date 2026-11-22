#!/bin/bash
# run58 — 동시 30세션 3시간 aging: worker 3개(rps 8, 터널 1개), nr(무제한 무손실 IFB 60/108 ms), run57 에서 고른 변형.
#   상향 iperf3 -P 15 (5201) + 하향 -R -P 15 (5202) 를 3시간 동시에. dist 3c965d14.
# 2026-11-23 사용자 "그대로 진행해줘". 쓰는 법: VAR=A|B|C ./run58.sh   (A 기본 · B +--pend-fifo · C +--pend-fifo --win-unlimited)
# 1분마다 raw58/samples.csv: 처리량(마지막 10초 SUM)·재전송(netns TcpRetransSegs 누적)·RSS·FD·CPU 유휴·UdpRcvbufErrors·로그 누적·프로세스 수.
RUN=r58; RAW=raw58
cd "$(dirname "$0")"; . ./lib.sh
: "${VAR:?VAR=A|B|C 로 변형을 정할 것}"
case $VAR in A) XA="";; B) XA="--pend-fifo";; C) XA="--pend-fifo --win-unlimited";; *) echo "VAR=$VAR 모름"; exit 1;; esac
DUR=${DUR:-10800}                 # aging 초 (기본 3시간)
TO=$((DUR + 900))                 # 모든 원격 프로세스의 timeout — 하네스가 죽어도 저절로 끝난다
SAMPLE=${SAMPLE:-60}
echo "== setup $(date +%T)  VAR=$VAR XA='$XA' DUR=$DUR"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; for p in 5201 5202; do (setsid timeout $TO ip netns exec hq iperf3 -s -p \$p > iperf_hq_${RUN}_\$p.log 2>&1 < /dev/null &); done"
env_up
setnet 0 0

echo "== start multi-fec workers 3 ($VAR) $(date +%T)"
stopall; setrps 8; route 1
for pair in "$S server" "$C client"; do set -- $pair
  rsh $1 "cd /root/rq; setsid timeout $TO ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 $XA > ${2}_MT_${RUN}_$VAR.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
sleep 10
rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c multi-fec-dist)\""

echo "== start load $(date +%T)"
rsh $C "cd /root/rq
  (setsid timeout $TO ip netns exec ue iperf3 -c 10.90.0.10 -p 5201 -P 15 -t $DUR -i 10 --forceflush > ${RUN}_up.txt 2>&1 < /dev/null &)
  (setsid timeout $TO ip netns exec ue iperf3 -c 10.90.0.10 -p 5202 -P 15 -t $DUR -i 10 --forceflush -R > ${RUN}_dn.txt 2>&1 < /dev/null &)
  (setsid timeout $TO ip netns exec ue ping -D -i 0.2 -c $((DUR * 5)) -W 2 10.90.0.10 > ${RUN}_ping.txt 2>&1 < /dev/null &)"
for h in $C $S; do rsh $h "cd /root/rq; (setsid timeout $TO sh -c 'LC_ALL=C mpstat -P ALL $SAMPLE $((DUR / SAMPLE))' > ${RUN}_mpstat.txt 2>&1 < /dev/null &)"; done

# 1분 샘플러 — 원격 한 번 호출로 한 줄씩
SC='cd /root/rq
mf=$(pgrep -d, -f "^[^ ]*mmulti-fec-dist --config"); n=$(echo "$mf" | tr , "\n" | grep -c .)
rss=0; fd=0; for p in $(echo $mf | tr , " "); do r=$(awk "/VmRSS/{print \$2}" /proc/$p/status 2>/dev/null); rss=$((rss + ${r:-0})); fd=$((fd + $(ls /proc/$p/fd 2>/dev/null | wc -l))); done
ub=$(awk "/^Udp:/{c++} /^Udp:/ && c==2{print \$6}" /proc/net/snmp)
ns=$(ip netns list | cut -d" " -f1); rt=$(ip netns exec $ns awk "/^Tcp:/{c++} /^Tcp:/ && c==2{print \$13}" /proc/net/snmp)
cpu=$(awk "/^cpu /{print \$2+\$3+\$4+\$6+\$7+\$8, \$5}" /proc/stat)
lg=$(cat *_MT_'"$RUN"'_*.log 2>/dev/null | tr -d "\000" | awk "/EAGAIN/{e++} /pending queue full/{p++} /ERROR|FATAL/{x++} END{printf \"%d %d %d\", e, p, x}")
up=""; dn=""; [ -f '"$RUN"'_up.txt ] && up=$(grep SUM '"$RUN"'_up.txt | grep -v -e sender -e receiver | tail -1 | awk "{for(i=1;i<=NF;i++) if(\$i ~ /bits\\/sec/){v=\$(i-1); if(\$i ~ /^G/) v*=1000; if(\$i ~ /^K/) v/=1000; print v}}")
[ -f '"$RUN"'_dn.txt ] && dn=$(grep SUM '"$RUN"'_dn.txt | grep -v -e sender -e receiver | tail -1 | awk "{for(i=1;i<=NF;i++) if(\$i ~ /bits\\/sec/){v=\$(i-1); if(\$i ~ /^G/) v*=1000; if(\$i ~ /^K/) v/=1000; print v}}")
ip=$(pgrep -xc iperf3)
echo "$MFROLE,$n,$rss,$fd,$ub,$rt,$cpu,$lg,${up:-},${dn:-},$ip"'
echo "t,role,mfprocs,rss_kb,fds,udp_rcvbuf_err,tcp_retrans_netns,cpu_busy_jiffies cpu_idle_jiffies,eagain pendfull err,up_mbps,dn_mbps,iperf3" > "$RAW/samples.csv"
t0=$(date +%s); end=$((t0 + DUR + 60)); i=0
while [ "$(date +%s)" -lt $end ]; do
  ts=$(date +%FT%T)
  for h in $C $S; do echo "$ts,$(rsh $h "$SC" 2>&1 | tail -1)" >> "$RAW/samples.csv"; done
  i=$((i+1)); if [ $((i % 15)) -eq 1 ]; then tail -2 "$RAW/samples.csv" | sed 's/^/  /'; fi
  # 프로세스 소실 감지 — 둘 중 한쪽 worker 수가 4 미만이면 기록만 하고 계속(timeout 으로 끝난다)
  tail -2 "$RAW/samples.csv" | awk -F, '$3 < 4 {print "  !! " $2 " mfprocs=" $3 " at " $1}'
  sleep $((SAMPLE - ($(date +%s) - t0) % SAMPLE))
done

echo "== load end $(date +%T)"
rsh $C "pkill -x iperf3; sleep 2; tail -4 /root/rq/${RUN}_up.txt; tail -4 /root/rq/${RUN}_dn.txt" | grep -E 'sender|receiver'
logsum $VAR
stopall
rget
echo "done $(date +%T)"
