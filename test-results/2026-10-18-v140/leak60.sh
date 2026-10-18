#!/bin/bash
# leak60.sh — 1.4.0 60분 누수 시험 (2026-10-18, 테스트망 전용, 사용자 요청)
#
# 왜: 1.4.0 은 3분 부하와 4분 장애 시험만 했다. 누수 판정은 램프(~20분) 뒤 평탄 구간을 봐야 한다
#     (memory: 누수는 기울기가 아니라 계단 개수·마지막 평탄 구간). 1.4.0 에서 장시간 반복되는 새 코드는
#     client 의 30초 경로 송신 NIC 조회(netlink 소켓 열고 닫기) — 이것까지 60분 돌린다.
# 구성: 기존 유닛(전 옵션 명시) + 1.4.0 바이너리, sysctl 은 손대지 않음(현 테스트망 값).
# 부하: mfgen 10 Mbps 양방향 3600초(run_load.sh — 가드 GW_NET=new 선기동).
# 계측: 호스트마다 10초 간격 multi-fec-dist 프로세스별 RSS(kB)·FD·CPU ticks·스레드 수 → raw/leak60/rss_<host>.log
# 끝나면(실패 포함) 3대 1.3.1 로 복구.
set -u
cd "$(dirname "$0")"
VG=../2026-10-05-vm-guard-calib
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=raw/leak60; mkdir -p "$OUT"
DUR=${DUR:-3600}

SAMPLER='while :; do t=$(date +%s); for p in $(pgrep -x multi-fec-dist); do
  u=$(tr "\0" " " < /proc/$p/cmdline | grep -oE "\-l [^ ]+" | cut -d" " -f2)
  echo "$t $p $(awk "/VmRSS/{r=\$2} /Threads/{th=\$2} END{print r, th}" /proc/$p/status) $(ls /proc/$p/fd | wc -l) $(awk "{print \$14+\$15}" /proc/$p/stat) $u"
done; sleep 10; done'

stop_samplers() {
  for p in "c $C" "r $R" "s $S"; do set -- $p
    ssh "$2" 'kill $(cat /tmp/leak60_sampler.pid) 2>/dev/null; rm -f /tmp/leak60_sampler.pid; true'
    scp -q "$2:/tmp/leak60_rss.log" "$OUT/rss_$1.log" 2>/dev/null; ssh "$2" 'rm -f /tmp/leak60_rss.log'
  done
}
restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  stop_samplers
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) sampler=$(ls /tmp/leak60_* 2>/dev/null | wc -l) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 10 -i 0.2 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.4.0 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.4.0 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.4.0 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
for h in $C $R $S; do
  ssh "$h" "echo '$(date +%s) START' > /tmp/leak60_rss.log; setsid nohup bash -c '$SAMPLER' >> /tmp/leak60_rss.log 2>/dev/null < /dev/null & echo \$! > /tmp/leak60_sampler.pid; exit 0"
done
echo "[$(date +%T)] 샘플러 시작 — 30초 유휴 기준선"
sleep 30
T0=$(date +%s)
# 부하를 5분 단위로 나눈다. 1차 시도(try1)는 12.5분째 VM 정지 → 방출로 가드가 트립해(r 3초 100%, 직전 10분 평균 40%)
# 나머지 47분이 무부하였다. 트립하면 30초 쉬고 가드를 새로 띄워 이어서, 부하 합계 60분을 채운다. 트립 3회 초과면 중단.
: > "$OUT/steps.txt"; trips=0; done_s=0; i=0
while [ $done_s -lt $DUR ]; do
  i=$((i+1)); a=$(date +%s.%N)
  ( cd $VG && RUNID=leak60_$i STEPS=10 DUR=300 ./run_load.sh ) > "$OUT/run_$i.out" 2>&1
  b=$(date +%s.%N); echo "10 $a $b" >> "$OUT/steps.txt"
  if grep -q '트립' "$OUT/run_$i.out"; then
    trips=$((trips+1)); el=$(python3 -c "print(int($b-$a))")
    done_s=$((done_s + el)); echo "[$(date +%T)] 구간 $i 가드 트립 ($trips회, ${el}s 부하) — $(grep -m1 '트립 →' "$OUT/run_$i.out" | cut -c1-90)"
    [ $trips -gt 3 ] && { echo "트립 3회 초과 — 중단"; break; }
    sleep 30
  else
    done_s=$((done_s + 300)); echo "[$(date +%T)] 구간 $i 완료 ($(grep -E '^\[run\] +10 Mbps' "$OUT/run_$i.out" | awk '{print "up "$5" dn "$9}'))  누적 ${done_s}s"
  fi
done
sleep 30   # 부하 뒤 30초도 남긴다
stop_samplers
for p in "c $C multi-fec-client" "r $R multi-fec-relay -u multi-fec-relay-b" "s $S multi-fec-server"; do set -- $p; n=$1; h=$2; shift 2
  ssh "$h" "journalctl -u $* --since @$T0 --no-pager -o cat" | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/log_$n.txt"
done
python3 leak60_analyze.py "$OUT" "$OUT/steps.txt" | tee "$OUT/analysis.txt"
echo "[$(date +%T)] 측정 완료"
