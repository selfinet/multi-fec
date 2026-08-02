#!/bin/bash
# mf_rt_multi.sh — 실토폴로지 다중 클라이언트 다운스트림 검증 (테스트망 전용)
#
# 왜: v1.0.2 가 고친 "다중 클라이언트 다운스트림 오배송"이 **실토폴로지에서 한 번도
#     확인된 적이 없다**. 기존 aging_rt_*.py 는 서버 sink 도착분(업스트림)만 본다.
#     이 결함은 "A 의 패킷이 B 의 경로로 나가 B 가 conv 불일치로 버림" 형태라
#     업스트림에는 안 나타난다. 서비스 가부 판단 항목.
#
# 구성: 운영(:443) 체인을 건드리지 않는 **병렬 체인(:4443)**.
#     c: 클라 N개 + blaster N개   r: 릴레이 2개   s: 서버 1개 + echo
#
# netem: 기본 필터는 dport 443 만 잡는다 → :4443 용 필터를 추가로 붙이고 끝나면 뗀다.
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com; S=s.xdn.selfinet.com
SRC=192.168.100.141; RA=192.168.100.85; RB=192.168.100.86; SRV=192.168.200.254
PORT=4443; SINK=44444; KEY=rtmulti-$(date +%s)
N=${N:-4}; SECS=${SECS:-300}; MBPS=${MBPS:-1.0}
GUARD=/home/stevekim/multi-fec/test-results/2026-08-02-50mbps-soak/mf_gwguard.sh
OUT=/tmp/claude-1000/-home-stevekim-multi-fec/09ddbccc-f6ab-4626-ba7c-12c7dc973215/scratchpad/rtmulti
mkdir -p $OUT

cleanup() {
  echo; echo "[$(date +%H:%M:%S)] 정리"
  ssh $C 'pkill -f rt_multi.py; pkill -f "multi-fec-dist -c -l 127.0.0.1:518[6-9]"' 2>/dev/null
  ssh $R "pkill -f 'multi-fec-dist -r -l 192.168.100.8[56]:$PORT'" 2>/dev/null
  ssh $S "pkill -f 'multi-fec-dist -s -l $SRV:$PORT'; pkill -f rt_echo.py" 2>/dev/null
  # netem 원복(서비스 재시작 = 설정파일 기준 재구성 → 추가 필터 소멸)
  for h in $C $R; do ssh $h 'sudo systemctl restart mf-netem' 2>/dev/null; done
  echo "  운영 체인 상태:"
  ssh $C 'systemctl is-active multi-fec-client' 2>/dev/null | sed 's/^/    c /'
  ssh $S 'systemctl is-active multi-fec-server' 2>/dev/null | sed 's/^/    s /'
  ssh $C 'tc qdisc show | grep -oE "delay [0-9]+ms loss [0-9]+%" | tr "\n" " "' 2>/dev/null | sed 's/^/    netem /'; echo
}
trap cleanup EXIT INT TERM

echo "=== 예산 사전 판정 (세션 $N × 각 방향 ${MBPS} Mbps, 왕복) ==="
GW_BASE=${GW_BASE:-40} $GUARD budget $MBPS $N || { echo "예산 초과 — 중단"; exit 1; }

echo; echo "=== :$PORT 에도 netem 적용 (경로별 flowid — 기본 필터는 443 만 잡는다) ==="
# c(상향): 목적지 주소로 경로 구분.  r(하향): 출발 주소로 구분.
ssh $C "IF=\$(ip -o -4 route show default | awk '{print \$5}' | head -1)
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip dst $RA/32 match ip dport $PORT 0xffff flowid 1:1
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip dst $RB/32 match ip dport $PORT 0xffff flowid 1:2" 2>/dev/null
ssh $R "IF=\$(ip -o -4 route show default | awk '{print \$5}' | head -1)
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip src $RA/32 match ip sport $PORT 0xffff flowid 1:1
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip src $RB/32 match ip sport $PORT 0xffff flowid 1:2" 2>/dev/null
for h in $C $R; do
  printf "  %-3s flowid 별 필터: " ${h%%.*}
  ssh $h 'tc filter show dev $(ip -o -4 route show default | awk "{print \$5}" | head -1) parent 1: 2>/dev/null | grep -oE "flowid 1:[12]" | sort | uniq -c | tr "\n" " "' 2>/dev/null; echo
