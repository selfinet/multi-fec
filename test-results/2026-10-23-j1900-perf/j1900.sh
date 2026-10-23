#!/bin/bash
# j1900.sh — J1900 하드웨어 · multi-fec 1.4.1 성능 (2026-10-23, 여분 장비 2대, 사용자 지시)
#
#   client j86 = 192.168.2.86 (dj19) · server j83 = 192.168.2.83 (NF01M), 같은 LAN 100 Mb/s 직결(0.27 ms)
#   경로 2개: client → .83:443 · → .250:443 (server 보조 IP, 시험 동안만)
#   WG `wg-mft` 10.9.30.2 ↔ 10.9.30.1 (설정 파일 없이 ip/wg 명령으로만, MTU 1300)
#
#   H1 직접 UDP(multi-fec·WG 없음)  H2 WG 만  M1 duplicate 1.4.1  M2 duplicate 1.4.0  M3 aggregate 1.4.1
#   단계마다 양방향 mfgen 60초, 양쪽 호스트 샘플러(mf-hostsamp.sh), 가드 GW_NET=j1900(링크 백스톱 195 Mbps).
#
#   바꾸는 것(전부 복구): /opt/mftest · sysctl rmem/wmem_max(→8 MB, 원래 212992) · .83 보조 IP .250 · wg-mft 인터페이스 ·
#   systemd-run 임시 유닛 mft-client/mft-server. 끝나면(중단돼도) teardown 후 baseline/*.txt 와 대조.
set -u
cd "$(dirname "$0")"
C=j86; S=j83
CW=10.9.30.2; SW=10.9.30.1
DUR=${DUR:-60}
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
mkdir -p raw

teardown() {
  echo "[$(date +%T)] ===== 복구"
  for h in $C $S; do ssh -o BatchMode=yes $h '
    systemctl stop mft-client mft-server 2>/dev/null; systemctl reset-failed mft-client mft-server 2>/dev/null
    [ -f /opt/mftest/netem.conf ] && CONF=/opt/mftest/netem.conf /opt/mftest/mf-netem.sh clear >/dev/null 2>&1
    lsmod | grep -q "^ifb " && [ -f /opt/mftest/loaded-ifb ] && rmmod ifb 2>/dev/null
    lsmod | grep -q "^sch_netem " && [ -f /opt/mftest/loaded-netem ] && rmmod sch_netem 2>/dev/null
    pkill -x mfgen 2>/dev/null; [ -f /tmp/mft_hs.csv.pid ] && kill $(cat /tmp/mft_hs.csv.pid) 2>/dev/null
    ip link del wg-mft 2>/dev/null
    ip addr del 192.168.2.250/24 dev enp3s0 2>/dev/null
    sysctl -q -w net.core.rmem_max=212992 net.core.wmem_max=212992
    rm -rf /opt/mftest /tmp/mft_* /run/multi-fec/mft*' ; done
  [ -n "${GP:-}" ] && { kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null; }
  ./verify.sh
}

setup() {
  echo "[$(date +%T)] ===== 설치"
  KEY=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')     # 시험 전용 키 (출력하지 않음)
  for h in $C $S; do
    ssh -o BatchMode=yes $h 'mkdir -p /opt/mftest/v141 /opt/mftest/v140 && chmod 700 /opt/mftest'
    scp -q bin/mf-141v5 $h:/opt/mftest/v141/multi-fec-dist
    scp -q bin/mf-140   $h:/opt/mftest/v140/multi-fec-dist
    scp -q bin/mfgen bin/mf-hostsamp.sh $h:/opt/mftest/
    ssh -o BatchMode=yes $h 'chmod 755 /opt/mftest/*/multi-fec-dist /opt/mftest/mfgen /opt/mftest/mf-hostsamp.sh
      sysctl -q -w net.core.rmem_max=8388608 net.core.wmem_max=8388608
      umask 077; wg genkey > /opt/mftest/wg.key; wg pubkey < /opt/mftest/wg.key > /opt/mftest/wg.pub'
  done
  ssh -o BatchMode=yes $S 'ip addr add 192.168.2.250/24 dev enp3s0'
  CP=$(ssh -o BatchMode=yes $C cat /opt/mftest/wg.pub); SP=$(ssh -o BatchMode=yes $S cat /opt/mftest/wg.pub)
  ssh -o BatchMode=yes $S "ip link add wg-mft type wireguard && wg set wg-mft listen-port 51830 private-key /opt/mftest/wg.key peer $CP allowed-ips $CW/32 &&
    ip addr add $SW/24 dev wg-mft && ip link set wg-mft mtu 1300 up"
  ssh -o BatchMode=yes $C "ip link add wg-mft type wireguard && wg set wg-mft private-key /opt/mftest/wg.key peer $SP allowed-ips $SW/32 endpoint 127.0.0.1:51831 persistent-keepalive 25 &&
    ip addr add $CW/24 dev wg-mft && ip link set wg-mft mtu 1300 up"
  ssh -o BatchMode=yes $S "umask 077; cat > /opt/mftest/server.conf" <<EOF
mode = server
listen = 0.0.0.0:443
wg = 127.0.0.1:51830
key = $KEY
multipath-mode = duplicate
log-level = 4
report = 60
EOF
  ssh -o BatchMode=yes $C "umask 077; cat > /opt/mftest/client.conf" <<EOF
mode = client
wg = 127.0.0.1:51831
path = 192.168.2.83:443
path = 192.168.2.250:443
key = $KEY
multipath-mode = duplicate
log-level = 4
report = 60
EOF
  unset KEY
  if [ "${NETEM:-0}" = 1 ]; then
    scp -q bin/mf-netem.sh bin/netem.conf $S:/opt/mftest/
    ssh -o BatchMode=yes $S 'lsmod | grep -q "^ifb " || touch /opt/mftest/loaded-ifb
      lsmod | grep -q "^sch_netem " || touch /opt/mftest/loaded-netem
      chmod 755 /opt/mftest/mf-netem.sh; CONF=/opt/mftest/netem.conf /opt/mftest/mf-netem.sh apply; tc qdisc show dev enp3s0 | grep netem; tc qdisc show dev ifb0 | grep netem'
  fi
  # 규칙 2: 하부 주소가 터널로 가면 안 된다
  for h in $C $S; do ssh -o BatchMode=yes $h 'n=0; for ip in 192.168.2.83 192.168.2.86 192.168.2.250; do ip route get $ip | head -1 | grep -q wg && n=$((n+1)); done; echo "$(hostname) 규칙2 위반 $n"'; done
}

