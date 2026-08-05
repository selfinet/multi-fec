#!/bin/bash
# 전 호스트 전 인터페이스 누적 바이트 스냅샷. 두 스냅샷의 차로 구간 총량을 낸다.
# /proc/net/dev 는 콜론을 먼저 떼야 필드가 맞는다 → $1=iface $2=rx_bytes $10=tx_bytes
# 사용: ifbytes.sh snap <출력파일>   /   ifbytes.sh diff <전> <후> [라벨]
set -u
HOSTS="c r s"

case "${1:-}" in
snap)
  OUT=${2:?출력파일}
  : > "$OUT"
  for h in $HOSTS; do
    ssh -o ConnectTimeout=5 "$h.xdn.selfinet.com" \
      "sed 's/:/ /' /proc/net/dev | awk 'NR>2 && \$1!=\"lo\" {print \$1, \$2, \$10}'" 2>/dev/null \
      | awk -v h="$h" '{print h"/"$1, $2, $3}' >> "$OUT" &
  done
  wait
  sort -o "$OUT" "$OUT"
  ;;
diff)
  A=${2:?전}; B=${3:?후}; LB=${4:-구간}
  echo "=== $LB — 구간 누적 전송량 ==="
  join "$A" "$B" 2>/dev/null | awk '
    { rx=($4-$2)/1e6; tx=($5-$3)/1e6
      if (rx>0.05 || tx>0.05) printf "  %-20s RX %9.2f  TX %9.2f MB\n", $1, rx, tx }' | sort
  ;;
*) echo "사용: $0 snap <파일> | $0 diff <전> <후> [라벨]"; exit 1 ;;
esac
