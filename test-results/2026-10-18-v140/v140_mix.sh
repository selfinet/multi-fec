#!/bin/bash
# v140_mix.sh — FEC 모드 혼용 재측정: 혼용 반복 + 양쪽 0 (2026-10-18, 테스트망 전용)
#
# 왜: 1.4.0 은 데이터 경로 코드를 바꾸지 않았지만(송신에 ipi_ifindex 만 추가) 기본값이 바뀌었다.
#     1.3.6 · --sock-buf 4096 저녁 측정(raw/bufx_1017/K4096_r*)과 같은 조건으로 손실·지연이 같은지 본다.
#     FEC 모드 혼용(client 0 / server 1)은 손실 있는 경로(netem)에서 복구까지 되는지 본다 — 루프백은 무손실이었다.
# 구성: 기존 유닛(전 옵션 명시) + 1.4.0 바이너리, sysctl 기본, relay drop-in 없음(relay 는 1.4.0 기본 sock-buf 4096).
# 하네스: ../2026-10-05-vm-guard-calib/tp_ladder.sh (가드 GW_NET=new 선기동, mfgen, PING=1). 끝나면 무조건 원상 복구.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
LAD=../2026-10-05-vm-guard-calib/tp_ladder.sh
OUT=../2026-10-18-v140/raw/load        # tp_ladder 는 자기 디렉터리 기준
DUR=${DUR:-180}; STEPS=${STEPS:-"10 20"}

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'mv /etc/multi-fec/client.conf.bak-v140mix /etc/multi-fec/client.conf 2>/dev/null'
  ssh "$S" 'mv /etc/multi-fec/server.conf.bak-v140mix /etc/multi-fec/server.conf 2>/dev/null'
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  # 1.4.0 시험 산출물 제거: 템플릿 유닛 · 새 형식 conf · route 파일
  for h in $C $R $S; do
    ssh "$h" 'systemctl stop "multi-fec@*" 2>/dev/null; rm -f /etc/systemd/system/multi-fec@.service /etc/multi-fec/*-140.conf /etc/multi-fec/c140.conf /etc/multi-fec/s140.conf /etc/multi-fec/routes-r2 /root/r2-140.conf.upstream /run/multi-fec/*140*.fifo /run/multi-fec/*.routes; systemctl daemon-reload'
  done
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) dropin=$(ls -d /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) tmpl=$(ls /etc/systemd/system/multi-fec@.service 2>/dev/null | wc -l) confs=$(ls /etc/multi-fec | tr "\n" " ")$(grep -h ^FEC_MODE /etc/multi-fec/client.conf /etc/multi-fec/server.conf 2>/dev/null | tr "\\n" " ") $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
# 템플릿 인스턴스 → 기존 유닛 (같은 포트를 두 프로세스가 잡지 않게 먼저 멈춘다)
for h in $C $R $S; do ssh "$h" 'systemctl stop "multi-fec@*" 2>/dev/null; true'; done
ssh "$C" 'cp -p /etc/multi-fec/client.conf /etc/multi-fec/client.conf.bak-v140mix'

run() { COMBOS="$1:140:140:140:def" OUT=$OUT PFX=v140 PING=1 STEPS="$STEPS" DUR=$DUR $LAD; }
ssh "$S" 'cp -p /etc/multi-fec/server.conf /etc/multi-fec/server.conf.bak-v140mix'
echo "[$(date +%T)] ##### 혼용 반복 client 0 / server 1"
ssh "$C" "sed -i 's/^FEC_MODE=.*/FEC_MODE=0/' /etc/multi-fec/client.conf"
run V140_mix2
echo "[$(date +%T)] ##### 양쪽 0"
ssh "$S" "sed -i 's/^FEC_MODE=.*/FEC_MODE=0/' /etc/multi-fec/server.conf"
run V140_m00
echo "[$(date +%T)] 측정 완료"
