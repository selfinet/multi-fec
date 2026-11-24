#!/bin/bash
# run60 — mt.2 worker 3개 aggregate 절체 시험 (2026-11-23, 사용자 "mt.2 worker 3개로 절체 실험 진행해 줘")
#   변형 A(--workers 3 --worker-cpus 0,1,2, 창 2배 기본), rps 8, 터널 1개, nr(IFB 60/108 ms, 무제한·무손실).
#   차단: .92 에서 iptables 전용 체인 R60 으로 경로 하나의 UDP 를 양방향(INPUT -s / OUTPUT -d) 30초 버린다.
#     경로 A = 172.31.10.1 (enp4s0, 30 ms) · 경로 B = 172.31.20.1 (enp1s0, 54 ms). worker 3개의 server 포트 443~445 모두 해당.
#   시간표(구간 270초): 0~30 정상 · 30~60 A 차단 · 60~90 정상 · 90~120 B 차단 · 120~150 정상 · 150~180 A · 180~210 정상 · 210~240 B · 240~270 정상.
#   구간: TCP -P8 상향 · -P8 하향(-R) · -P1 상향. 기록: iperf3 1초, ping 0.2초(-D), 차단 시각(.92 시계), multi-fec 로그.
#   run15(v1.4.4, 케이블 분리)와 달리 carrier 는 살아 있다 — mud 입장에서는 그 경로 무수신과 같다.
RUN=r60; RAW=raw60
cd "$(dirname "$0")"; . ./lib.sh
DUR=270; TO=3000
echo "== setup $(date +%T)"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

FW_DOWN='iptables -D INPUT -j R60 2>/dev/null; iptables -D OUTPUT -j R60 2>/dev/null; iptables -F R60 2>/dev/null; iptables -X R60 2>/dev/null
  echo "$MFROLE iptables R60 제거: 남은 R60 줄 $(iptables -S | grep -c R60)"'
for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; (setsid timeout $TO ip netns exec hq iperf3 -s > iperf_hq_${RUN}.log 2>&1 < /dev/null &)"
env_up
trap 'rsh $C "$FW_DOWN"; restore2' EXIT
rsh $C 'iptables -N R60 && iptables -I INPUT 1 -j R60 && iptables -I OUTPUT 1 -j R60 && echo "$MFROLE iptables R60 준비 (비어 있음)"'
setnet 0 0

start() { local v=$1 pair; stopall; setrps 8; route 1
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; setsid timeout $TO ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 12
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c mmulti-fec-dist)\""; }

# 차단 스케줄 — .92 에서 직접 sleep 으로 돈다(ssh 지연 없음). 각 전환 시각을 기록.
# ⚠️ 함수 이름을 cut 등 명령 이름으로 짓지 말 것 — 첫 실행(10:31)에서 cut() 이 log 안의 `| cut` 을 가로채 무한 재귀·프로세스 폭증(.92 부하 220)을 냈다.
CUTS='stamp() { echo "$(date +%T.%3N) $*" >> /root/rq/${RUN}_${NAME}_cuts.txt; }
  pathdrop() { iptables -A R60 -s $1 -p udp -j DROP; iptables -A R60 -d $1 -p udp -j DROP; stamp "drop $2 $1"; }
  pathheal() { iptables -F R60; stamp "heal"; }
  stamp start; sleep 30
  pathdrop 172.31.10.1 A; sleep 30; pathheal; sleep 30
  pathdrop 172.31.20.1 B; sleep 30; pathheal; sleep 30
  pathdrop 172.31.10.1 A; sleep 30; pathheal; sleep 30
  pathdrop 172.31.20.1 B; sleep 30; pathheal; stamp end'

seg() { local name=$1 P=$2 A=$3 h
  echo "-- $name $(date +%T)  (-P$P $A, ${DUR}초)"
  for h in $C $S; do rsh $h "nstat -n; cd /root/rq; (LC_ALL=C mpstat -P ALL 1 $DUR > ${RUN}_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  rsh $C "cd /root/rq; (ip netns exec ue ping -D -i 0.2 -c $((DUR*5)) -W 2 10.90.0.10 > ${RUN}_${name}_ping.txt 2>&1 < /dev/null &)"
  rsh $C "cd /root/rq; (RUN=$RUN NAME=$name setsid timeout $((DUR+30)) bash -c '$CUTS' < /dev/null > /dev/null 2>&1 &)"
  rsh $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t $DUR -i 1 --timestamps='%T ' --forceflush $A" > "$RAW/iperf_$name.txt" 2>&1
  sleep 4
  rsh $C "iptables -F R60; cat /root/rq/${RUN}_${name}_cuts.txt" > "$RAW/cuts_$name.txt"
  rsh $C "cat /root/rq/${RUN}_${name}_ping.txt" > "$RAW/ping_$name.txt"
  echo "  recv $(mbps "$RAW/iperf_$name.txt") Mbps | retr $(grep -E 'sender' "$RAW/iperf_$name.txt" | tail -1 | awk '{print $(NF-1)}') | ping $(tail -2 "$RAW/ping_$name.txt" | head -1)"
  echo "  rcvbuf c/s $(for h in $C $S; do rsh $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n /; done) | cuts $(paste -sd' ' "$RAW/cuts_$name.txt" | cut -c1-200)"
  sleep 5; }

echo "== A worker 3 $(date +%T)"
start A
seg p8_up 8 ""
seg p8_dn 8 "-R"
seg p1_up 1 ""
logsum A
for h in $C $S; do rsh $h "cd /root/rq; echo \"  \$MFROLE 경로 경고 \$(grep -saE 'no RUNNING path' *_${RUN}_A.log | wc -l) / 재개 \$(grep -saE 'RUNNING again' *_${RUN}_A.log | wc -l) / stale \$(grep -saoE 'dropped [0-9]+ stale' *_${RUN}_A.log | awk '{s+=\$2} END{print s+0}') / procs \$(pgrep -c mmulti-fec-dist)\""; done
stopall
rget
echo "done $(date +%T)"
