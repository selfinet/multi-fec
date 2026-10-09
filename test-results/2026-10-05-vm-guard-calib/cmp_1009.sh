#!/bin/bash
# cmp_1009.sh — 1.3.1 vs 1.3.6 재측정 (2026-10-09, 사용자 승인)
#
# 조건: sysctl 기본(212992) · 1단 --upstream · relay drop-in --sock-buf 4096 (서비스 relay 유닛과 같은 형태).
# 순서 1.3.1(A) → 1.3.6(B) → 1.3.1(C) — 고정 순서 편향을 보려고 1.3.1 을 앞뒤로 둔다.
# 조건마다: 계단 5/10/15/20/25 × 45초 + 지속 10/15/20 × 540초, 둘 다 PING=1(터널 ping 20 pps).
# 끝나면 무조건 원상 복구: sysctl 파일 재적용 → drop-in 제거 → 3대 1.3.1 → 재시작 → 확인.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
DI=/etc/systemd/system/multi-fec-relay.service.d/tp-sockbuf.conf
DIB=/etc/systemd/system/multi-fec-relay-b.service.d/tp-sockbuf.conf

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  ssh "$R" "rm -f $DI $DIB; rmdir /etc/systemd/system/multi-fec-relay.service.d /etc/systemd/system/multi-fec-relay-b.service.d 2>/dev/null; systemctl daemon-reload"
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) dropin=$(ls /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

# relay drop-in (--sock-buf 4096)
for u in multi-fec-relay multi-fec-relay-b; do
  ssh "$R" "mkdir -p /etc/systemd/system/$u.service.d && cat > /etc/systemd/system/$u.service.d/tp-sockbuf.conf" <<'EOF'
# 2026-10-09 1.3.1 vs 1.3.6 재측정용 임시 drop-in (cmp_1009.sh 가 끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l ${LISTEN} --upstream ${UPSTREAM} --upstream-local ${UPSTREAM_LOCAL} -k ${KEY} --obfs-mode quic --auth-interval ${AUTH_INTERVAL} --log-level ${LOG_LEVEL} --sock-buf 4096
EOF
done
ssh "$R" 'systemctl daemon-reload'

for combo in A:131:131:131:def B:136:136:136:def C:131:131:131:def; do
  X=${combo%%:*}
  echo "[$(date +%T)] ##### $X 계단"
  COMBOS=$combo OUT=raw/cmp_lad PFX=cmpl PING=1 STEPS="5 10 15 20 25" DUR=45 ./tp_ladder.sh
  echo "[$(date +%T)] ##### $X 지속"
  COMBOS=$combo OUT=raw/cmp_soak PFX=cmps PING=1 STEPS="10 15 20" DUR=540 ./tp_ladder.sh
done
echo "[$(date +%T)] 측정 완료"
