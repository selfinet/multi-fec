#!/bin/bash
# mf_aging_1h.sh — c→r→s 실토폴로지 1시간 에이징 (테스트망 전용)
#
# 목적 2가지
#   ① CPU·메모리 누수 확인 — 램프가 끝난 뒤 RSS 기울기가 0 인가
#   ② 트래픽 격납 확인     — 전 구간이 192.168.100.0/24 온링크이므로
#                            테스트망 밖 인터페이스는 부하 중에도 유휴여야 한다
#
# 2026-08-03 `mf_rt_multi.sh` 에서 갱신한 것 (그대로 쓰면 안 되는 이유)
#   - SRV 192.168.200.254 → **192.168.100.84**  (2026-08-05 s 리슨 이전)
#   - 가드 인터페이스 변경: GW_BASE 폐지, `budget` 인자가 **양방향** Mbps
#   - gw 대리지표(s ens18 RX+TX) 폐지 → 전 인터페이스 델타로 격납을 직접 확인
#
# 구성: 운영(:443) 체인 무침습 **병렬 체인(:4443)**
#     c: 클라 N개 + blaster N개   r: 릴레이 2개   s: 서버 1개 + echo
#   blaster_i ─▶ client_i ─mud─▶ [relay×2] ─▶ server ─▶ echo ─▶ (역방향)
#   왕복이므로 하향(§19-가 결함 축)까지 검증한다.
#
# netem: 기본 필터는 dport 443 만 잡는다 → :4443 용 필터를 추가하고 끝나면 뗀다
#        (측정 하네스 함정 #4 — 안 하면 임피어먼트를 전혀 안 받는다)
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com; S=s.xdn.selfinet.com
SRC=192.168.100.141; RA=192.168.100.85; RB=192.168.100.86; SRV=192.168.100.84
PORT=4443; SINK=44444; KEY=aging1h-$(date +%s)
N=${N:-8}; SECS=${SECS:-3600}; MBPS=${MBPS:-0.25}     # MBPS = 세션당 각 방향
GUARD=/home/stevekim/multi-fec/test-results/2026-08-02-50mbps-soak/mf_gwguard.sh
OUT=${OUT:-/home/stevekim/multi-fec/test-results/2026-08-07-aging-1h/raw}
mkdir -p "$OUT"

