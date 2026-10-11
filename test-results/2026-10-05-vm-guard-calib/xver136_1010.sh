#!/bin/bash
# xver136_1010.sh — 1.3.1 ↔ 1.3.6 혼용 실측 래퍼 (2026-10-10, 사용자 요청)
#
# 왜: 서비스망은 전 홉 1.3.1 이다. 1.3.1↔1.3.5 혼용은 §9·§10 에서 쟀지만 1.3.6 과 섞은 적은 없다.
# 조건: sysctl 기본(서비스와 같게 — 측정 중 sysctl -w 로만), c·s SOCK_BUF=4096(기존 conf), 릴레이 전부 --sock-buf 4096
#       (서비스 relay 유닛과 같은 형태 — 1.3.1 은 무시).
#   1부 xver136.sh  : 1단 --upstream 7조합, 10·20 Mbps × 120초 (§9 와 같은 방식)
#   2부 xver2_136.sh: 2단 --route 7조합, 5 Mbps × 120초 (§10 과 같은 방식 — 2단을 한 VM 에 올리면 10 Mbps 이상은 r CPU 로 트립)
# 2부 구성은 §10 그대로 r VM 안에 만든다: 1단 drop-in 으로 --route "KEY .88/.117:4443", 2단 임시 유닛 mfx-r2{a,b}
#   (바이너리 /opt/mfx/multi-fec-dist, 리슨 :4443, --route "KEY .102:443").
# 끝나면 무조건 원상 복구: 임시 유닛·/opt/mfx·drop-in 제거 → sysctl 파일 재적용 → 3대 1.3.1 → 재시작 → 확인.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$R" 'systemctl stop mfx-r2a mfx-r2b 2>/dev/null; rm -f /etc/systemd/system/mfx-r2a.service /etc/systemd/system/mfx-r2b.service; rm -rf /opt/mfx
    rm -rf /etc/systemd/system/multi-fec-relay.service.d /etc/systemd/system/multi-fec-relay-b.service.d; systemctl daemon-reload'
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) dropin=$(ls -d /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) mfx=$(ls /etc/systemd/system/mfx-* /opt/mfx 2>/dev/null | wc -l) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 20 -i 0.5 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

dropin() {  # <unit> <args...> — 1단 relay 의 ExecStart 를 교체
  local u=$1; shift
  ssh "$R" "mkdir -p /etc/systemd/system/$u.service.d && cat > /etc/systemd/system/$u.service.d/xver136.conf" <<EOF
# 2026-10-10 xver136_1010.sh 임시 drop-in (끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l \${LISTEN} $* --upstream-local \${UPSTREAM_LOCAL} --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf 4096
EOF
}

for h in $C $R $S; do ssh "$h" 'sysctl -qw net.core.rmem_max=212992 net.core.wmem_max=212992 net.core.rmem_default=212992 net.core.wmem_default=212992'; done

# ── 1부: 1단 --upstream (기존 유닛 + --sock-buf 4096)
dropin multi-fec-relay   '--upstream ${UPSTREAM} -k ${KEY}'
dropin multi-fec-relay-b '--upstream ${UPSTREAM} -k ${KEY}'
ssh "$R" 'systemctl daemon-reload'
echo "[$(date +%T)] ##### 1부 1단 --upstream"
STEPS="10 20" DUR=120 ./xver136.sh
rc1=$?
echo "[$(date +%T)] 1부 종료 rc=$rc1"

# ── 2부: 2단 --route
dropin multi-fec-relay   '--route "${KEY} 192.168.100.88:4443"'
dropin multi-fec-relay-b '--route "${KEY} 192.168.100.117:4443"'
ssh "$R" 'mkdir -p /opt/mfx && install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /opt/mfx/multi-fec-dist'
for p in "a relay.conf 192.168.100.88" "b relay-b.conf 192.168.100.117"; do set -- $p
  ssh "$R" "cat > /etc/systemd/system/mfx-r2$1.service" <<EOF
[Unit]
Description=xver136 임시 2단 릴레이 $1 (2026-10-10, 끝나면 제거)
[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/$2
ExecStart=/opt/mfx/multi-fec-dist -r -l $3:4443 --route "\${KEY} 192.168.100.102:443" --upstream-local $3 --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf 4096
TimeoutStopSec=3
EOF
done
ssh "$R" 'systemctl daemon-reload && systemctl start mfx-r2a mfx-r2b && systemctl restart multi-fec-relay multi-fec-relay-b'
echo "[$(date +%T)] ##### 2부 2단 --route"
STEPS="5" DUR=120 ./xver2_136.sh
rc2=$?
echo "[$(date +%T)] 2부 종료 rc=$rc2"
echo "[$(date +%T)] 측정 완료"
