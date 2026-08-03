#!/bin/bash
# rc_run.sh — 릴레이 단절 1회분을 지휘하고 결과를 회수한다. (테스트망 전용)
#
#   rc_run.sh <tag> <stop|blackhole>
#
# ── 2026-08-03 v2: 1차 시도가 무효로 끝난 뒤 전면 수정 ──────────────────────
#
# ① pkill 자기자신 매치 (1차 시도를 무효로 만든 결함)
#    `pkill -f 'rc_echo[.]py'` 가 그 명령을 실행하는 **원격 셸 자신**의 커맨드라인
#    (`python3 /tmp/rc_echo.py` 문자열 포함)에 매치해 에코를 띄우기도 전에 죽였다.
#    결과: 180초 내내 손실 100%. 이 세션에서만 같은 함정에 세 번 걸렸다.
#    → 원격 pgrep/pkill 은 반드시 bracket() 로 첫 글자를 감싼 패턴을 쓴다.
#
# ② 엔드포인트 미기동인데 그냥 진행했다
#    `[echo] procs=0` 을 찍고도 계속 돌았다. → 이제 확인 실패 시 **즉시 중단**한다.
#
# ③ gw 가드 미기동 (800 Mbps 사고의 직접 원인)
#    부하 **전에** mf_gwguard.sh watch 를 띄우고, 트립하면 런을 실패로 끝낸다.
#
# ④ 절단 시각을 sv1 에서 ssh 로 찍었다
#    ssh 왕복이 ~1s 인데 버킷은 100ms 다. 게다가 ssh 세션 설정 때문에 원격 `date` 가
#    구간 후반에 찍혀 **오프셋 측정 자체가 +0.5s 편향**된다(실측). → r 의 절단과 c 의
#    마커를 **절대 epoch 로 예약**해 각자 로컬 시계로 발동시킨다. 전 호스트 NTP 동기이므로
#    잔여 오차는 ms 급이고, 프로브가 자기 시간축에 직접 마커를 남기므로 t0_wall 산술도
#    호스트 간 시계차도 타지 않는다.
#
# ⑤ 규칙 1 — 프로브 목적지는 WG IP(10.9.10.1)뿐. c/r/s 실제 IP 로 쏘지 않는다.
#    (절단은 r 의 제어 동작이라 트래픽 생성이 아니다.)
set -uo pipefail

TAG=${1:?usage: rc_run.sh <tag> <stop|blackhole>}
METHOD=${2:?usage: rc_run.sh <tag> <stop|blackhole>}
case "$METHOD" in stop|blackhole) ;; *) echo "METHOD 는 stop | blackhole" >&2; exit 1 ;; esac

C=c.xdn.selfinet.com
R=r.xdn.selfinet.com
S=s.xdn.selfinet.com
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/raw
GUARD=${GUARD:-$HERE/../2026-08-02-50mbps-soak/mf_gwguard.sh}
mkdir -p "$OUT"

SECS=${SECS:-180}
PPS=${PPS:-200}
SIZE=${SIZE:-1000}
CUT_AT=${CUT_AT:-40}
RESTORE_AT=${RESTORE_AT:-100}
DRAIN=${DRAIN:-3}
LEAD=${LEAD:-12}                    # 예약 발동까지 여유 (ssh 기동 시간 흡수)
WG_DEST=${WG_DEST:-10.9.10.1:40010} # 규칙 1: WG IP 만
BH_RULE="-p udp -d 192.168.100.86 --dport 443 -j DROP"

GUARD_PID=""
FAIL=""

# ── 원격 pgrep/pkill 자기자신 매치 방지 ──────────────────────────────
# 'rc_echo.py' → '[r]c_echo.py'. 정규식으로는 같은 것을 매치하지만, 이 문자열이 들어간
# 셸 커맨드라인에는 'rc_echo.py' 가 나타나지 않으므로 자기를 죽이지 않는다.
bracket() { printf '[%s]%s' "${1:0:1}" "${1:1}"; }

ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$@"; }
log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { FAIL="$*"; log "!! 중단: $*"; exit 1; }