# 전 호스트 전 인터페이스 누적 바이트 스냅샷 (원격 시계로 epoch 도 같이)
ifsnap() {   # $1 = 라벨
  for h in $C $R $S; do
    ssh -o ConnectTimeout=5 "$h" "awk -v H=${h%%.*} -v L=$1 -v T=\$(date +%s) '
      NR>2 { gsub(/:/,\"\",\$1); if (\$1!=\"lo\") print L, H, \$1, \$2, \$10, T }' /proc/net/dev" 2>/dev/null
  done
}

cleanup() {
  echo; echo "[$(date +%H:%M:%S)] 정리"
  # ⚠️ 포트 범위 [6-9] 를 반드시 남길 것. `127.0.0.1:518` 로 줄이면 **운영 클라이언트
  # (:51821)** 까지 매치해 죽인다 — 2026-08-07 첫 런에서 실제로 그렇게 죽였다.
  # 시험 클라는 51861~51868, 운영은 51821 이다.
  ssh $C 'pkill -f "[r]t_multi.py"; pkill -f "[m]ulti-fec-dist -c -l 127.0.0.1:518[6-9]"' 2>/dev/null
  ssh $R "pkill -f '[m]ulti-fec-dist -r -l 192.168.100.8[56]:$PORT'" 2>/dev/null
  ssh $S "pkill -f '[m]ulti-fec-dist -s -l $SRV:$PORT'; pkill -f '[r]t_echo.py'" 2>/dev/null
  # netem 원복 (서비스 재시작 = 설정파일 기준 재구성 → 추가 필터 소멸)
  for h in $C $R; do ssh $h 'sudo systemctl restart mf-netem' 2>/dev/null; done
  echo "  운영 체인:"
  ssh $C 'systemctl is-active multi-fec-client' 2>/dev/null | sed 's/^/    c multi-fec-client /'
  ssh $R 'systemctl is-active multi-fec-relay multi-fec-relay@b | tr "\n" " "' 2>/dev/null | sed 's/^/    r relay /'; echo
  ssh $S 'systemctl is-active multi-fec-server' 2>/dev/null | sed 's/^/    s multi-fec-server /'
  ssh $C 'tc qdisc show | grep -oE "delay [0-9]+ms loss [0-9]+%" | tr "\n" " "' 2>/dev/null | sed 's/^/    netem /'; echo
}
trap cleanup EXIT INT TERM

echo "=== 0. 사전 판정 (세션 $N × 각 방향 ${MBPS} Mbps) ==="
$GUARD budget "$(awk -v m=$MBPS 'BEGIN{print m*2}')" "$N" || { echo "예산 초과 — 중단"; exit 1; }

echo; echo "=== 1. 가드 precheck (전제 검증, 트래픽 미발생) ==="
$GUARD precheck || { echo "precheck 실패 — 중단"; exit 1; }

echo; echo "=== 2. 유휴 기준선 (부하 전 60초, 격납 대조용) ==="
ifsnap idle0 > $OUT/ifsnap.txt
sleep 60
ifsnap idle1 >> $OUT/ifsnap.txt
echo "  유휴 60초 스냅샷 완료"

echo; echo "=== 3. :$PORT 에 netem 적용 (기본 필터는 443 만 잡는다) ==="
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

echo; echo "=== 4. 병렬 체인 기동 ==="
ssh $S "nohup /tmp/rt_echo.py $SINK >/tmp/rtecho.log 2>&1 & sleep 0.3" 2>/dev/null
ssh $S "nohup /usr/sbin/multi-fec-dist -s -l $SRV:$PORT --wg 127.0.0.1:$SINK -k $KEY \
        --obfs-mode quic --auth-interval 60 --multipath-mode duplicate -f 5:1,20:4 \
        --fec-timeout 10 --mode 1 --mtu 1350 --decode-buf 2000 --queue-len 500 \
        --sock-buf 4096 --log-level 4 >/tmp/rtsrv.log 2>&1 & sleep 0.5" 2>/dev/null
for A in $RA $RB; do
  ssh $R "nohup /usr/sbin/multi-fec-dist -r -l $A:$PORT --route '$KEY $SRV:$PORT' \
          --obfs-mode quic --auth-interval 60 --log-level 4 >/tmp/rtrelay_${A##*.}.log 2>&1 & sleep 0.3" 2>/dev/null
done
sleep 3
# 함정 #5 — 기동 확인에 실패하면 즉시 중단한다 (무효 데이터를 만들지 않기 위해)
ECHO_N=$(ssh $S 'pgrep -cf "[r]t_echo.py"' 2>/dev/null || echo 0)
SRV_N=$(ssh $S "pgrep -cf '[m]ulti-fec-dist -s -l $SRV:$PORT'" 2>/dev/null || echo 0)
REL_N=$(ssh $R "pgrep -cf '[m]ulti-fec-dist -r -l 192.168.100.8'" 2>/dev/null || echo 0)
echo "  s echo=$ECHO_N  s server=$SRV_N  r relay=$REL_N  (1/1/2 이어야 함)"
[ "$ECHO_N" -ge 1 ] && [ "$SRV_N" -ge 1 ] && [ "$REL_N" -ge 2 ] || { echo "  ✗ 기동 실패 — 중단"; exit 1; }

echo; echo "=== 5. 샘플러 + 가드 ==="
ssh $C "nohup /tmp/rt_sample.sh 'multi-fec-dist -c -l 127.0.0.1:518' /tmp/ag_c.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $S "nohup /tmp/rt_sample.sh 'multi-fec-dist -s -l $SRV:$PORT' /tmp/ag_s.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $R "nohup /tmp/rt_sample.sh 'multi-fec-dist -r -l 192.168.100.8' /tmp/ag_r.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
nohup $GUARD watch "rt_multi.py" > $OUT/watchdog.log 2>&1 &
WD=$!
sleep 12
kill -0 $WD 2>/dev/null && echo "  가드 살아있음 pid=$WD" || { echo "  ✗ 가드가 죽었다 — 중단"; exit 1; }
echo "  샘플러 c/r/s 기동"

echo; echo "=== 6. 부하 ${SECS}s (세션 $N, 각 방향 ${MBPS} Mbps) — $(date +%H:%M:%S) 시작 ==="
ifsnap load0 >> $OUT/ifsnap.txt
ssh $C "python3 /tmp/rt_multi.py --sessions $N --secs $SECS --mbps $MBPS --src $SRC \
        --relay-a $RA:$PORT --relay-b $RB:$PORT --key $KEY" 2>$OUT/rt_multi.err | tee $OUT/result.csv
ifsnap load1 >> $OUT/ifsnap.txt

kill $WD 2>/dev/null
echo; echo "=== 7. 샘플 회수 ==="
ssh $C 'cat /tmp/ag_c.csv' > $OUT/sample_c.csv 2>/dev/null
ssh $R 'cat /tmp/ag_r.csv' > $OUT/sample_r.csv 2>/dev/null
ssh $S 'cat /tmp/ag_s.csv' > $OUT/sample_s.csv 2>/dev/null
wc -l $OUT/sample_*.csv
echo "  가드 로그: $(grep -c 초과 $OUT/watchdog.log 2>/dev/null || echo 0) 건 초과, 트립 $(grep -c 트립 $OUT/watchdog.log 2>/dev/null || echo 0) 건"