endpoint() { # mf | direct
  local sp; sp=$(ssh -o BatchMode=yes $S cat /opt/mftest/wg.pub)
  if [ "$1" = direct ]; then ssh -o BatchMode=yes $C "wg set wg-mft peer $sp endpoint 192.168.2.83:51830"
  else ssh -o BatchMode=yes $C "wg set wg-mft peer $sp endpoint 127.0.0.1:51831"; fi
}

mf_start() { # ver mode
  local ver=$1 mode=$2 h role
  for h in "$S server" "$C client"; do role=${h#* }; h=${h%% *}
    ssh -o BatchMode=yes $h "systemctl stop mft-$role 2>/dev/null; systemctl reset-failed mft-$role 2>/dev/null
      sed -i 's/^multipath-mode = .*/multipath-mode = $mode/' /opt/mftest/$role.conf
      systemd-run -q --unit=mft-$role /opt/mftest/$ver/multi-fec-dist --config /opt/mftest/$role.conf"
  done
  set -- $ver $mode
  for i in $(seq 1 12); do ssh -o BatchMode=yes $C "ping -c 3 -W 1 -q $SW" >/dev/null 2>&1 && break; sleep 5; done
  sleep 10
  echo "  $1 $2: $(ssh -o BatchMode=yes $C "sha256sum /opt/mftest/$1/multi-fec-dist | cut -c1-12; systemctl is-active mft-client" | tr '\n' ' ') server $(ssh -o BatchMode=yes $S 'systemctl is-active mft-server')"
}
mf_stop() { for h in "$C client" "$S server"; do set -- $h; ssh -o BatchMode=yes $1 "systemctl stop mft-$2 2>/dev/null; systemctl reset-failed mft-$2 2>/dev/null"; done; }

step() { # tag rate dst_c dst_s   (c 가 dst_s 로, s 가 dst_c 로 보낸다)
  local tag=$1 r=$2 dc=$3 ds=$4 O=raw/$1_$2
  mkdir -p $O; kill -0 $GP 2>/dev/null || { echo "  가드 소멸(트립?) — 중단"; tail -3 raw/guard.log; exit 3; }
  local t0; t0=$(date +%s)
  for h in $C $S; do ssh -o BatchMode=yes $h "setsid nohup /opt/mftest/mf-hostsamp.sh /tmp/mft_hs.csv enp3s0 >/dev/null 2>&1 < /dev/null &"; done
  ssh -o BatchMode=yes $S "/opt/mftest/mfgen rx $ds 5301 $((DUR+4)) > /tmp/mft_up.txt" >/dev/null 2>&1 & local A1=$!
  ssh -o BatchMode=yes $C "/opt/mftest/mfgen rx $dc 5302 $((DUR+4)) > /tmp/mft_dn.txt" >/dev/null 2>&1 & local A2=$!
  sleep 1
  ssh -o BatchMode=yes $C "/opt/mftest/mfgen tx $ds 5301 $r $DUR" >/dev/null 2>&1 & local B1=$!
  ssh -o BatchMode=yes $S "/opt/mftest/mfgen tx $dc 5302 $r $DUR" >/dev/null 2>&1 & local B2=$!
  wait $B1; wait $B2; wait $A1; wait $A2
  for h in "c $C" "s $S"; do set -- $h
    ssh -o BatchMode=yes $2 'kill $(cat /tmp/mft_hs.csv.pid) 2>/dev/null'; scp -q $2:/tmp/mft_hs.csv $O/hs_$1.csv
    ssh -o BatchMode=yes $2 "journalctl -u mft-client -u mft-server --since @$t0 --no-pager -o short-unix 2>/dev/null" | sed 's/\x1b\[[0-9;]*m//g' > $O/log_$1.txt
  done
  scp -q $S:/tmp/mft_up.txt $O/up.txt; scp -q $C:/tmp/mft_dn.txt $O/dn.txt
  local u d e
  u=$(awk '/^total/{print $9}' $O/up.txt); d=$(awk '/^total/{print $9}' $O/dn.txt); e=$(grep -c EAGAIN $O/log_c.txt)
  printf "[run] %-8s %3s Mbps  up %s%%  dn %s%%  cliEAGAIN %s  %s\n" $tag $r "$u" "$d" "$e" "$(python3 cpu.py $O)" | tee -a raw/summary.txt
  grep -q 트립 raw/guard.log && { echo "[run] 가드 트립"; grep 트립 raw/guard.log | tail -1; exit 4; }
  awk -v u="${u:-100}" -v d="${d:-100}" 'BEGIN{exit !(u>20 || d>20)}' && return 1
  sleep 3; return 0
}

oneway() { # tag rate dir(up|dn) — 한 방향만 30초, 양쪽 CPU (송신·수신 비용 분리)
  local tag=$1 r=$2 dir=$3 O=raw/$1_$2_$3; mkdir -p $O
  for h in $C $S; do ssh -o BatchMode=yes $h "setsid nohup /opt/mftest/mf-hostsamp.sh /tmp/mft_hs.csv enp3s0 >/dev/null 2>&1 < /dev/null &"; done
  if [ $dir = up ]; then
    ssh -o BatchMode=yes $S "/opt/mftest/mfgen rx 192.168.2.83 5301 34 > /tmp/mft_up.txt" >/dev/null 2>&1 & local A=$!; sleep 1
    ssh -o BatchMode=yes $C "/opt/mftest/mfgen tx 192.168.2.83 5301 $r 30" >/dev/null 2>&1
  else
    ssh -o BatchMode=yes $C "/opt/mftest/mfgen rx 192.168.2.86 5302 34 > /tmp/mft_up.txt" >/dev/null 2>&1 & local A=$!; sleep 1
    ssh -o BatchMode=yes $S "/opt/mftest/mfgen tx 192.168.2.86 5302 $r 30" >/dev/null 2>&1
  fi
  wait $A
  for h in "c $C" "s $S"; do set -- $h; ssh -o BatchMode=yes $2 'kill $(cat /tmp/mft_hs.csv.pid) 2>/dev/null'; scp -q $2:/tmp/mft_hs.csv $O/hs_$1.csv; done
  printf "[run] %-8s %3s Mbps %s  %s\n" $tag $r $dir "$(python3 cpu.py $O)" | tee -a raw/summary.txt
}

ladder() { # tag rates dst_c dst_s
  local tag=$1; shift; local rates=$1 dc=$2 ds=$3
  for r in $rates; do step $tag $r $dc $ds || { echo "  [$tag] $r Mbps 손실 20% 초과 — 계단 중단"; break; }; done
}

trap teardown EXIT
setup
export GW_NET=j1900 GW_PROFILE=vm GW_CPU_C=99 GW_CPU_VM=99 GW_CORE=101 GW_LINK=195
setsid "$G" watch "mfgen tx" > raw/guard.log 2>&1 < /dev/null & GP=$!
sleep 12; kill -0 $GP 2>/dev/null && grep -q '감시 시작' raw/guard.log || { echo "가드 기동 실패"; cat raw/guard.log; exit 2; }
echo "[run] 가드 PID $GP (링크 백스톱 195 Mbps, CPU 임계 해제 — 성능 한계 측정)"

if [ -n "${PLAN:-}" ]; then
  eval "$PLAN"; mf_stop; echo "[$(date +%T)] J1900_DONE"; exit 0
fi
if [ "${SKIP_H:-0}" != 1 ]; then
echo "[$(date +%T)] ##### H1 직접 UDP (multi-fec·WG 없음)"
ladder H1raw "10 20 40" 192.168.2.86 192.168.2.83
echo "[$(date +%T)] ##### H2 WireGuard 만"
endpoint direct; sleep 5
ladder H2wg "10 20 40" $CW $SW
endpoint mf
fi
echo "[$(date +%T)] ##### H0 한 방향 진단 (직접 UDP 40 Mbps)"
oneway H0 40 up; oneway H0 40 dn
echo "[$(date +%T)] ##### M1 duplicate 1.4.1"
mf_start v141 duplicate; ladder M1dup141 "5 10 15 20 25 30" $CW $SW
echo "[$(date +%T)] ##### M2 duplicate 1.4.0"
mf_start v140 duplicate; ladder M2dup140 "5 10 15 20 25 30" $CW $SW
echo "[$(date +%T)] ##### M3 aggregate 1.4.1"
mf_start v141 aggregate; ladder M3agg141 "10 20 30 40" $CW $SW
mf_stop
echo "[$(date +%T)] J1900_DONE"
