#!/bin/bash
# rc_run.sh — sv1 에서 실행. 릴레이 단절 1회분을 지휘하고 결과를 회수한다.
#
#   rc_run.sh <tag> <stop|blackhole>
#
# 타임라인(초): 0 시작 ─ 40 절단 ─ 100 복구 ─ 180 종료
# 절단·복구 시각은 wall clock 으로 찍어두고, 프로브가 남긴 t0_wall 과 맞춰
# 분석 때 t_ms 축으로 환산한다(ssh 왕복 지연이 있어 sleep 계산을 믿지 않는다).
set -u

TAG=${1:?usage: rc_run.sh <tag> <stop|blackhole>}
METHOD=${2:?usage: rc_run.sh <tag> <stop|blackhole>}
C=c.xdn.selfinet.com
R=r.xdn.selfinet.com
S=s.xdn.selfinet.com
OUT=$(cd "$(dirname "$0")" && pwd)/raw
mkdir -p "$OUT"

SECS=${SECS:-180}
PPS=${PPS:-200}
CUT_AT=${CUT_AT:-40}
RESTORE_AT=${RESTORE_AT:-100}
BH_RULE="-p udp -d 192.168.100.86 --dport 443 -j DROP"

sshq() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" 2>&1 | grep -v setlocale; }

cut_path() {
    if [ "$METHOD" = stop ]; then
        sshq $R "sudo systemctl stop multi-fec-relay@b"
    else
        sshq $R "sudo iptables -I INPUT 1 $BH_RULE"
    fi
}
restore_path() {
    if [ "$METHOD" = stop ]; then
        sshq $R "sudo systemctl start multi-fec-relay@b"
    else
        sshq $R "sudo iptables -D INPUT $BH_RULE 2>/dev/null || true"
    fi
}
cleanup() {
    echo "[cleanup] 잔여 상태 정리"
    sshq $R "sudo iptables -D INPUT $BH_RULE 2>/dev/null; sudo systemctl start multi-fec-relay@b 2>/dev/null; true"
}
trap cleanup EXIT

echo "=== $TAG ($METHOD) secs=$SECS pps=$PPS cut@${CUT_AT}s restore@${RESTORE_AT}s ==="

# 에코 기동
sshq $S "pkill -f 'rc_echo[.]py' 2>/dev/null; setsid python3 /tmp/rc_echo.py --bind 10.9.10.1:40010 >/tmp/rc_echo.log 2>&1 </dev/null & disown; exit 0"
sleep 2
sshq $S "pgrep -c -f 'rc_echo[.]py'" | sed 's/^/[echo] procs=/'

# 프로브 기동 (백그라운드)
sshq $C "setsid python3 /tmp/rc_probe.py --dest 10.9.10.1:40010 --pps $PPS --secs $SECS --out /tmp/rc_${TAG}.csv >/tmp/rc_${TAG}.err 2>&1 </dev/null & disown; exit 0"
T_START=$(date +%s.%N)
echo "[t0] $T_START"

sleep "$CUT_AT"
cut_path
T_CUT=$(date +%s.%N)
echo "[cut] $T_CUT"

sleep $((RESTORE_AT - CUT_AT))
restore_path
T_RESTORE=$(date +%s.%N)
echo "[restore] $T_RESTORE"

sleep $((SECS - RESTORE_AT + 8))

# 회수
sshq $C "cat /tmp/rc_${TAG}.err" | sed 's/^/[probe] /'
scp -q -o BatchMode=yes $C:/tmp/rc_${TAG}.csv "$OUT/rc_${TAG}.csv" && echo "[saved] $OUT/rc_${TAG}.csv"
printf 't_cut=%s\nt_restore=%s\nmethod=%s\n' "$T_CUT" "$T_RESTORE" "$METHOD" > "$OUT/rc_${TAG}.events"
echo "[saved] $OUT/rc_${TAG}.events"