rkill() {  # rkill <host> <프로세스패턴>
    local h=$1 p; p=$(bracket "$2")
    ssh_ "$h" "pkill -f '$p' 2>/dev/null; exit 0" >/dev/null 2>&1
}
rup() {    # rup <host> <프로세스패턴> → 실행 중이면 0
    local h=$1 p; p=$(bracket "$2")
    [ "$(ssh_ "$h" "pgrep -cf '$p' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')" -gt 0 ] 2>/dev/null
}

cleanup() {
    log "정리"
    [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null
    # 절단 상태·예약 잔재를 무조건 되돌린다
    ssh_ "$R" "sudo iptables -D INPUT $BH_RULE 2>/dev/null
               sudo systemctl start multi-fec-relay@b 2>/dev/null
               sudo systemctl stop rc-cut.timer rc-restore.timer 2>/dev/null
               sudo systemctl reset-failed rc-cut.timer rc-cut.service \
                    rc-restore.timer rc-restore.service 2>/dev/null
               exit 0" >/dev/null 2>&1
    rkill "$C" rc_probe.py
    rkill "$S" rc_echo.py
    if [ -n "$FAIL" ]; then log "결과: 실패 — $FAIL"; else log "결과: 완료"; fi
}
trap cleanup EXIT

log "=== $TAG ($METHOD) secs=$SECS pps=$PPS cut@${CUT_AT}s restore@${RESTORE_AT}s ==="

# ── 0. 사전 점검 ────────────────────────────────────────────────────
for h in "$C" "$R" "$S"; do
    ssh_ "$h" true >/dev/null 2>&1 || die "$h 접속 불가"
done
[ -x "$GUARD" ] || die "gw 가드 없음: $GUARD (규칙 0 — 가드 없이 부하 금지)"

# 규칙 2 — 하부 전송망이 터널로 향하면 즉시 중단 (터널이 자기 전송을 삼켜 증폭된다)
for h in "$C" "$R" "$S"; do
    v=$(ssh_ "$h" "n=0
        for ip in 192.168.100.141 192.168.100.85 192.168.100.86 192.168.200.254; do
            ip route get \$ip 2>/dev/null | head -1 | grep -qE 'starlink|tun|wg' && n=\$((n+1))
        done; echo \$n" 2>/dev/null | tr -d '[:space:]')
    [ "$v" = 0 ] || die "$h 규칙2 위반 $v 건 — 하부망이 터널로 향한다"
done
log "사전점검 OK (접속 3/3, 규칙2 위반 0)"

# 스크립트 배포 — 측정 후 호스트 /tmp 는 정리되므로 매 런마다 다시 올린다.
# (리포 사본이 정본이고 호스트에는 잔재를 남기지 않는다)
scp -q -o BatchMode=yes "$HERE/rc_probe.py" "$C:/tmp/" || die "rc_probe.py 배포 실패"
scp -q -o BatchMode=yes "$HERE/rc_echo.py"  "$S:/tmp/" || die "rc_echo.py 배포 실패"
log "스크립트 배포 OK"

# 잔재 정리 후 서비스 정상 확인
rkill "$C" rc_probe.py; rkill "$S" rc_echo.py
ssh_ "$R" "sudo iptables -D INPUT $BH_RULE 2>/dev/null; sudo systemctl start multi-fec-relay@b; exit 0" >/dev/null 2>&1
sleep 2
[ "$(ssh_ "$R" "systemctl is-active multi-fec-relay multi-fec-relay@b | tr '\n' ' '" 2>/dev/null)" = "active active " ] \
    || die "릴레이 2개가 active 가 아니다"

# ── 1. 에코 기동 — 확인 실패 시 중단 (1차 시도가 여기서 무너졌다) ────────
ssh_ "$S" "setsid python3 /tmp/rc_echo.py --bind $WG_DEST \
           >/tmp/rc_echo.log 2>&1 </dev/null & disown; exit 0" >/dev/null 2>&1
sleep 2
rup "$S" rc_echo.py || die "에코 미기동 — /tmp/rc_echo.log 확인"
log "에코 기동 확인 ($WG_DEST)"

# ── 2. 예약: r 의 절단·복구를 절대시각에 (로컬 시계로 발동) ──────────────
NOW=$(date +%s)
T_CUT=$((NOW + LEAD + CUT_AT))
T_RESTORE=$((NOW + LEAD + RESTORE_AT))
T_END=$((NOW + LEAD + SECS))

if [ "$METHOD" = stop ]; then
    CUT_CMD="/usr/bin/systemctl stop multi-fec-relay@b"
    RES_CMD="/usr/bin/systemctl start multi-fec-relay@b"
else
    CUT_CMD="/usr/sbin/iptables -I INPUT 1 $BH_RULE"
    RES_CMD="/usr/sbin/iptables -D INPUT $BH_RULE"
fi
# --on-calendar 은 초 단위 절대시각을 받는다. 각 호스트가 자기 시계로 발동하므로
# ssh 왕복이 절단 시각에 섞이지 않는다.
#
# ⚠️ AccuracySec 를 반드시 지정한다. systemd 타이머 기본 정확도는 **1분**이라
#    그대로 두면 절단이 최대 60초 늦게 발동해 측정이 통째로 무의미해진다.
#    (전력 절약을 위해 타이머를 묶어 발동시키는 기본 동작)
CAL_CUT=$(date -u -d "@$T_CUT" +'%Y-%m-%d %H:%M:%S UTC')
CAL_RES=$(date -u -d "@$T_RESTORE" +'%Y-%m-%d %H:%M:%S UTC')
n=$(ssh_ "$R" "sudo systemd-run --unit=rc-cut --on-calendar='$CAL_CUT' \
                   --timer-property=AccuracySec=50ms $CUT_CMD >/dev/null 2>&1
               sudo systemd-run --unit=rc-restore --on-calendar='$CAL_RES' \
                   --timer-property=AccuracySec=50ms $RES_CMD >/dev/null 2>&1
               systemctl list-timers 'rc-*' --all --no-pager 2>/dev/null \
                   | grep -cE 'rc-(cut|restore)\.timer'" 2>/dev/null | tail -1 | tr -d '[:space:]')
[ "$n" = 2 ] || die "절단/복구 예약 실패 (타이머 $n/2)"
log "예약 OK — 절단 $CAL_CUT / 복구 $CAL_RES (AccuracySec=50ms)"

# ── 3. gw 가드 — 부하 **전에** (규칙 0) ────────────────────────────
"$GUARD" watch "rc_probe.py" > "$OUT/rc_${TAG}.guard" 2>&1 &
GUARD_PID=$!
sleep 1
kill -0 "$GUARD_PID" 2>/dev/null || die "gw 가드 기동 실패 — $OUT/rc_${TAG}.guard 확인"
log "gw 가드 기동 (pid $GUARD_PID)"

# ── 4. 프로브 — 마커를 절대시각으로 넘겨 자기 시간축에 절단 위치를 남긴다 ──
ssh_ "$C" "setsid python3 /tmp/rc_probe.py --dest $WG_DEST --pps $PPS --secs $SECS \
           --size $SIZE --drain $DRAIN --mark-at $T_CUT,$T_RESTORE \
           --out /tmp/rc_${TAG}.csv >/tmp/rc_${TAG}.err 2>&1 </dev/null & disown; exit 0" >/dev/null 2>&1
sleep 3
rup "$C" rc_probe.py || die "프로브 미기동 — c:/tmp/rc_${TAG}.err 확인"
log "프로브 기동 확인 (pps=$PPS secs=$SECS dest=$WG_DEST)"

# ── 5. 진행 — 가드가 트립하면 즉시 실패 처리 ───────────────────────
WAIT_UNTIL=$((T_END + DRAIN + 6))
CUT_CHECKED=0
while [ "$(date +%s)" -lt "$WAIT_UNTIL" ]; do
    if ! kill -0 "$GUARD_PID" 2>/dev/null; then
        wait "$GUARD_PID"; rc=$?
        [ "$rc" = 2 ] && die "gw 가드 트립 — 부하 중단됨 ($OUT/rc_${TAG}.guard)"
        die "gw 가드 비정상 종료 rc=$rc"
    fi
    # 절단이 실제로 걸렸는지 한 번 확인한다.
    # `-eq` 로 정확히 일치를 보면 sleep 2 격자에서 거의 항상 놓친다 → `-ge` + 플래그.
    if [ "$CUT_CHECKED" = 0 ] && [ "$(date +%s)" -ge "$((T_CUT + 3))" ]; then
        CUT_CHECKED=1
        st=$(ssh_ "$R" "systemctl is-active multi-fec-relay@b
                        sudo iptables -S INPUT | grep -c '192.168.100.86.*DROP'" 2>/dev/null | tr '\n' '/')
        log "절단 후 r 상태: $st  (기대: stop→inactive/0/, blackhole→active/1/)"
        case "$METHOD:$st" in
            stop:inactive/0/*|blackhole:active/1/*) : ;;
            *) log "!! 경고: 절단이 예상대로 걸리지 않았다 — 결과 해석 주의" ;;
        esac
    fi
    sleep 2
done
kill "$GUARD_PID" 2>/dev/null; GUARD_PID=""

# ── 6. 복구 확인 · 회수 ────────────────────────────────────────────
st=$(ssh_ "$R" "systemctl is-active multi-fec-relay multi-fec-relay@b | tr '\n' ' '; sudo iptables -S INPUT | grep -c '192.168.100.86.*DROP'" 2>/dev/null | tr '\n' ' ')
log "복구 후 r 상태: $st  (기대: active active 0)"

ssh_ "$C" "cat /tmp/rc_${TAG}.err" 2>/dev/null | sed 's/^/  [probe] /'
scp -q -o BatchMode=yes "$C:/tmp/rc_${TAG}.csv" "$OUT/rc_${TAG}.csv" 2>/dev/null \
    || die "CSV 회수 실패 (프로브가 완주하지 못했다)"

{   printf 'method=%s\ntag=%s\n' "$METHOD" "$TAG"
    printf 't_cut=%s\nt_restore=%s\n' "$T_CUT" "$T_RESTORE"
    printf 'pps=%s secs=%s size=%s dest=%s\n' "$PPS" "$SECS" "$SIZE" "$WG_DEST"
    printf 'r_after=%s\n' "$st"
    grep '^# mark' "$OUT/rc_${TAG}.csv" | tr -d '# '
} > "$OUT/rc_${TAG}.events"

log "회수 완료: $OUT/rc_${TAG}.csv / .events / .guard"
echo
python3 "$HERE/rc_analyze.py" "$OUT/rc_${TAG}.csv" "$OUT/rc_${TAG}.events"
