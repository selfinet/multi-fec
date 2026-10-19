#!/bin/bash
# relay-stat.sh [초] [유닛...] — multi-fec relay 의 CPU·메모리·세션·트래픽 한눈에 (읽기 전용, 설치 불필요)
#
#   ./relay-stat.sh                 # 5초 측정, multi-fec-relay*
#   ./relay-stat.sh 10 multi-fec-relay
#
# relay 는 자체 통계가 없다(--report 는 relay 에서 동작하지 않는다). 그래서 OS 카운터를 두 시점에서 읽어 차이를 낸다.
#   CPU  : /proc/<pid>/stat utime+stime 변화 (코어 1개 = 100%)
#   메모리: VmRSS, FD 수, 세션 소켓 수(ss -u, 연결된 upstream 소켓 = 세션)
#   트래픽: 인터페이스 RX/TX 바이트 변화 (relay 전용 호스트면 거의 relay 트래픽)
#   오류 : UDP 수신 버퍼 넘침(UdpRcvbufErrors) · 소켓별 drops(/proc/net/udp) 변화
set -u
DUR=${1:-5}; shift || true
UNITS=${*:-$(systemctl list-units --plain --no-legend 'multi-fec-relay*' | awk '{print $1}')}
HZ=$(getconf CLK_TCK)

declare -A pid t0 rss fds ses drops0
inode_drops() {  # 프로세스의 UDP 소켓 drops 합
    local p=$1 sum=0 ino
    for ino in $(ls -l /proc/$p/fd 2>/dev/null | grep -oE 'socket:\[[0-9]+\]' | grep -oE '[0-9]+'); do
        d=$(awk -v i=$ino '$10==i {print $NF; exit}' /proc/net/udp /proc/net/udp6 2>/dev/null)   # UDP 가 아닌 fd 는 빈 값
        sum=$((sum + ${d:-0}))
    done; echo $sum
}
for u in $UNITS; do
    p=$(systemctl show -p MainPID --value "$u"); [ "$p" -gt 0 ] 2>/dev/null || { echo "$u: 실행 중 아님"; continue; }
    pid[$u]=$p; t0[$u]=$(awk '{print $14+$15}' /proc/$p/stat); drops0[$u]=$(inode_drops $p)
done
read -r rb0 tb0 <<< "$(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)"
e0=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}')
sleep "$DUR"
read -r rb1 tb1 <<< "$(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)"
e1=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}')

echo "== $(hostname) · $(date '+%F %T') · ${DUR}초 측정 · 코어 $(nproc)개 · load $(cut -d' ' -f1-3 /proc/loadavg)"
printf '%-24s %7s %9s %5s %6s %7s %s\n' '유닛' 'CPU%' 'RSS(MB)' 'FD' '세션' 'drops' '버전/기동'
for u in $UNITS; do
    p=${pid[$u]:-}; [ -n "$p" ] || continue
    c=$(awk -v a=${t0[$u]} -v h=$HZ -v d=$DUR '{printf "%.1f", ($14+$15-a)/h/d*100}' /proc/$p/stat)
    r=$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/$p/status)
    f=$(ls /proc/$p/fd | wc -l); s=$(ss -unp | grep -c "pid=$p,")
    dd=$(( $(inode_drops $p) - ${drops0[$u]} ))
    v=$(journalctl -u "$u" _PID=$p -o cat 2>/dev/null | grep -m1 -oE 'multi-fec [0-9.]+'); st=$(systemctl show -p ActiveEnterTimestamp --value "$u" | cut -d' ' -f2-3)
    printf '%-24s %7s %9s %5s %6s %7s %s · %s\n' "$u" "$c" "$r" "$f" "$s" "+$dd" "${v:-?}" "$st"
done
awk -v r=$((rb1-rb0)) -v t=$((tb1-tb0)) -v d=$DUR 'BEGIN{printf "트래픽(전 인터페이스, lo 제외): RX %.2f Mbps · TX %.2f Mbps\n", r*8/d/1e6, t*8/d/1e6}'
[ -n "${e0:-}" ] && echo "UDP 수신 버퍼 넘침(호스트 전체) 증가: $((e1-e0))"
echo "호스트 메모리: $(free -m | awk '/Mem:/{printf "사용 %d / %d MB (가용 %d MB)", $3, $2, $7}')"
