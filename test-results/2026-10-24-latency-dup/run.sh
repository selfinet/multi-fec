#!/bin/bash
# run.sh — duplicate 하향 경로 사용: 1.4.1-v5 vs 1.4.0 × 실제망 지연 (2026-10-24, 테스트망 전용)
#
# 왜: 1.4.0 서버는 "먼저 도착한 적이 있는 경로" 만 하향에 쓴다. 손실이 거의 없고 한 경로가 늘 느리면
#   하향이 한 경로로만 간다(1.4.1 fix/dup-path-tag 가 고침). 실제망 50~100 ms 에서 1.4.1 로 바꾸면 하향이 얼마나 느는지 잰다.
# 경우: A = path[0] 25 ms / path[1] 50 ms (편도, 늘 path[1] 이 느림)  B = 둘 다 37 ms (순서가 수시로 뒤집힘). 손실 0.
# 부하: mfgen 상향 2 · 하향 10 Mbps 90초(WG IP 사이). 지표: client 경로별 rx 증가분(중복 제거 전 사본 포함), mfgen 손실.
# 작업: r·rs2 netem.conf 지연·손실 변경(원본 *.bak-latency-2026-10-24), 4대 바이너리 교체·재시작
# 영향: 테스트망 터널이 재시작마다 1초 안팎 끊김, 시험 동안 지연값이 기준선과 다름
# 되돌리기: 끝나면(중단돼도) netem.conf 원본 복원·mf-netem 재시작, 4대 .v1.4.0 — 시작 전과 같은 상태
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
G=../2026-08-02-50mbps-soak/mf_gwguard.sh; BAK=bak-latency-2026-10-24
REPS=${REPS:-2}; DUR=${DUR:-90}; UP=${UP:-2}; DN=${DN:-10}
OUT=raw; mkdir -p $OUT
export GW_NET=new GW_PROFILE=vm

inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 20; }
setdelay() {   # $1 = r 지연, $2 = rs2 지연 (손실 0)
  for p in "$R $1" "$R2 $2"; do set -- $p
    ssh $1 "f=/etc/multi-fec/netem.conf; [ -f \$f.$BAK ] || cp -p \$f \$f.$BAK
      sed -i -e 's/^P0_DELAY=.*/P0_DELAY=$2/' -e 's/^P0_LOSS=.*/P0_LOSS=0%/' \$f; systemctl restart mf-netem; tc qdisc show dev ens18 | grep -m1 'netem 10:'"; done
}
fin() {
  echo "[$(date +%T)] ===== 정리 · netem 원본 · 1.4.0"
  kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null
  for h in $R $R2; do ssh $h "f=/etc/multi-fec/netem.conf; [ -f \$f.$BAK ] && cp -p \$f.$BAK \$f; systemctl restart mf-netem; tc qdisc show dev ens18 | grep -m1 'netem 10:'"; done
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist | cut -c1-8)"
}

# 가드 — 트립하면 mfgen 을 죽인다
setsid "$G" watch "mfgen tx" > $OUT/guard.log 2>&1 < /dev/null &
GP=$!
trap fin EXIT
sleep 12
kill -0 $GP 2>/dev/null && grep -q '감시 시작' $OUT/guard.log || { echo "가드 기동 실패"; cat $OUT/guard.log; exit 2; }
echo "[run] 가드 PID $GP"

# client 경로 보고에서 경로별 rx 누적값 (가장 최근 보고)
pathrx() { ssh $C "journalctl -u multi-fec@client --since '-70s' --no-pager -o cat | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'path\[[01]\] ' | tail -2" | sed -E 's/.*path\[([01])\] ([A-Z]+).*owd=([0-9.]+)ms.* tx=([0-9]+) rx=([0-9]+).*/p\1 \2 owd=\3 tx=\4 rx=\5/'; }

for cs in A B; do
  if [ $cs = A ]; then setdelay 25ms 50ms; else setdelay 37ms 37ms; fi
  for rep in $(seq 1 $REPS); do
    for v in 1.4.1-v5 1.4.0; do
      [ $((rep % 2)) -eq 0 ] && v=$([ "$v" = 1.4.0 ] && echo 1.4.1-v5 || echo 1.4.0)
      kill -0 $GP 2>/dev/null || { echo "[run] 가드 소멸 — 중단"; tail -3 $OUT/guard.log; exit 3; }
      tag=${cs}_v${v//./}_$rep; setall $v
      t0=$(date +%s)
      ssh $S "mfgen rx 10.9.20.1 5301 $((DUR+4)) > /tmp/lu_$tag.txt" >/dev/null 2>&1 & RS=$!
      ssh $C "mfgen rx 10.9.20.2 5302 $((DUR+4)) > /tmp/ld_$tag.txt" >/dev/null 2>&1 & RC=$!
      sleep 1
      ssh $C "mfgen tx 10.9.20.1 5301 $UP $DUR" > /dev/null 2>&1 & T1=$!
      ssh $S "mfgen tx 10.9.20.2 5302 $DN $DUR" > /dev/null 2>&1 & T2=$!
      wait $T1; wait $T2; wait $RS; wait $RC
      ssh $S "cat /tmp/lu_$tag.txt; rm -f /tmp/lu_$tag.txt" > $OUT/up_$tag.txt
      ssh $C "cat /tmp/ld_$tag.txt; rm -f /tmp/ld_$tag.txt" > $OUT/dn_$tag.txt
      ssh $C "journalctl -u multi-fec@client --since @$((t0-25)) --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > $OUT/cli_$tag.log
      ssh $S "journalctl -u multi-fec@server --since @$((t0-25)) --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > $OUT/srv_$tag.log
      printf "[run] %-14s up %s  dn %s  | %s\n" $tag "$(awk '/^total/{print $9"%"}' $OUT/up_$tag.txt)" "$(awk '/^total/{print $9"%"}' $OUT/dn_$tag.txt)" "$(pathrx | tr '\n' ' ')"
      grep -q '트립' $OUT/guard.log && { echo "[run] 가드 트립"; grep 트립 $OUT/guard.log; exit 4; }
    done
  done
done
echo "[$(date +%T)] LATDUP_DONE"
