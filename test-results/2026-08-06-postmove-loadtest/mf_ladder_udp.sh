#!/bin/bash
# mf_ladder_udp.sh — 앱 레이트 계단으로 무릎점을 찾는다 (테스트망 전용).
#
# 왜 UDP 인가: 고정 레이트라 부하가 예측 가능하고 손실이 그대로 보인다. TCP 는 스스로
# 레이트를 조절해 "어디서 무너지는가" 를 흐린다. goodput 은 별도 TCP 런으로 본다.
#
# 반드시 가드를 먼저 띄우고 실행한다 — 이 스크립트는 가드를 띄우지 않는다:
#   ../2026-08-02-50mbps-soak/mf_gwguard.sh watch "iperf3 -c" &
#
# ⚠️ iperf3 요약 줄 필드 (NF=13, 콜론 없음):
#     $5=전송량 $6=MBytes $7=실효Mbps $8=Mbits/sec $9=지터 $11=lost/total $12=(손실%)
#   `$(NF-4)` 같은 상대 인덱스를 쓰면 지터를 실효로 읽는다 — 2026-08-06 에 한 번 틀렸다.
# ⚠️ 가드 sample 줄 필드: $3="전체%/한계%"  $5="최고1코어%/한계%"
#   CPU 는 1초 창 단일 샘플이 매우 시끄럽다(가드 자신의 ssh 기동이 섞인다) → 3회 평균.
set -u
G=${GUARD:-$(cd "$(dirname "$0")" && pwd)/../2026-08-02-50mbps-soak/mf_gwguard.sh}
STEPS=${STEPS:-"10 12 14 16 18"}    # 앱 각 방향 Mbps
DUR=${DUR:-45}
PORT=${PORT:-5201}
C=${C:-c.xdn.selfinet.com}
OUT=${OUT:-/tmp}

printf "%-5s  %-11s %-11s  %-10s %-10s  %-9s %-9s  %-6s %s\n" \
  "각방향" "c→s 실효" "s→c 실효" "c→s 손실" "s→c 손실" "c전체CPU" "c최고1코어" "OoO" "판정"

for each in $STEPS; do
  if ! pgrep -f '[m]f_gwguard.sh watch' >/dev/null; then
    echo "  ✗ 가드가 없다 — 중단 (트립했거나 띄우지 않았다)"; exit 2
  fi

  L=$OUT/lad_$each.log
  ssh "$C" "iperf3 -c 10.9.10.1 -p $PORT -u -b ${each}M --bidir -t $DUR" >"$L" 2>&1 &
  IP=$!

  # 스텝 중반에 3회 샘플해 평균 (단일 1초 샘플은 노이즈가 크다)
  sleep 8
  st=0; sm=0; n=0
  for i in 1 2 3; do
    line=$("$G" sample 2>/dev/null | awk '/^  c /{print $3, $5}')
    t=$(echo "$line" | awk '{print $1}' | tr -d '%' | cut -d/ -f1)
    m=$(echo "$line" | awk '{print $2}' | tr -d '%' | cut -d/ -f1)
    [ -n "${t:-}" ] && { st=$(awk -v a=$st -v b=$t 'BEGIN{print a+b}'); \
                         sm=$(awk -v a=$sm -v b=$m 'BEGIN{print a+b}'); n=$((n+1)); }
  done
  ctot=$(awk -v s=$st -v n=$n 'BEGIN{print (n?sprintf("%.1f",s/n):"?")}')
  cmax=$(awk -v s=$sm -v n=$n 'BEGIN{print (n?sprintf("%.1f",s/n):"?")}')

  wait $IP 2>/dev/null

  txbw=$(awk '/TX-C.*receiver/{print $7}' "$L"); txls=$(awk '/TX-C.*receiver/{print $11, $12}' "$L")
  rxbw=$(awk '/RX-C.*receiver/{print $7}' "$L"); rxls=$(awk '/RX-C.*receiver/{print $11, $12}' "$L")
  ooo=$(awk '/out-of-order/{print $(NF-3)}' "$L"); ooo=${ooo:-0}

  txp=$(echo "$txls" | grep -o '([0-9.]*%)' | tr -d '(%)')
  rxp=$(echo "$rxls" | grep -o '([0-9.]*%)' | tr -d '(%)')
  verdict="ok"
  awk -v a="${txp:-0}" -v b="${rxp:-0}" 'BEGIN{ if (a+0>0.1 || b+0>0.1) exit 1 }' || verdict="손실"
  awk -v v="$cmax" 'BEGIN{ if (v+0>85) exit 1 }' 2>/dev/null || verdict="$verdict+1코어포화"
  awk -v a="${txbw:-0}" -v e="$each" 'BEGIN{ if (a+0 < e*0.95) exit 1 }' 2>/dev/null || verdict="$verdict+레이트미달"

  printf "%-5s  %-11s %-11s  %-10s %-10s  %-9s %-9s  %-6s %s\n" \
    "$each" "${txbw}M" "${rxbw}M" "$txls" "$rxls" "${ctot}%" "${cmax}%" "$ooo" "$verdict"
  sleep 3
done
