#!/bin/bash
# buf2m_1017.sh — --sock-buf 2048 낮 시간대 반복 측정 (2026-10-17, 사용자 요청)
#
# 왜: §14 의 2 MB 는 밤 1회뿐이고 10 Mbps 가 15 Mbps 보다 나쁜 역전이 있어 결론을 못 냈다.
#     같은 조건(1.3.6 · sysctl 기본 · 5/10/15/20 Mbps 각 540초 · PING=1)으로 낮에 3회 반복해 런 간 편차를 본다.
# 절차는 maxbuf_1009.sh 2단계와 같다. 끝나면(실패 포함) 무조건 원상 복구.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
DI=/etc/systemd/system/multi-fec-relay.service.d/tp-sockbuf.conf
DIB=/etc/systemd/system/multi-fec-relay-b.service.d/tp-sockbuf.conf
REPS=${REPS:-3}

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'mv /etc/multi-fec/client.conf.bak-buf2m /etc/multi-fec/client.conf 2>/dev/null'
  ssh "$S" 'mv /etc/multi-fec/server.conf.bak-buf2m /etc/multi-fec/server.conf 2>/dev/null'
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  ssh "$R" "rm -f $DI $DIB; rmdir /etc/systemd/system/multi-fec-relay.service.d /etc/systemd/system/multi-fec-relay-b.service.d 2>/dev/null; systemctl daemon-reload"
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) dropin=$(ls /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) $(grep -h ^SOCK_BUF /etc/multi-fec/*.conf 2>/dev/null) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

setbuf() {  # kB — c·s conf + relay drop-in. 재시작은 tp_ladder 가 한다
  ssh "$C" "sed -i 's/^SOCK_BUF=.*/SOCK_BUF=$1/' /etc/multi-fec/client.conf"
  ssh "$S" "sed -i 's/^SOCK_BUF=.*/SOCK_BUF=$1/' /etc/multi-fec/server.conf"
  for u in multi-fec-relay multi-fec-relay-b; do
    ssh "$R" "mkdir -p /etc/systemd/system/$u.service.d && cat > /etc/systemd/system/$u.service.d/tp-sockbuf.conf" <<EOF2
# 2026-10-17 buf2m_1017.sh 임시 drop-in (끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l \${LISTEN} --upstream \${UPSTREAM} --upstream-local \${UPSTREAM_LOCAL} -k \${KEY} --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf $1
EOF2
  done
  ssh "$R" 'systemctl daemon-reload'
}

echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
ssh "$C" 'cp -p /etc/multi-fec/client.conf /etc/multi-fec/client.conf.bak-buf2m'
ssh "$S" 'cp -p /etc/multi-fec/server.conf /etc/multi-fec/server.conf.bak-buf2m'

setbuf 2048
for i in $(seq 1 "$REPS"); do
  echo "[$(date +%T)] ##### 2048 반복 $i/$REPS"
  COMBOS=R$i:136:136:136:def OUT=raw/b2m_1017 PFX=b2m PING=1 STEPS="5 10 15 20" DUR=540 ./tp_ladder.sh
done
echo "[$(date +%T)] 측정 완료"
