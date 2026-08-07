#!/bin/bash
# mf_soak_18m.sh — 앱 각 방향 18 Mbps 1시간 지속 소크 (테스트망 전용)
#
# 왜: 2026-08-06 계단이 준 "실용 한계 각 방향 22 Mbps" 는 **단계당 45초** 값이다.
#     그 숫자를 SLA 로 쓰려면 지속 부하에서도 유지되는지 확인해야 한다. 18 은
#     한계 22 아래의 안전 운용점(계단에서 손실 0/0.033%, c 전체 46.2%, 최고1코어 64.8%).
#
# 계단과 같은 조건으로 맞춘다 — 비교 가능해야 의미가 있다:
#   운영 체인(:443) · duplicate · mode 1 · -f 5:1,20:4 · mtu 1350 · netem 25ms/5%·30ms/2%
#   부하는 WG IP 사이 (규칙 1). `-B 10.9.10.1` 바인딩이 핵심 안전장치다 —
#   실제 IP 로 쏘면 multi-fec 을 안 타고 측정이 조용히 무의미해진다.
#
# ⚠️ TCP 가 아니라 UDP 를 쓴다. 고정 레이트라 손실이 그대로 보이고, iperf 3.9 의
#    TCP `--bidir` 은 36배 붕괴하는 도구 결함이 있다 (UDP --bidir 은 정상).
#
# ⚠️ 용량 모델(`budget`)은 이 레이트에서 유효하지 않다 — R=36 은 모델의 ②(15.9)·③(31.25)에
#    걸리지만, 계단 실측은 44 까지 동작함을 보였다(§10: 모델이 고배율에서 2.1배 과대).
#    그래서 budget 은 **정보로만** 출력하고 게이트로 쓰지 않는다. 실제 안전장치는
#    precheck + 가드 watch 이고 그 둘은 그대로 강제한다.
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com; S=s.xdn.selfinet.com
RATE=${RATE:-18}; SECS=${SECS:-3600}; PORT=${PORT:-5201}
GUARD=/home/stevekim/multi-fec/test-results/2026-08-02-50mbps-soak/mf_gwguard.sh
OUT=${OUT:-/home/stevekim/multi-fec/test-results/2026-08-07-aging-1h/soak}
mkdir -p "$OUT"

