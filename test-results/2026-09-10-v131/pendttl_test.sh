#!/bin/bash
# pendttl_test.sh — v1.3.1 클라이언트 pending 큐 TTL 검증 (테스트망 전용)
#
# 왜 별도 시험인가: pending 큐는 mud EAGAIN·경로 단절에서만 쓰인다. 일반 소크는
# 이번 수정 코드를 **한 번도 실행하지 않는다.** 2026-09-09 SPOF 시험에서 관측한
# 조건(릴레이 2개 동시 정지 → 복구)을 반복 재현해 ① 묵은 패킷이 폐기되는지
# ② 반복 실행에서 RSS/FD 가 늘지 않는지를 본다.
#
# 기대 (v1.3.1): 복구 직후 첫 응답 RTT ≈ 정상(54 ms), 클라 로그에
#   "dropped N stale pending packet(s)" 가 사이클마다 남는다.
# 대조 (v1.3.0): 복구 직후 RTT 가 단절 길이만큼(수만 ms) 나오고 프로브 간격씩 감소.
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com
LABEL=${LABEL:-v131}; CYCLES=${CYCLES:-3}; DOWN=${DOWN:-26}; SETTLE=${SETTLE:-35}
OUT=${OUT:-/home/stevekim/multi-fec/test-results/2026-09-10-v131}
mark() { echo "$(date +%s.%N) $*" >> "$OUT/pend_${LABEL}_events.log"; echo "[$(date +%H:%M:%S)] $*"; }

: > "$OUT/pend_${LABEL}_events.log"
: > "$OUT/pend_${LABEL}_rss.log"

# 프로세스 자원 스냅샷 — PID 기준(문자열 매치 회피)
snap() {
  ssh $C 'p=$(systemctl show -p MainPID --value multi-fec-client); \
    [ "$p" = 0 ] && { echo "0 0 0"; exit 0; }; \
    r=$(awk "/VmRSS/{print \$2}" /proc/$p/status); f=$(ls /proc/$p/fd 2>/dev/null|wc -l); \
    c=$(awk "{print \$14+\$15}" /proc/$p/stat); echo "$p $r $f $c"' 2>/dev/null
}
echo "phase pid rss_kb fd cpu_ticks" >> "$OUT/pend_${LABEL}_rss.log"
echo "before $(snap)" >> "$OUT/pend_${LABEL}_rss.log"

ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.10.1'; exit 0" 2>/dev/null
ssh $C "setsid nohup ping -i 0.2 -D 10.9.10.1 </dev/null >/tmp/pend_${LABEL}.log 2>&1 & sleep 1; exit 0" 2>/dev/null
mark "프로브 시작 (5 pps over WG) — ${LABEL}"
sleep 15

i=1
while [ $i -le $CYCLES ]; do
  mark "cycle$i: 릴레이 2개 정지 (단절 ${DOWN}s)"
  ssh $R 'systemctl stop multi-fec-relay multi-fec-relay@b' 2>/dev/null
  sleep $DOWN
  mark "cycle$i: 복구"
  ssh $R 'systemctl start multi-fec-relay multi-fec-relay@b' 2>/dev/null
  sleep $SETTLE
  echo "cycle$i $(snap)" >> "$OUT/pend_${LABEL}_rss.log"
  mark "cycle$i: 완료"
  i=$((i+1))
done

echo "after $(snap)" >> "$OUT/pend_${LABEL}_rss.log"
ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.10.1'; exit 0" 2>/dev/null
ssh $C "cat /tmp/pend_${LABEL}.log" > "$OUT/pend_${LABEL}_ping.log" 2>/dev/null
ssh $C "journalctl -u multi-fec-client --since '-$((CYCLES*(DOWN+SETTLE)+120)) seconds' --no-pager -o cat" \
  > "$OUT/pend_${LABEL}_client.log" 2>/dev/null
mark "종료 — 릴레이 $(ssh $R 'systemctl is-active multi-fec-relay multi-fec-relay@b|tr "\n" " "' 2>/dev/null)"
wc -l "$OUT/pend_${LABEL}_ping.log"
