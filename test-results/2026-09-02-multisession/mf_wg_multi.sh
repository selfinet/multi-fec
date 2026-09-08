#!/bin/bash
# mf_wg_multi.sh — **세션별 WireGuard** 다중 세션 소크 (테스트망 전용)
#
# 왜 새로 짰나 (2026-09-02)
# ------------------------
# 앞선 다중 세션 시험(mf_multi_soak.sh)에는 **WireGuard 가 하나도 없었다.**
# blaster → multi-fec client → relay → server → echo 였고, 하네스에 보이는
# `--wg 127.0.0.1:44444` 는 multi-fec 의 옵션 이름일 뿐 실제 WG 가 아니다.
# 그런데 실서비스는 **지사마다 독립 WG 터널**이라 세션 수만큼 암복호가 붙는다.
# 그 비용이 빠진 측정은 낙관적으로 치우친다 → 이 하네스가 그 구조를 재현한다.
#
# 구조 (세션 i = 지사 i)
#   [mf_blast] 10.9.(NB+i).2 ──wg mft{i}── 10.9.(NB+i).1 [rt_echo_ip]
#        c: Endpoint=127.0.0.1:CLIP+i           s: ListenPort=WGSP+i
#             │                                        ▲
#        multi-fec client{i} ─┬─▶ r .85:4443 ─┐        │
#                             └─▶ r .86:4443 ─┴─▶ multi-fec server{i} (.84:SRVP+i)
#                                 (--route 로 키별 분기, 릴레이 2개)
#
# 운영 무침습: 이름·주소·포트를 운영과 완전히 분리한다
#   WG 이름 mft0..9 (운영 starlink-fec) · 서브넷 10.9.20~29 (운영 10.9.9/10.9.10)
#   클라 포트 51900~ (운영 51821) · 서버 포트 4500~ (운영 443) · 릴레이 4443 (운영 443)
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com; S=s.xdn.selfinet.com
SRC=192.168.100.141; RA=192.168.100.85; RB=192.168.100.86; SRV=192.168.100.84
N=${N:-10}; SECS=${SECS:-3600}; MBPS=${MBPS:-1}      # MBPS = 세션당 각 방향
NB=${NB:-20}                                          # 10.9.(NB+i).0/24
RPORT=4443; SRVP=4500; CLIP=51900; WGSP=51900; ECHOP=44450
KEY=wgmulti-$(date +%s)
GUARD=/home/stevekim/multi-fec/test-results/2026-08-02-50mbps-soak/mf_gwguard.sh
# 다중 세션 구조는 c 전체 CPU 가 단일 세션과 완전히 다르다(단일 20 Mbps max 53.9% vs
# 10지사 상시 68~93%). 가드 프로파일을 multi 로 고정한다 — 근거는 가드 헤더의 검증 표.
export GW_PROFILE=${GW_PROFILE:-multi}
HERE=/home/stevekim/multi-fec/test-results/2026-09-02-multisession
OUT=${OUT:-$HERE/wg_raw}
mkdir -p "$OUT"

