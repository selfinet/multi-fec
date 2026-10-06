#!/bin/bash
# tp_ladder.sh — 버전·sysctl 조건별 처리량 계단 (2026-10-06)
#
# 왜: 서비스망은 sysctl 기본값 + 전 홉 1.3.1 이다. 1.3.1/1.3.5 혼용과 sysctl 조정이 처리량을
#     얼마나 바꾸는지 같은 날 같은 조건에서 비교한다.
#   P0 1.3.1 전부 · sysctl 기본      (현 서비스와 같은 조건)
#   P1 relay 만 1.3.5 · sysctl 기본  (서비스에 relay 를 먼저 올렸을 때)
#   P2 1.3.5 전부 · sysctl 기본
#   P3 1.3.1 전부 · sysctl 조정      (10-05 값: 3대 rmem/wmem_max 8 MB + relay default 4 MB)
# 공통: 1단 --upstream, relay 유닛에 drop-in 으로 --sock-buf 4096(서비스 relay 유닛과 같게 — 1.3.1 은 무시).
#
# 전제(사전 배치): 각 호스트 /usr/sbin/multi-fec-dist.v1.3.1 · .v1.3.5,
#   sysctl 파일은 /root/sysctl-bak-tp/ 로 옮겨져 있고(=기본값), relay drop-in 이 있다.
#   COMBOS="이름:c:r:s:def|tuned ..."  STEPS/DUR 는 run_load.sh 로.
# 기록: 조합별 소켓 버퍼(ss -uamp) · 소켓별 drops(skmem d) 전후 · nstat · run_load 결과.
# 가드가 트립하면 그 조합의 계단은 거기서 끝나고(run_load.sh 가 부하를 멈춘다) 다음 조합으로 간다.
# 정리(파일 복원·1.3.1·drop-in 제거)는 이 스크립트가 하지 않는다.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
COMBOS=${COMBOS:-"P0:131:131:131:def P1:131:135:131:def P2:135:135:135:def P3:131:131:131:tuned"}
STEPS=${STEPS:-"5 10 15 20 25"}; DUR=${DUR:-45}
OUT=${OUT:-raw/tp}; PFX=${PFX:-tp}; mkdir -p "$OUT"
SUM=$OUT/summary.txt

ver() { echo "1.3.${1:2}"; }
setsys() {  # def | tuned
  if [ "$1" = def ]; then
    for h in $C $R $S; do ssh "$h" 'sysctl -qw net.core.rmem_max=212992 net.core.wmem_max=212992 net.core.rmem_default=212992 net.core.wmem_default=212992'; done
  else
    ssh "$C" 'sysctl -qp /root/sysctl-bak-tp/90-multi-fec.conf'
    ssh "$S" 'sysctl -qp /root/sysctl-bak-tp/90-multi-fec.conf'
    ssh "$R" 'sysctl -qp /root/sysctl-bak-tp/90-multi-fec-relay.conf'
  fi
}
# ⚠️ 2026-10-06 수정: 처음엔 `grep -A1 | paste - -` 로 두 줄씩 묶었는데 grep 이 넣는 `--` 구분선 때문에
#    짝이 어긋나 일부 소켓의 skmem 이 엉뚱한 소켓에 붙었다(로컬 주소가 "0" 으로 찍힌 행). P0·P1 계단의
#    소켓별 귀속은 그래서 무효이고 호스트 합계(nstat)만 유효하다. 소켓 줄을 기억했다가 바로 다음
#    skmem 줄과 짝짓는다.
sockets() { for p in "c $C" "r $R" "s $S"; do set -- $p
  ssh "$2" 'ss -uamnp | awk "/users:/ {sock=\$4\" \"\$5; mf=(\$0 ~ /multi-fec/); next} /skmem/ && mf {print sock, \$1; mf=0}"' | sed "s/^/$1 /"; done; }
snap() { for p in "c $C" "r $R" "s $S"; do set -- $p
  echo "$1 $(ssh "$2" 'nstat -az UdpRcvbufErrors | tail -1' | awk '{print $2}')"; done; }

echo "# $(date '+%F %T') STEPS=$STEPS DUR=$DUR" >> "$SUM"
for combo in $COMBOS; do
  IFS=: read -r X VC VR VS SY <<< "$combo"
  D=$OUT/$X; mkdir -p "$D"
  echo "[$(date +%T)] ===== $X  c=$VC r=$VR s=$VS sysctl=$SY"
  setsys "$SY"
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $VS) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $VR) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $VC) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client"
  for p in "c $C" "r $R" "s $S"; do set -- $p
    echo "$1 $(ssh "$2" 'sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " "; /usr/sbin/multi-fec-dist --version | head -1; md5sum /usr/sbin/multi-fec-dist | cut -c1-8' | tr '\n' ' ')"
  done > "$D/versions.txt"
  ok=0
  for i in $(seq 1 12); do
    ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' > "$D/ping.txt" 2>&1 && { ok=1; break; }
    sleep 5
  done
  if [ $ok -ne 1 ]; then
    echo "[$(date +%T)] $X FAIL: 터널 ping 60초 무응답 — 부하 생략"; echo "$X FAIL tunnel" >> "$SUM"; continue
  fi
  sockets > "$D/sock_before.txt"; snap > "$D/nstat_before.txt"
  RUNID=${PFX}_$X STEPS="$STEPS" DUR=$DUR ./run_load.sh > "$D/run.out" 2>&1
  rc=$?
  sockets > "$D/sock_after.txt"; snap > "$D/nstat_after.txt"
  res=$(grep -E '^\[run\] +[0-9]+ Mbps' "$D/run.out" | awk '{printf "%s:up%s/dn%s ", $2, $5, $9}')
  drops=$(paste "$D/nstat_before.txt" "$D/nstat_after.txt" | awk '{printf "%s+%d ", $1, $4-$2}')
  trip=$(grep -m1 '트립' "$D/run.out" | cut -c1-120)
  echo "[$(date +%T)] $X rc=$rc  $res  drop $drops ${trip:+ TRIP: $trip}"
  echo "$X c=$VC r=$VR s=$VS sysctl=$SY rc=$rc $res drop $drops ${trip:+TRIP}" >> "$SUM"
  if [ $rc -ne 0 ] && [ $rc -ne 4 ]; then
    echo "[$(date +%T)] run_load rc=$rc (트립 외 실패) — 중단"; exit $rc
  fi
done
echo "[$(date +%T)] 완료"
