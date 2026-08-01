#!/bin/bash
# mf_ladder2.sh — c.xdn 부하 계단 v2  (REPORT.md §7-2)
#
# v1(c:/tmp/mf_ladder.sh) 에서 TCP 구간이 90초 중 27초에 워치독에 잘려 데이터를 못 남겼다.
# 원인은 TCP 자체가 아니라 하네스였다. 고친 것:
#
#   1. TCP 페이싱   -b 단독  →  -b + --fq-rate 병용
#                   iperf3 -b 는 TCP 에서 누적 평균만 맞추고 순간값을 놓아준다
#                   (실측: 앱 평균 2.14 Mbps 인데 와이어 피크 14.25 Mbps, 피크/평균 2.88배).
#                   --fq-rate 는 커널 SO_MAX_PACING_RATE 라 톱니 자체가 생기지 않는다.
#   2. TCP 캡       3 Mbps → 1.5 Mbps.  피크/평균 2.88배 역산 → 평균 와이어 4.9 Mbps 여야
#                   피크가 TX_LIMIT(14 Mbps) 아래에 들어온다.
#   3. 프리플라이트  본시험 전 캡 1/4 로 45초. 경로가 이상하면 여기서 걸러진다.
#   4. 자동 재시도   트립하면 캡을 절반으로 낮춰 최대 2회 재시도. v1 은 트립 = 데이터 0.
#   5. TCP -i 1     v1 은 -i 30 이라 30초 평균에 톱니가 묻혔다. 초단위 Retr/cwnd 를 남긴다.
#   6. 라벨 시점    txrate.csv 의 phase 를 창 '시작' 시점으로 기록 (v1 은 종료 시점이라
#                   구간 경계 창이 다음 phase 로 잘못 붙었다).
#   7. ping         고정 timeout 900 → 전 구간 커버 후 trap 에서 정리.
#   8. 요약         종료 시 phase 별 min/avg/max 와 트립 목록을 자동 출력.
#
# 사용:  sudo bash mf_ladder2.sh                     # 기본값으로 전체
#        sudo TCP_CAP=1000000 bash mf_ladder2.sh     # TCP 캡만 조정
#        sudo DUR=60 TCP_DUR=60 bash mf_ladder2.sh   # 짧게 리허설
#
# 주의:  gw 는 건드리지 않는다. c:enp2s0 TX 를 gw 상향 대리지표로 쓴다 (§3).
#        TX_LIMIT 은 gw 상한 30 Mbps 의 절반(양방향 대칭 가정) 기준이다.

set -u

D=${D:-/tmp/mftest2}            # v1 의 /tmp/mftest 를 덮지 않는다
S=${S:-10.9.10.1}               # WG 터널 server (starlink-fec)
IF=${IF:-enp2s0}
TX_LIMIT=${TX_LIMIT:-1750000}   # B/s = 14.0 Mbps. gw 상향 대리지표
WIN=${WIN:-5}                   # 워치독 창(초). v1 과 같아야 txrate 비교 가능
DUR=${DUR:-120}                 # UDP 구간 길이
TCP_DUR=${TCP_DUR:-120}
TCP_CAP=${TCP_CAP:-1500000}     # bit/s. §7-2 역산값
TCP_RETRY=${TCP_RETRY:-2}
UDP_PORT=${UDP_PORT:-5201}
TCP_PORT=${TCP_PORT:-5202}

command -v iperf3 >/dev/null || { echo "iperf3 없음" >&2; exit 1; }
iperf3 --help 2>&1 | grep -q -- --fq-rate || {
    echo "이 iperf3 는 --fq-rate 를 지원하지 않는다 (3.9+ 필요) — v2 의 핵심 수정이 무효" >&2
    exit 1
}
grep -q "^ *$IF:" /proc/net/dev || { echo "$IF 없음" >&2; exit 1; }

mkdir -p "$D"
: > "$D/timeline.log"; : > "$D/txrate.csv"; : > "$D/trip"; : > "$D/summary.txt"
echo init > "$D/phase"

log(){ echo "$(date +%s) $*" | tee -a "$D/timeline.log"; }
txbytes(){ awk -v i="$IF:" '$1==i{print $10}' /proc/net/dev; }
tripped(){ grep -q "^$1 " "$D/trip" 2>/dev/null; }

# ── 워치독 ────────────────────────────────────────────────────────────────
# 창 '시작' 시점의 phase 를 라벨로 쓴다. pkill 브래킷 트릭은 자기 명령줄에
# 걸려 스스로 먼저 죽는 것을 막는다 (§3 계측 함정).
(
  while true; do
    p=$(cat "$D/phase" 2>/dev/null || echo "?")
    t0=$(date +%s); a=$(txbytes)
    sleep "$WIN"
    b=$(txbytes); r=$(( (b - a) / WIN ))
    echo "$t0,$p,$r" >> "$D/txrate.csv"
    if [ "$r" -gt "$TX_LIMIT" ]; then
        log "WATCHDOG tx=${r} > ${TX_LIMIT} phase=${p} -> KILL"
        echo "$p $r" >> "$D/trip"
        pkill -f 'ipe[r]f3 -c'
    fi
  done
) & WD=$!