ifsnap() { for h in $C $R $S; do
    ssh -o ConnectTimeout=5 "$h" "awk -v H=${h%%.*} -v L=$1 -v T=\$(date +%s) '
      NR>2 { gsub(/:/,\"\",\$1); if (\$1!=\"lo\") print L, H, \$1, \$2, \$10, T }' /proc/net/dev" 2>/dev/null
done; }

cleanup() {
  echo; echo "[$(date +%H:%M:%S)] 정리"
  ssh $C 'pkill -f "[m]f_blast"' 2>/dev/null
  # ⚠️ 포트 범위를 반드시 남길 것. `127.0.0.1:519` 로 줄여도 운영(:51821)은 안 맞지만
  #    습관을 깨지 않는다 — 2026-08-07 에 범위를 줄여 운영 클라를 죽인 전례가 있다.
  ssh $C "pkill -f '[m]ulti-fec-dist -c -l 127.0.0.1:519[0-9][0-9]'" 2>/dev/null
  ssh $R "pkill -f '[m]ulti-fec-dist -r -l 192.168.100.8[56]:$RPORT'" 2>/dev/null
  ssh $S "pkill -f '[m]ulti-fec-dist -s -l $SRV:45'; pkill -f '[r]t_echo_ip.py'" 2>/dev/null
  for h in $C $S; do
    ssh $h 'for i in $(seq 0 15); do wg-quick down mft$i >/dev/null 2>&1; rm -f /etc/wireguard/mft$i.conf; done' 2>/dev/null
  done
  for h in $C $R; do ssh $h 'sudo systemctl restart mf-netem' 2>/dev/null; done
  echo "  남은 WG:   c=$(ssh $C 'wg show interfaces' 2>/dev/null) | s=$(ssh $S 'wg show interfaces' 2>/dev/null)"
  echo "  운영 체인: c=$(ssh $C 'systemctl is-active multi-fec-client' 2>/dev/null)" \
       "r=$(ssh $R 'systemctl is-active multi-fec-relay multi-fec-relay@b|tr "\n" " "' 2>/dev/null)" \
       "s=$(ssh $S 'systemctl is-active multi-fec-server' 2>/dev/null)"
  ssh $C 'tc qdisc show | grep -oE "delay [0-9]+ms loss [0-9]+%" | tr "\n" " "' 2>/dev/null | sed 's/^/  netem /'; echo
}
trap cleanup EXIT INT TERM

echo "=== 0. 사전 판정 (세션 $N × 각 방향 ${MBPS} Mbps · 세션별 WG) ==="
$GUARD budget "$(awk -v m=$MBPS 'BEGIN{print m*2}')" "$N" || true
echo "  ↑ 모델은 WG 암복호를 포함하지 않는다. 게이트는 precheck 와 가드다."

echo; echo "=== 1. precheck ==="
$GUARD precheck || { echo "precheck 실패 — 중단"; exit 1; }

echo; echo "=== 2. 배포 ==="
scp -q $HERE/mf_blast      $C:/tmp/mf_blast      || { echo "  ✗ mf_blast"; exit 1; }
scp -q $HERE/rt_echo_ip.py $S:/tmp/rt_echo_ip.py || { echo "  ✗ rt_echo_ip"; exit 1; }
for h in $C $R $S; do scp -q $HERE/rt_sample.sh $h:/tmp/rt_sample.sh || { echo "  ✗ rt_sample ($h)"; exit 1; }
  ssh $h 'chmod 755 /tmp/rt_sample.sh' 2>/dev/null; done
ssh $C 'chmod 755 /tmp/mf_blast' 2>/dev/null; ssh $S 'chmod 755 /tmp/rt_echo_ip.py' 2>/dev/null
echo "  완료"

echo; echo "=== 3. 세션별 WG 키·설정 ($N 쌍) ==="
KEYS=$(ssh $S "for i in \$(seq 0 $((N-1))); do
  cp=\$(wg genkey); sp=\$(wg genkey)
  echo \"\$i \$cp \$(echo \$cp|wg pubkey) \$sp \$(echo \$sp|wg pubkey)\"
done" 2>/dev/null)
[ -n "$KEYS" ] || { echo "  ✗ 키 생성 실패"; exit 1; }
CCONF=""; SCONF=""
while read -r i cpriv cpub spriv spub; do
  [ -n "${i:-}" ] || continue
  net=$((NB+i))
  CCONF="$CCONF
cat > /etc/wireguard/mft$i.conf <<EOF
[Interface]
PrivateKey = $cpriv
Address = 10.9.$net.2/24
MTU = 1300
Table = off
[Peer]
PublicKey = $spub
AllowedIPs = 10.9.$net.1/32
Endpoint = 127.0.0.1:$((CLIP+i))
PersistentKeepalive = 25
EOF"
  SCONF="$SCONF
cat > /etc/wireguard/mft$i.conf <<EOF
[Interface]
PrivateKey = $spriv
Address = 10.9.$net.1/24
ListenPort = $((WGSP+i))
MTU = 1300
Table = off
[Peer]
PublicKey = $cpub
AllowedIPs = 10.9.$net.2/32
EOF"
done <<< "$KEYS"
ssh $C "$CCONF" 2>/dev/null; ssh $S "$SCONF" 2>/dev/null
echo "  설정 파일 c/s 각 $N 개"

echo; echo "=== 4. netem 필터 (:$RPORT) ==="
ssh $C "IF=\$(ip -o -4 route show default | awk '{print \$5}' | head -1)
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip dst $RA/32 match ip dport $RPORT 0xffff flowid 1:1
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip dst $RB/32 match ip dport $RPORT 0xffff flowid 1:2" 2>/dev/null
ssh $R "IF=\$(ip -o -4 route show default | awk '{print \$5}' | head -1)
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip src $RA/32 match ip sport $RPORT 0xffff flowid 1:1
  sudo tc filter add dev \$IF protocol ip parent 1: prio 2 u32 match ip protocol 17 0xff match ip src $RB/32 match ip sport $RPORT 0xffff flowid 1:2" 2>/dev/null
for h in $C $R; do printf "  %s " "${h%%.*}"
  ssh $h 'tc filter show dev $(ip -o -4 route show default|awk "{print \$5}"|head -1) parent 1: 2>/dev/null | grep -oE "flowid 1:[12]" | sort | uniq -c | tr "\n" " "' 2>/dev/null; echo; done

echo; echo "=== 5. s: 서버 $N 개 + echo $N 개, WG 기동 ==="
ssh $S "for i in \$(seq 0 $((N-1))); do
  setsid nohup /usr/sbin/multi-fec-dist -s -l $SRV:\$(($SRVP+i)) --wg 127.0.0.1:\$(($WGSP+i)) \
    -k ${KEY}-\$i --obfs-mode quic --auth-interval 60 --multipath-mode duplicate \
    -f 5:1,20:4 --mode 1 --fec-timeout 10 --mtu 1350 --decode-buf 2000 --queue-len 500 \
    --sock-buf 4096 --log-level 4 </dev/null >/tmp/wgsrv\$i.log 2>&1 &
done; sleep 2
for i in \$(seq 0 $((N-1))); do wg-quick up mft\$i >/dev/null 2>&1; done
sleep 1
for i in \$(seq 0 $((N-1))); do
  setsid nohup /tmp/rt_echo_ip.py 10.9.\$(($NB+i)).1 $ECHOP </dev/null >/tmp/wgecho\$i.log 2>&1 &
done; sleep 1; exit 0" 2>/dev/null
echo "  s: server=$(ssh $S "pgrep -cf '[m]ulti-fec-dist -s -l $SRV:45'" 2>/dev/null|head -1)" \
     "echo=$(ssh $S "pgrep -cf '[r]t_echo_ip.py'" 2>/dev/null|head -1)" \
     "wg=$(ssh $S 'wg show interfaces' 2>/dev/null | wc -w)"

echo; echo "=== 6. r: 릴레이 2개 (--route 로 $N 키 분기) ==="
ROUTES=""; for i in $(seq 0 $((N-1))); do ROUTES="$ROUTES --route \"${KEY}-$i $SRV:$((SRVP+i))\""; done
for A in $RA $RB; do
  ssh $R "setsid nohup /usr/sbin/multi-fec-dist -r -l $A:$RPORT $ROUTES \
    --obfs-mode quic --auth-interval 60 --log-level 4 </dev/null >/tmp/wgrelay_\${A##*.}.log 2>&1 &
    sleep 0.3; exit 0" 2>/dev/null
done
sleep 2
echo "  r: relay=$(ssh $R "pgrep -cf '[m]ulti-fec-dist -r -l 192.168.100.8[56]:$RPORT'" 2>/dev/null|head -1)"

echo; echo "=== 7. c: 클라이언트 $N 개 + WG 기동 ==="
ssh $C "for i in \$(seq 0 $((N-1))); do
  setsid nohup /usr/sbin/multi-fec-dist -c -l 127.0.0.1:\$(($CLIP+i)) \
    --path $SRC:$RA:$RPORT --path $SRC:$RB:$RPORT -k ${KEY}-\$i \
    --obfs-mode quic --auth-interval 60 --multipath-mode duplicate \
    -f 5:1,20:4 --mode 1 --fec-timeout 10 --mtu 1350 --decode-buf 2000 --queue-len 500 \
    --sock-buf 4096 --log-level 4 </dev/null >/tmp/wgcli\$i.log 2>&1 &
done; sleep 6
for i in \$(seq 0 $((N-1))); do wg-quick up mft\$i >/dev/null 2>&1; done
sleep 3; exit 0" 2>/dev/null
echo "  c: client=$(ssh $C "pgrep -cf '[m]ulti-fec-dist -c -l 127.0.0.1:519'" 2>/dev/null|head -1)" \
     "wg=$(ssh $C 'wg show interfaces' 2>/dev/null | wc -w)"

echo; echo "=== 8. WG 핸드셰이크 확인 (터널이 실제로 붙었나) ==="
sleep 8
HS=$(ssh $C "ok=0; for i in \$(seq 0 $((N-1))); do
  t=\$(wg show mft\$i latest-handshakes 2>/dev/null | awk '{print \$2}'); [ -n \"\$t\" ] && [ \"\$t\" != 0 ] && ok=\$((ok+1)); done; echo \$ok" 2>/dev/null)
PING=$(ssh $C "ok=0; for i in \$(seq 0 $((N-1))); do
  ping -c1 -W2 -I 10.9.\$(($NB+i)).2 10.9.\$(($NB+i)).1 >/dev/null 2>&1 && ok=\$((ok+1)); done; echo \$ok" 2>/dev/null)
echo "  핸드셰이크 $HS/$N · 터널 ping $PING/$N"
[ "${PING:-0}" -eq "$N" ] || { echo "  ✗ 터널 $N 개가 다 붙지 않았다 — 중단"; exit 1; }

echo; echo "=== 9. 샘플러 + 가드 ==="
ssh $C "nohup /tmp/rt_sample.sh 'multi-fec-dist -c -l 127.0.0.1:519' /tmp/wg_c.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $R "nohup /tmp/rt_sample.sh 'multi-fec-dist -r -l 192.168.100.8[56]:$RPORT' /tmp/wg_r.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
ssh $S "nohup /tmp/rt_sample.sh 'multi-fec-dist -s -l $SRV:45' /tmp/wg_s.csv $((SECS+180)) >/dev/null 2>&1 &" 2>/dev/null
# ⚠️ 패턴은 실제 cmdline 과 맞아야 한다. `mf_blast --sessions` 는 사이에 `--no-clients`
# 가 껴 있어 매치되지 않았다(스모크에서 발견 — CSV 가 헤더만 남는다). comm 필터가
# 샘플러 자신을 걸러주므로 패턴은 이름만으로 충분하다.
ssh $C "nohup /tmp/rt_sample.sh 'mf_blast' /tmp/wg_blast.csv $((SECS+180)) mf_blast >/dev/null 2>&1 &" 2>/dev/null
nohup $GUARD watch "mf_blast" > $OUT/watchdog.log 2>&1 &
WD=$!
sleep 12
kill -0 $WD 2>/dev/null && echo "  가드 살아있음 pid=$WD" || { echo "  ✗ 가드 사망 — 중단"; exit 1; }

echo; echo "=== 10. 부하 ${SECS}s (세션 $N × 각 ${MBPS} Mbps, WG 터널 안) — $(date +%H:%M:%S) ==="
ifsnap load0 > $OUT/ifsnap.txt
( while kill -0 $WD 2>/dev/null; do sleep 10; done
  echo "[$(date +%H:%M:%S)] ✗ 가드 소멸 — 부하 중단" >> $OUT/guard_died.log
  ssh $C "pkill -f '[m]f_blast'" 2>/dev/null ) &
GW=$!
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 $C \
  "/tmp/mf_blast --no-clients --sessions $N --mbps $MBPS --secs $SECS \
   --src-fmt '10.9.%d.2' --dst-fmt '10.9.%d.1' --net-base $NB --dst-port $ECHOP" \
  2>$OUT/blast.err | tee $OUT/result.csv
kill $GW 2>/dev/null; kill $WD 2>/dev/null
ifsnap load1 >> $OUT/ifsnap.txt
echo "  하네스 건전성: $(cat $OUT/blast.err 2>/dev/null | tr '\n' ' ')"
[ -s $OUT/guard_died.log ] && { echo "  ⚠️ 무감시 구간 발생:"; cat $OUT/guard_died.log; }

echo; echo "=== 11. 회수 ==="
ssh $C 'cat /tmp/wg_c.csv'     > $OUT/sample_c.csv 2>/dev/null
ssh $C 'cat /tmp/wg_blast.csv' > $OUT/sample_blast.csv 2>/dev/null
ssh $R 'cat /tmp/wg_r.csv'     > $OUT/sample_r.csv 2>/dev/null
ssh $S 'cat /tmp/wg_s.csv'     > $OUT/sample_s.csv 2>/dev/null
wc -l $OUT/sample_*.csv
echo "  가드: $(grep -c 초과 $OUT/watchdog.log 2>/dev/null||echo 0) 초과 · $(grep -c 트립 $OUT/watchdog.log 2>/dev/null||echo 0) 트립"
