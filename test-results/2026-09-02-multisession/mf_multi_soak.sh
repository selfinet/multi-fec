#!/bin/bash
# mf_multi_soak.sh — 다중 세션 **지속 한계** 소크 (테스트망 전용)
#
# 유래: test-results/2026-08-07-aging-1h/mf_aging_1h.sh (저부하 에이징)
# 2026-09-02 에 고레이트용으로 두 곳을 고쳤다:
#   ① budget 을 **하드 게이트 → 정보 출력**으로. 원본은 `|| exit 1` 이라
#      MBPS=4 N=4 에서 반드시 중단된다(비용 3.50 vs 예산 2.00). 용량 모델은
#      12 Mbps 한 점 외삽이라 고배율에서 1.9~2.1배 과대함이 12/14/16 런으로
#      확인됐다. 실제 게이트는 precheck 와 가드이며 그 둘은 그대로 강제한다.
#   ② 부하 생성기 rt_multi.py(Python) → mf_blast(C). 이유는 CPU 가 아니라
#      **격리**다 — 생성기 비용이 c 전체 CPU 에 잡혀 가드 임계(62%)를 먹는데,
#      고레이트에서는 그 몫이 무시할 수 없다. C 판은 RSS 0.77 MB, sv1 기준
#      CPU 17%(Python 22%). ⚠️ c(Atom)에서의 비교는 실행 직전에 따로 잰다.
#
# (원본 설명)
# c→r→s 실토폴로지 에이징
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
N=${N:-4}; SECS=${SECS:-3600}; MBPS=${MBPS:-4}        # MBPS = 세션당 각 방향
GUARD=/home/stevekim/multi-fec/test-results/2026-08-02-50mbps-soak/mf_gwguard.sh
OUT=${OUT:-/home/stevekim/multi-fec/test-results/2026-09-02-multisession/raw}
# ── 온호스트 샘플러 CSV 경로에 런 식별자 (2026-09-09) ──────────────────
# 왜: 경로가 `/tmp/<pre>_c.csv` 로 **고정**이면 연속 장시간 런에서 충돌한다.
# 2026-09-07 24시간 소크에서 실제로 겪었다 — 1차가 17시간에 트립으로 끝났어도
# 샘플러 수명(SECS+600 = 24.2시간)이 남아 계속 돌았고, 2차 샘플러와 **같은 파일에
# 동시 기록**해 중복 행이 생겼다. 게다가 잔존 샘플러 하나가 **가드 초과를 14배로**
# 만들었다(임계 근처에서는 계측 도구 자신의 부하가 결과를 바꾼다).
RUNID=${RUNID:-$(basename "${OUT:-run}")-$(date +%m%d%H%M%S)}

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
  ssh $C 'pkill -f "[m]f_blast"; pkill -f "[m]ulti-fec-dist -c -l 127.0.0.1:518[6-9]"' 2>/dev/null
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
$GUARD budget "$(awk -v m=$MBPS 'BEGIN{print m*2}')" "$N" || true
echo "  ↑ 초과 표시는 예상된 것이다 — 모델이 고배율에서 1.9~2.1배 과대하다."
echo "    실제 게이트는 아래 precheck 와 가드다."

echo; echo "=== 1. 가드 precheck (전제 검증, 트래픽 미발생) ==="
$GUARD precheck || { echo "precheck 실패 — 중단"; exit 1; }

echo; echo "=== 1-1. 하네스 배포·검증 ==="
# c 는 2026-08-24 재부팅으로 /tmp 가 비었다. 원본 하네스는 배포 단계가 없어
# "파일이 없으면 조용히 아무 일도 안 일어나는" 실패를 만든다 → 매번 배포하고 확인한다.
HERE=/home/stevekim/multi-fec/test-results/2026-09-02-multisession
scp -q $HERE/mf_blast $C:/tmp/mf_blast || { echo "  ✗ mf_blast 배포 실패"; exit 1; }
scp -q $HERE/../2026-08-07-aging-1h/rt_echo.py $S:/tmp/rt_echo.py || { echo "  ✗ rt_echo 배포 실패"; exit 1; }
for h in $C $R $S; do
  scp -q $HERE/rt_sample.sh $h:/tmp/rt_sample.sh || { echo "  ✗ rt_sample 배포 실패 ($h)"; exit 1; }
  ssh $h 'chmod 755 /tmp/rt_sample.sh' 2>/dev/null
done
ssh $C 'chmod 755 /tmp/mf_blast' 2>/dev/null
ssh $S 'chmod 755 /tmp/rt_echo.py' 2>/dev/null
BV=$(ssh $C '/tmp/mf_blast --sessions 1 --secs 0 --no-clients --echo-port 1 2>&1 | tail -1' 2>/dev/null)
echo "  mf_blast 기동 확인: ${BV:-<무응답>}"
[ -n "$BV" ] || { echo "  ✗ c 에서 mf_blast 가 실행되지 않는다 — 중단"; exit 1; }

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
echo "  ⚠️ relay 카운트는 **운영 릴레이(.85:443/.86:443)도 함께 센다** — 4 로 나와도 정상이다"
[ "$ECHO_N" -ge 1 ] && [ "$SRV_N" -ge 1 ] && [ "$REL_N" -ge 2 ] || { echo "  ✗ 기동 실패 — 중단"; exit 1; }

