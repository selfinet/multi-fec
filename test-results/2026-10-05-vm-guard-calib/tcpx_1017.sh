#!/bin/bash
# tcpx_1017.sh — --sock-buf 1024 vs 4096 TCP 비교 (2026-10-17 저녁, 사용자 요청). bufx_1017.sh 의 TCP 판
#
# 왜: 같은 버퍼 안의 런 간 편차가 버퍼 간 차이보다 컸다(buf2m_1017). 순서를 라운드마다 돌려 시간대 편향을 상쇄한다.
#     sysctl 기본 · 1.3.6 · iperf3 TCP --bidir 10/20 Mbps 각 180초 · PING=1 · 라운드 3 × 버퍼 2 = 6회.
# 절차는 maxbuf_1009.sh 2단계와 같다. 끝나면(실패 포함) 무조건 원상 복구.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
DI=/etc/systemd/system/multi-fec-relay.service.d/tp-sockbuf.conf
DIB=/etc/systemd/system/multi-fec-relay-b.service.d/tp-sockbuf.conf
REPS=${REPS:-3}

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'mv /etc/multi-fec/client.conf.bak-tcpx /etc/multi-fec/client.conf 2>/dev/null'
  ssh "$S" 'mv /etc/multi-fec/server.conf.bak-tcpx /etc/multi-fec/server.conf 2>/dev/null'
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
# 2026-10-17 tcpx_1017.sh 임시 drop-in (끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l \${LISTEN} --upstream \${UPSTREAM} --upstream-local \${UPSTREAM_LOCAL} -k \${KEY} --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf $1
EOF2
  done
  ssh "$R" 'systemctl daemon-reload'
}

echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
ssh "$C" 'cp -p /etc/multi-fec/client.conf /etc/multi-fec/client.conf.bak-tcpx'
ssh "$S" 'cp -p /etc/multi-fec/server.conf /etc/multi-fec/server.conf.bak-tcpx'

ORDER=${ORDER:-"1024 4096 / 4096 1024 / 1024 4096"}
r=1
for kb in $ORDER; do
  [ "$kb" = / ] && { r=$((r+1)); continue; }
  echo "[$(date +%T)] ##### 라운드 $r · sock-buf $kb"
  setbuf "$kb"
  RUNNER=./run_tcp.sh COMBOS=T${kb}_r$r:136:136:136:def OUT=raw/tcpx_1017 PFX=tx PING=1 STEPS="${STEPS:-10 20}" DUR=${DUR:-180} ./tp_ladder.sh
done
echo "[$(date +%T)] 측정 완료"
