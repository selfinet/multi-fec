#!/bin/bash
# t5_failure.sh — 장애 회귀 (시험 5): 1.3.1 vs 1.4.0 (2026-10-18, 테스트망 전용)
#
#   A. 두 경로 동시 소멸 → 복구 (pendttl_test.sh 를 신규 망에 맞춘 것 — 원본은 구 망 이름·유닛·WG IP 를 박아 두었다)
#      relay 2개(multi-fec-relay, multi-fec-relay-b)를 26초 정지 → 시작, 3회. WG 위 ping 5 pps.
#      볼 것: 단절 공백, 복구 후 첫 RTT(1.3.1 부터 묵은 패킷 없음 — 남는 ~2초는 WG 재핸드셰이크), 1초 초과 응답 수, 클라 RSS/FD.
#   B. test_path_failure.py — r 에서 root 로, 격리 netns(mfd)·veth(vA/vB 10.210.x)·포트 3444x. 테스트망 링크·유닛과 무관.
#      절단·열화·지연차 × duplicate/aggregate 8종. 1.4.0 과 1.3.1 을 같은 날 같은 호스트에서.
# 트래픽: A 는 ping 5 pps 뿐, B 는 r 내부 veth 만 → 가드 불필요. 끝나면 3대 1.3.1 로 복구.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=$(pwd)/raw/t5; mkdir -p "$OUT"
cp -p ../2026-09-10-v131/analyze_pend.py "$OUT/analyze_pend.py"   # 같은 디렉터리의 pend_<LABEL>_* 를 읽는다

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" "pkill -f '[p]ing -i 0.2 -D 10.9.20.1'; exit 0"
  ssh "$R" 'systemctl start multi-fec-relay multi-fec-relay-b; ip netns del mfd 2>/dev/null; ip link del vA 2>/dev/null; ip link del vB 2>/dev/null; rm -f /tmp/mf131 /tmp/mf140 /tmp/test_path_failure.py /tmp/mf_*.log /tmp/mf_order.txt; true'
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) netns=$(ip netns list | grep -c mfd) veth=$(ip -br link | grep -cE "^v[AB]") $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 10 -i 0.2 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT
echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"

setall() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client"
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && return 0; sleep 5; done
  echo "터널 미복구 ($1)"; return 1
}
snap() {
  ssh $C 'p=$(systemctl show -p MainPID --value multi-fec-client); [ "$p" = 0 ] && { echo "0 0 0"; exit 0; }
    r=$(awk "/VmRSS/{print \$2}" /proc/$p/status); f=$(ls /proc/$p/fd 2>/dev/null|wc -l); echo "$p $r $f"' 2>/dev/null
}

# ═══ A. 두 경로 동시 소멸 → 복구
CYCLES=3; DOWN=26; SETTLE=35
for ver in 1.3.1 1.4.0; do
  L=v${ver//./}; setall $ver || exit 1; sleep 15
  : > "$OUT/pend_${L}_events.log"; echo "phase pid rss_kb fd" > "$OUT/pend_${L}_rss.log"; echo "before $(snap)" >> "$OUT/pend_${L}_rss.log"
  # 정리와 시작은 다른 ssh 로 — 같은 명령줄에 평문 "ping -i 0.2 …" 가 있으면 bracket 패턴이 그 셸 자신을 죽인다
  ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.20.1'; exit 0"
  ssh $C "setsid nohup ping -i 0.2 -D 10.9.20.1 </dev/null >/tmp/pend_${L}.log 2>&1 & sleep 1; exit 0"
  T0=$(date +%s); sleep 15
  for i in $(seq 1 $CYCLES); do
    echo "$(date +%s.%N) cycle$i: 릴레이 2개 정지" >> "$OUT/pend_${L}_events.log"; echo "[$(date +%T)] $L cycle$i 정지"
    ssh $R 'systemctl stop multi-fec-relay multi-fec-relay-b'
    sleep $DOWN
    echo "$(date +%s.%N) cycle$i: 복구" >> "$OUT/pend_${L}_events.log"
    ssh $R 'systemctl start multi-fec-relay multi-fec-relay-b'
    sleep $SETTLE
    echo "cycle$i $(snap)" >> "$OUT/pend_${L}_rss.log"
  done
  echo "after $(snap)" >> "$OUT/pend_${L}_rss.log"
  ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.20.1'; exit 0"
  ssh $C "cat /tmp/pend_${L}.log; rm -f /tmp/pend_${L}.log" > "$OUT/pend_${L}_ping.log"
  ssh $C "journalctl -u multi-fec-client --since @$T0 --no-pager -o cat" | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/pend_${L}_client.log"
  python3 "$OUT/analyze_pend.py" "$L" | tee "$OUT/pend_${L}_analysis.txt"
  echo "  stale-drop 로그: $(grep -c 'stale pending' "$OUT/pend_${L}_client.log")줄 · RSS/FD:"; column -t "$OUT/pend_${L}_rss.log" | sed 's/^/    /'
done

# ═══ B. test_path_failure.py (격리 netns, r)
setall 1.3.1 || exit 1
scp -q ../../test_path_failure.py $R:/tmp/test_path_failure.py
ssh $R 'cp /usr/sbin/multi-fec-dist.v1.4.0 /tmp/mf140; cp /usr/sbin/multi-fec-dist.v1.3.1 /tmp/mf131'
for b in mf140 mf131; do
  echo "[$(date +%T)] ##### test_path_failure.py BIN=$b"
  ssh $R "cd /tmp && BIN=/tmp/$b python3 /tmp/test_path_failure.py" 2>&1 | tee "$OUT/path_failure_$b.txt" | grep -E '✓|✗|결과'
done
echo "[$(date +%T)] 측정 완료"