ping -D -i 0.5 -O "$S" > "$D/ping.log" 2>&1 & PG=$!
trap 'kill $WD $PG 2>/dev/null; echo DONE > "$D/phase"' EXIT

# ── 구간 ──────────────────────────────────────────────────────────────────
udp(){  # <label> <rate> <dur>
  echo "$1" > "$D/phase"
  log "PHASE $1 start  udp bidir -b $2 -l 1200 ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$UDP_PORT" -u --bidir \
      -b "$2" -l 1200 -t "$3" -i 10 > "$D/iperf_$1.log" 2>&1
  log "PHASE $1 end rc=$?"
  sleep 5
}

tcp(){  # <label> <bps> <dur>   — -b 와 --fq-rate 를 같은 값으로 건다.
        # --fq-rate 가 서버 쪽 역방향에 반영되지 않는 경우에도 -b 가 남는다.
  echo "$1" > "$D/phase"
  log "PHASE $1 start  tcp bidir -b $2 --fq-rate $2 ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$TCP_PORT" --bidir \
      -b "$2" --fq-rate "$2" -t "$3" -i 1 > "$D/iperf_$1.log" 2>&1
  log "PHASE $1 end rc=$?"
  if tripped "$1"; then sleep 15; else sleep 5; fi   # 트립 후엔 역방향 배수까지 대기
}

tcp_ladder(){  # <bps> — 트립하면 캡 절반으로 재시도
  local cap=$1 try=0 label
  while :; do
    label="t$(( cap / 1000 ))k"
    tcp "$label" "$cap" "$TCP_DUR"
    if ! tripped "$label"; then
        log "TCP OK at ${cap} bps (${label})"
        return 0
    fi
    try=$(( try + 1 ))
    if [ "$try" -gt "$TCP_RETRY" ]; then
        log "TCP FAILED — ${TCP_RETRY}회 재시도 모두 트립"
        return 1
    fi
    cap=$(( cap / 2 ))
    log "TCP tripped -> retry ${try}/${TCP_RETRY} at ${cap} bps"
  done
}

summary(){
  {
    echo
    echo "=== phase별 c:$IF TX (Mbps, ${WIN}초 창) ==="
    awk -F, -v L="$TX_LIMIT" '
      $2!="" && $2!="init" {
        if (!($2 in n)) { ord[++c] = $2; mn[$2] = $3 }
        n[$2]++; s[$2] += $3
        if ($3 > mx[$2]) mx[$2] = $3
        if ($3 < mn[$2]) mn[$2] = $3
      }
      END {
        for (i = 1; i <= c; i++) { p = ord[i]
          printf "  %-10s n=%-3d min=%6.2f  avg=%6.2f  max=%6.2f%s\n",
                 p, n[p], mn[p]*8/1e6, s[p]/n[p]*8/1e6, mx[p]*8/1e6,
                 (mx[p] > L ? "   ** TRIP **" : "")
        }
        printf "  %-10s               limit=%6.2f\n", "", L*8/1e6
      }' "$D/txrate.csv"
    echo
    echo "=== 워치독 트립 ==="
    if [ -s "$D/trip" ]; then
        awk '{printf "  %-10s %.2f Mbps\n", $1, $2*8/1e6}' "$D/trip"
    else
        echo "  없음"
    fi
    echo
    echo "=== TCP 재전송 (완주 구간만 유효) ==="
    for f in "$D"/iperf_t*.log; do
        [ -e "$f" ] || continue
        printf "  %-22s %s\n" "$(basename "$f")" \
               "$(awk '/sender/ && /TX-C/ {print $(NF-1)" Retr, "$7" "$8; exit}' "$f")"
    done
    echo
    echo "원시데이터: $D/"
  } | tee -a "$D/summary.txt"
}

# ── 실행 ──────────────────────────────────────────────────────────────────
log "RUN start  TX_LIMIT=${TX_LIMIT}B/s WIN=${WIN}s DUR=${DUR}s TCP_CAP=${TCP_CAP}bps"

udp u1M 1M "$DUR"
udp u2M 2M "$DUR"
udp u3M 3M "$DUR"
udp u4M 4M "$DUR"

tcp tpre $(( TCP_CAP / 4 )) 45          # 프리플라이트
if tripped "tpre"; then
    log "프리플라이트가 트립했다 — 본 TCP 구간 생략. TCP_CAP 을 더 낮춰 재실행할 것"
else
    tcp_ladder "$TCP_CAP"
fi

echo idle > "$D/phase"; log "PHASE idle start"; sleep 60; log "PHASE idle end"
log "ALL DONE"
summary