ifsnap() {   # $1 = 라벨
  for h in $C $R $S; do
    ssh -o ConnectTimeout=5 "$h" "awk -v H=${h%%.*} -v L=$1 -v T=\$(date +%s) '
      NR>2 { gsub(/:/,\"\",\$1); if (\$1!=\"lo\") print L, H, \$1, \$2, \$10, T }' /proc/net/dev" 2>/dev/null
  done
}

cleanup() {
  echo; echo "[$(date +%H:%M:%S)] 정리"
  ssh $C "pkill -9 -f '[i]perf3 -c'" 2>/dev/null
  ssh $S "pkill -9 -f '[i]perf3 -s'" 2>/dev/null
  ssh $C "pkill -f '[r]t_sample.sh'" 2>/dev/null
  ssh $R "pkill -f '[r]t_sample.sh'" 2>/dev/null
  ssh $S "pkill -f '[r]t_sample.sh'" 2>/dev/null
  # r 의 apt 타이머 복구 (아래에서 정지시켰다)
  ssh $R 'sudo systemctl start apt-daily-upgrade.timer 2>/dev/null
          sudo systemctl stop soak-timer-restore.timer 2>/dev/null; exit 0' 2>/dev/null
  echo "  r apt-daily-upgrade.timer: $(ssh $R 'systemctl is-active apt-daily-upgrade.timer' 2>/dev/null)"
  echo "  운영 체인:"
  ssh $C 'systemctl is-active multi-fec-client' 2>/dev/null | sed 's/^/    c client /'
  ssh $R 'systemctl is-active multi-fec-relay multi-fec-relay@b | tr "\n" " "' 2>/dev/null | sed 's/^/    r relay /'; echo
  ssh $S 'systemctl is-active multi-fec-server' 2>/dev/null | sed 's/^/    s server /'
}
trap cleanup EXIT INT TERM

echo "=== 0. 용량 모델 (정보 — 이 레이트에서는 무효, 게이트 아님) ==="
$GUARD budget "$(awk -v r=$RATE 'BEGIN{print r*2}')" 1 || true
echo "  ↑ ②·③ 초과는 예상된 것이다. 계단 실측이 각 방향 22 까지 동작을 보였고"
echo "    모델은 고배율에서 2.1배 과대다(REPORT 2026-08-06 §10). 실제 게이트는 아래 precheck 와 가드."

echo; echo "=== 1. precheck (전제 검증, 트래픽 미발생) ==="
$GUARD precheck || { echo "precheck 실패 — 중단"; exit 1; }

echo; echo "=== 2. r 의 apt 타이머 정지 (오늘 아침 트립 원인) ==="
# 2026-08-07 첫 런은 apt-daily.service 가 r 의 1코어를 33초간 포화시켜 48분에 트립했다.
# apt-daily-upgrade 가 이번 런 한가운데(15:33 KST)에 예약돼 있어 정지한다.
# 내 정리 루틴이 안 돌아도 복구되도록 systemd 예약도 함께 건다.
ssh $R "sudo systemctl stop apt-daily-upgrade.timer
        sudo systemd-run --on-active=$((SECS+900)) --unit=soak-timer-restore \
             systemctl start apt-daily-upgrade.timer >/dev/null 2>&1" 2>/dev/null
echo "  apt-daily-upgrade.timer: $(ssh $R 'systemctl is-active apt-daily-upgrade.timer' 2>/dev/null) (복구 예약 $((SECS+900))s)"

echo; echo "=== 3. 유휴 기준선 60초 ==="
ifsnap idle0 > $OUT/ifsnap.txt
sleep 60
ifsnap idle1 >> $OUT/ifsnap.txt
echo "  완료"

echo; echo "=== 4. 샘플러 (운영 프로세스 RSS/FD/CPU) ==="
ssh $C "nohup /tmp/rt_sample.sh 'multi-fec-dist -c -l 127.0.0.1:51821' /tmp/sk_c.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $R "nohup /tmp/rt_sample.sh 'multi-fec-dist -r -l 192.168.100.8'   /tmp/sk_r.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $S "nohup /tmp/rt_sample.sh 'multi-fec-dist -s -l 192.168.100.84'  /tmp/sk_s.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
echo "  c/r/s 기동"

echo; echo "=== 5. 가드 (부하보다 먼저 — 규칙 0) ==="
nohup $GUARD watch "iperf3 -c" > $OUT/watchdog.log 2>&1 &
WD=$!
sleep 12
kill -0 $WD 2>/dev/null && echo "  가드 pid=$WD 살아있음" || { echo "  ✗ 가드 사망 — 중단"; exit 1; }

echo; echo "=== 6. iperf3 서버 (s, 터널 IP 바인딩) ==="
# ⚠️ `nohup ... &` 만으로는 부족하다 — ssh 채널이 닫힐 때 프로세스가 같이 죽어
# 로그 파일조차 안 생겼다(2026-08-07 실측). **setsid + </dev/null** 이 필요하다.
# ⚠️ kill 과 기동을 **반드시 별도 ssh 로** 나눌 것.
# bracket 패턴 `[i]perf3 -s` 는 그 토큰만 가려준다 — 같은 커맨드라인 뒤쪽의
# `setsid nohup iperf3 -s -B ...` 에 평문이 그대로 있어 pkill 이 **자기 셸을 죽인다**
# (2026-08-07 실측: ssh rc=255, 로그 파일만 빈 채 생성, 서버 미기동).
ssh $S "pkill -9 -f '[i]perf3 -s'; exit 0" 2>/dev/null
sleep 1
ssh $S "setsid nohup iperf3 -s -B 10.9.10.1 -p $PORT </dev/null >/tmp/sk_srv.log 2>&1 &
        sleep 1; exit 0" 2>/dev/null
# ⚠️ `pgrep -cf` 는 미매치 시 "0" 을 찍고 **exit 1** 이라 `|| echo 0` 을 붙이면
# "0\n0" 이 되어 `[ ]` 정수 비교가 깨진다. head -1 로 첫 줄만 취한다.
SRV_N=$(ssh $S "pgrep -cf '[i]perf3 -s'" 2>/dev/null | head -1); SRV_N=${SRV_N:-0}
echo "  iperf3 -s: $SRV_N 개"
[ "$SRV_N" -ge 1 ] || { echo "  ✗ 서버 기동 실패 — 중단"; exit 1; }

echo; echo "=== 7. CPU 타임라인 (60초 간격) ==="
( for i in $(seq 1 $((SECS/60+2))); do
    echo "--- $(date +%H:%M:%S)"; $GUARD sample 2>/dev/null; sleep 55
  done ) > $OUT/cpu_timeline.log 2>&1 &
TL=$!

echo; echo "=== 8. 부하 ${SECS}s · 앱 각 방향 ${RATE} Mbps — $(date +%H:%M:%S) 시작 ==="
ifsnap load0 >> $OUT/ifsnap.txt
# 1시간짜리 ssh 라 keepalive 를 건다. 없으면 중간에 끊겨 런이 통째로 날아간다.
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 $C \
    "iperf3 -c 10.9.10.1 -p $PORT -u -b ${RATE}M --bidir -t $SECS -i 60" > $OUT/iperf.log 2>&1
ifsnap load1 >> $OUT/ifsnap.txt
kill $TL $WD 2>/dev/null

echo; echo "=== 9. 회수 ==="
ssh $C 'cat /tmp/sk_c.csv' > $OUT/sample_c.csv 2>/dev/null
ssh $R 'cat /tmp/sk_r.csv' > $OUT/sample_r.csv 2>/dev/null
ssh $S 'cat /tmp/sk_s.csv' > $OUT/sample_s.csv 2>/dev/null
wc -l $OUT/sample_*.csv $OUT/iperf.log
echo "  가드: 초과 $(grep -c 초과 $OUT/watchdog.log 2>/dev/null || echo 0) 건 · 트립 $(grep -c 트립 $OUT/watchdog.log 2>/dev/null || echo 0) 건"
tail -6 $OUT/iperf.log