done

echo; echo "=== 병렬 체인 기동 ==="
ssh $S "nohup /tmp/rt_echo.py $SINK >/tmp/rtecho.log 2>&1 & sleep 0.3; echo '  s: echo :$SINK'" 2>/dev/null
ssh $S "nohup /usr/sbin/multi-fec-dist -s -l $SRV:$PORT --wg 127.0.0.1:$SINK -k $KEY \
        --obfs-mode quic --auth-interval 60 --multipath-mode duplicate -f 5:1,20:4 \
        --fec-timeout 10 --mode 1 --mtu 1350 --decode-buf 2000 --queue-len 500 \
        --sock-buf 4096 --log-level 4 >/tmp/rtsrv.log 2>&1 & sleep 0.5; echo '  s: server :$PORT'" 2>/dev/null
for A in $RA $RB; do
  ssh $R "nohup /usr/sbin/multi-fec-dist -r -l $A:$PORT --route '$KEY $SRV:$PORT' \
          --obfs-mode quic --auth-interval 60 --log-level 4 >/tmp/rtrelay_${A##*.}.log 2>&1 & sleep 0.3; echo '  r: relay $A:$PORT'" 2>/dev/null
done
sleep 3

echo; echo "=== CPU/RSS 샘플러 + gw 워치독 ==="
ssh $C "nohup /tmp/rt_sample.sh 'multi-fec-dist -c -l 127.0.0.1:518' /tmp/rt_c.csv $((SECS+120)) >/dev/null 2>&1 &" 2>/dev/null
ssh $S "nohup /tmp/rt_sample.sh 'multi-fec-dist -s -l $SRV:$PORT' /tmp/rt_s.csv $((SECS+120)) >/dev/null 2>&1 &" 2>/dev/null
GW_BASE=${GW_BASE:-37} nohup $GUARD watch "rt_multi.py" > $OUT/watchdog.log 2>&1 &
WD=$!
echo "  샘플러 c/s, 워치독 pid=$WD (기저 ${GW_BASE:-40} 가정)"

echo; echo "=== 부하 ${SECS}s (세션 $N, 각 방향 ${MBPS} Mbps) ==="
ssh $S "nohup bash -c 'for i in \$(seq 1 $((SECS/5+8))); do awk -v k=ens18: \"\\\$1==k{print systime(), \\\$2+\\\$10}\" /proc/net/dev; sleep 5; done > /tmp/rtgw.csv' >/dev/null 2>&1 &" 2>/dev/null
ssh $C "python3 /tmp/rt_multi.py --sessions $N --secs $SECS --mbps $MBPS --src $SRC \
        --relay-a $RA:$PORT --relay-b $RB:$PORT --key $KEY" 2>/dev/null | tee $OUT/result.csv

kill $WD 2>/dev/null
echo; echo "=== gw 실사용 (s ens18 RX+TX, 10초 창) ==="
ssh $S 'cat /tmp/rtgw.csv' 2>/dev/null | python3 -c "
import sys
v=[int(l.split()[1]) for l in sys.stdin if len(l.split())==2]
d=[(v[i+1]-v[i])*8/5/1e6 for i in range(len(v)-1)]
d=[x for x in d if x>0.3]
print(f'  창 {len(d)}개  평균 {sum(d)/len(d):.1f}  최대 {max(d):.1f} Mbps   (우리 몫, 한도 70 − 기저 23 = 47)') if d else print('  데이터 없음')"