echo; echo "=== 5. 샘플러 + 가드 ==="
# ⚠️ 샘플러 패턴에도 포트 범위를 준다. `127.0.0.1:518` 이면 **운영 클라(:51821)** 까지
# 합산해 nproc·RSS·FD 가 오염된다 — cleanup 의 kill 패턴만 고쳐져 있고 샘플러는
# 빠져 있었다(2026-09-02 발견). 누수 판정이 통째로 무의미해지는 종류의 결함이다.
ssh $C "nohup /tmp/rt_sample.sh 'multi-fec-dist -c -l 127.0.0.1:518[6-9]' /tmp/ag_c_$RUNID.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $S "nohup /tmp/rt_sample.sh 'multi-fec-dist -s -l $SRV:$PORT' /tmp/ag_s_$RUNID.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
# 같은 이유 — `192.168.100.8` 은 **운영 릴레이(.85:443/.86:443)** 도 매치한다
ssh $R "nohup /tmp/rt_sample.sh 'multi-fec-dist -r -l 192.168.100.8[56]:$PORT' /tmp/ag_r_$RUNID.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
# 생성기 자체 CPU 를 따로 잰다 — c 전체 CPU 에서 이 몫을 빼야 제품 비용이 나온다.
# 별도 A/B 런이 필요 없고 실제 런과 같은 조건에서 정확히 귀속된다.
ssh $C "nohup /tmp/rt_sample.sh 'mf_blast --sessions' /tmp/ag_blast_$RUNID.csv $((SECS+180)) mf_blast >/dev/null 2>&1 &" 2>/dev/null
nohup $GUARD watch "mf_blast" > $OUT/watchdog.log 2>&1 &
WD=$!
sleep 12
kill -0 $WD 2>/dev/null && echo "  가드 살아있음 pid=$WD" || { echo "  ✗ 가드가 죽었다 — 중단"; exit 1; }
echo "  샘플러 c/r/s 기동"

echo; echo "=== 6. 부하 ${SECS}s (세션 $N, 각 방향 ${MBPS} Mbps) — $(date +%H:%M:%S) 시작 ==="
ifsnap load0 >> $OUT/ifsnap.txt
# ⚠️ 가드가 트립하면 그 자리에서 종료한다. 트립 시점에 대상 프로세스가 아직 없으면
# (부하 시작 직전의 순간 초과 등) **아무것도 못 죽이고 사라져 나머지 런이 무감시가 된다.**
# 2026-09-02 다중 세션 런에서 실제로 그렇게 1시간을 무감시로 돌았다.
# → 부하와 병렬로 가드 생존을 감시하고, 죽으면 부하를 즉시 중단한다.
( while kill -0 $WD 2>/dev/null; do sleep 10; done
  echo "[$(date +%H:%M:%S)] ✗ 가드가 사라졌다 — 부하를 중단한다" >> $OUT/guard_died.log
  ssh $C "pkill -f '[m]f_blast'" 2>/dev/null ) &
GW=$!
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 $C \
    "/tmp/mf_blast --sessions $N --secs $SECS --mbps $MBPS --src $SRC \
     --relay-a $RA:$PORT --relay-b $RB:$PORT --key $KEY" 2>$OUT/blast.err | tee $OUT/result.csv
kill $GW 2>/dev/null
[ -s $OUT/guard_died.log ] && { echo "  ⚠️ 이 런은 도중에 무감시가 됐다:"; cat $OUT/guard_died.log; }
echo "  하네스 건전성: $(cat $OUT/blast.err 2>/dev/null | tr '\n' ' ')"
echo "  ⚠️ pacing_resets 가 0 이 아니면 생성기가 레이트를 못 낸 것이므로 결과를 믿지 말 것"
ifsnap load1 >> $OUT/ifsnap.txt

kill $WD 2>/dev/null
echo; echo "=== 7. 샘플 회수 ==="
ssh $C "cat /tmp/ag_c_$RUNID.csv" > $OUT/sample_c.csv 2>/dev/null
ssh $C "cat /tmp/ag_blast_$RUNID.csv" > $OUT/sample_blast.csv 2>/dev/null
ssh $R "cat /tmp/ag_r_$RUNID.csv" > $OUT/sample_r.csv 2>/dev/null
ssh $S "cat /tmp/ag_s_$RUNID.csv" > $OUT/sample_s.csv 2>/dev/null
wc -l $OUT/sample_*.csv
echo "  가드 로그: $(grep -c 초과 $OUT/watchdog.log 2>/dev/null || echo 0) 건 초과, 트립 $(grep -c 트립 $OUT/watchdog.log 2>/dev/null || echo 0) 건"
