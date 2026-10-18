#!/bin/bash
# x140_2stage.sh — 2단 --route 다중 키 1.3.1↔1.4.0 혼용(시험 2) + 교체·롤백 리허설(시험 4) (2026-10-18, 테스트망 전용)
#
# 왜: 1.4.0 은 1.3.1 과 1단 4조합(ping)만 쟀다. 서비스망은 지사 → 1단 → 2단 → 서버, 양 단 모두 --route 이고
#     relay 마다 키가 여러 개다. relay 의 --route 파서를 1.4.0 에서 새로 썼으므로 그 구조로 섞어 본다(시험 2).
#     이어서 서비스에 올릴 순서 그대로 홉을 하나씩 바꾸고 되돌리며 단절을 잰다(시험 4).
#
# 구성 (§15 와 같게 r VM 안에 2단 — 새 VM 을 만들지 않는다는 방침):
#   path[0] c → 1단 .88:443  (multi-fec-relay,   /opt/mfx/1a) → 2단 .88:4443  (mfx-r2a, /opt/mfx/2a) ─┐
#   path[1] c → 1단 .117:443 (multi-fec-relay-b, /opt/mfx/1b) → 2단 .117:4443 (mfx-r2b, /opt/mfx/2b) ─┴→ s .102:443
#   홉마다 바이너리 경로를 따로 둬서 경로 단위로 바꿀 수 있게 했다.
#   모든 relay: --route 4개 — 가짜 키 3개(쓰지 않는 upstream) 뒤에 실제 키. 탐색이 앞 키들을 거쳐야 맞는다.
#   전부 --sock-buf 4096 · --auth-interval ${AUTH_INTERVAL}(60) — 서비스 relay 유닛과 같은 형태. sysctl 기본.
# 부하: 시험 2 = 조합당 5 Mbps × 120초(§15 와 같음 — 2단을 한 VM 에 올리면 10 Mbps 이상은 r CPU 로 트립),
#       시험 4 = 3 Mbps 지속 + ping 20 pps, 45초 간격으로 교체 12회.
# 가드는 run_load.sh 가 먼저 띄운다(GW_NET=new). 끝나면(실패 포함) 무조건 원상 복구.
set -u
cd "$(dirname "$0")"
VG=../2026-10-05-vm-guard-calib
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=raw/x140; mkdir -p "$OUT"
SUM=$OUT/summary.txt

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'pkill -INT -x ping; exit 0'
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

echo "[$(date +%T)] sv1 운영(시작 전): $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
for h in $C $R $S; do ssh "$h" 'sysctl -qw net.core.rmem_max=212992 net.core.wmem_max=212992 net.core.rmem_default=212992 net.core.wmem_default=212992'; done

# ── 2단 구성
DUMMY='--route "dummyA-0000 192.168.100.102:4991" --route "dummyB-1111 192.168.100.102:4992" --route "dummyC-2222 192.168.100.102:4993"'
ssh "$R" 'mkdir -p /opt/mfx/1a /opt/mfx/1b /opt/mfx/2a /opt/mfx/2b; for d in 1a 1b 2a 2b; do install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /opt/mfx/$d/multi-fec-dist; done'
for p in "multi-fec-relay 1a 192.168.100.88" "multi-fec-relay-b 1b 192.168.100.117"; do set -- $p
  ssh "$R" "mkdir -p /etc/systemd/system/$1.service.d && cat > /etc/systemd/system/$1.service.d/x140.conf" <<EOF
# 2026-10-18 x140_2stage.sh 임시 drop-in (끝나면 제거)
[Service]
ExecStart=
ExecStart=/opt/mfx/$2/multi-fec-dist -r -l \${LISTEN} $DUMMY --route "\${KEY} $3:4443" --upstream-local \${UPSTREAM_LOCAL} --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf 4096
EOF
done
for p in "a relay.conf 192.168.100.88" "b relay-b.conf 192.168.100.117"; do set -- $p
  ssh "$R" "cat > /etc/systemd/system/mfx-r2$1.service" <<EOF
[Unit]
Description=x140 임시 2단 릴레이 $1 (2026-10-18, 끝나면 제거)
[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/$2
ExecStart=/opt/mfx/2$1/multi-fec-dist -r -l $3:4443 $DUMMY --route "\${KEY} 192.168.100.102:443" --upstream-local $3 --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf 4096
TimeoutStopSec=3
EOF
done
ssh "$R" 'systemctl daemon-reload && systemctl start mfx-r2a mfx-r2b && systemctl restart multi-fec-relay multi-fec-relay-b'

# 홉별 버전 설정: setv <c> <1a> <1b> <2a> <2b> <s>   (예: 1.3.1 1.4.0 …)
setv() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$6 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$4 /opt/mfx/2a/multi-fec-dist && install -m 755 /usr/sbin/multi-fec-dist.v$5 /opt/mfx/2b/multi-fec-dist && systemctl restart mfx-r2a mfx-r2b"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$2 /opt/mfx/1a/multi-fec-dist && install -m 755 /usr/sbin/multi-fec-dist.v$3 /opt/mfx/1b/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client"
}
snap() { for p in "c $C" "r $R" "s $S"; do set -- $p
  echo "$1 $(ssh "$2" 'nstat -az UdpRcvbufErrors | tail -1' | awk '{print $2}')"; done; }
logs() {  # <dir> <since-epoch>
  for p in "c $C multi-fec-client" "r1 $R multi-fec-relay -u multi-fec-relay-b" "r2 $R mfx-r2a -u mfx-r2b" "s $S multi-fec-server"; do
    set -- $p; n=$1; h=$2; shift 2
    ssh "$h" "journalctl -u $* --since @$T0 --no-pager -o cat" | sed 's/\x1b\[[0-9;]*m//g' > "$D/log_$n.txt" 2>&1
  done; }

# ═══ 시험 2: 혼용 7조합 (이름:c:1단:2단:s) — 교체 순서 s → 2단 → 1단 → c
v() { [ "$1" = 140 ] && echo 1.4.0 || echo 1.3.1; }
echo "# $(date '+%F %T') 시험 2  5 Mbps × 120s" >> "$SUM"
for combo in Z0:131:131:131:131 Z1:131:131:131:140 Z2:131:131:140:140 Z3:131:140:140:140 Z4:140:140:140:140 Z5:140:131:140:131 Z6:131:140:131:131; do
  IFS=: read -r X VC V1 V2 VS <<< "$combo"
  D=$OUT/$X; mkdir -p "$D"; T0=$(date +%s)
  echo "[$(date +%T)] ===== $X  c=$(v $VC) 1단=$(v $V1) 2단=$(v $V2) s=$(v $VS)"
  setv $(v $VC) $(v $V1) $(v $V1) $(v $V2) $(v $V2) $(v $VS)
  ok=0
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' > "$D/ping.txt" 2>&1 && { ok=1; break; }; sleep 5; done
  ssh "$R" 'ss -uanp | grep multi-fec' > "$D/ss_r.txt" 2>&1
  n1=$(awk '$5 ~ /:4443$/' "$D/ss_r.txt" | wc -l)
  n2=$(awk '$5 ~ /^192\.168\.100\.102:443$/' "$D/ss_r.txt" | wc -l)
  nd=$(awk '$5 ~ /:499[123]$/' "$D/ss_r.txt" | wc -l)
  if [ $ok -ne 1 ] || [ "$n1" -lt 2 ] || [ "$n2" -lt 2 ]; then
    echo "[$(date +%T)] $X FAIL: ping=$ok 1단→2단=$n1 2단→서버=$n2"
    echo "$X FAIL ping=$ok hop1=$n1 hop2=$n2" >> "$SUM"
  else
    snap > "$D/nstat_before.txt"
    ( cd $VG && RUNID=x140_$X STEPS=5 DUR=120 ./run_load.sh ) > "$D/run.out" 2>&1; rc=$?
    snap > "$D/nstat_after.txt"
    res=$(grep -E '^\[run\] +[0-9]+ Mbps' "$D/run.out" | awk '{printf "%s:up%s/dn%s ", $2, $5, $9}')
    drops=$(paste "$D/nstat_before.txt" "$D/nstat_after.txt" | awk '{printf "%s+%d ", $1, $4-$2}')
    echo "[$(date +%T)] $X rc=$rc hop1=$n1 hop2=$n2 dummy-upstream=$nd  $res drop $drops"
    echo "$X c=$VC r1=$V1 r2=$V2 s=$VS rc=$rc hop1=$n1 hop2=$n2 dummy=$nd $res drop $drops" >> "$SUM"
  fi
  logs
  echo "  warn/err(재시작·EAGAIN 제외) c=$(grep -E 'WARN|ERROR|FATAL' $D/log_c.txt | grep -vcE 'EAGAIN|signal|exiting') r1=$(grep -E 'WARN|ERROR|FATAL' $D/log_r1.txt | grep -vcE 'signal|exiting') r2=$(grep -E 'WARN|ERROR|FATAL' $D/log_r2.txt | grep -vcE 'signal|exiting') s=$(grep -E 'WARN|ERROR|FATAL' $D/log_s.txt | grep -vcE 'signal|exiting')" \
       " routes(1.4.0 relay 기동줄): $(grep -c 'route\[' $D/log_r1.txt)/$(grep -c 'route\[' $D/log_r2.txt)" \
       " path: $(grep -oE 'path\[[01]\] [A-Z]+' $D/log_c.txt | sort | uniq -c | tr -s ' ' | tr '\n' ';')" | tee -a "$SUM"
  if grep -qE '트립|소멸|기동 실패' "$D/run.out" 2>/dev/null; then echo "[$(date +%T)] 가드 트립/실패 — 중단"; echo "$X GUARD STOP" >> "$SUM"; exit 4; fi
done

# ═══ 시험 4: 교체·롤백 리허설 — 3 Mbps 지속 + ping 20 pps, 45초 간격
echo "[$(date +%T)] ##### 시험 4 리허설 (전 홉 1.3.1 에서 시작)"
D=$OUT/rehearsal; mkdir -p "$D"; T0=$(date +%s)
setv 1.3.1 1.3.1 1.3.1 1.3.1 1.3.1 1.3.1
for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
sleep 20
: > "$D/events.txt"
ssh "$C" "ping -D -i 0.05 -W 1 -w 700 10.9.20.1" > "$D/ping_load.txt" 2>&1 & PP=$!
( cd $VG && RUNID=x140_rehearsal STEPS=3 DUR=640 ./run_load.sh ) > "$D/run.out" 2>&1 & LP=$!
sleep 40
ev() {  # <label> <host> <install-target> <version> <unit...>
  local l=$1 h=$2 t=$3 ver=$4; shift 4
  echo "$(date +%s.%N) $l" >> "$D/events.txt"; echo "[$(date +%T)] $l"
  ssh "$h" "install -m 755 /usr/sbin/multi-fec-dist.v$ver $t && systemctl restart $*"
  sleep 45
}
ev "U1 s→1.4.0"          "$S" /usr/sbin/multi-fec-dist   1.4.0 multi-fec-server
ev "U2 경로0 2단→1.4.0"   "$R" /opt/mfx/2a/multi-fec-dist 1.4.0 mfx-r2a
ev "U3 경로0 1단→1.4.0"   "$R" /opt/mfx/1a/multi-fec-dist 1.4.0 multi-fec-relay
ev "U4 경로1 2단→1.4.0"   "$R" /opt/mfx/2b/multi-fec-dist 1.4.0 mfx-r2b
ev "U5 경로1 1단→1.4.0"   "$R" /opt/mfx/1b/multi-fec-dist 1.4.0 multi-fec-relay-b
ev "U6 c→1.4.0"          "$C" /usr/sbin/multi-fec-dist   1.4.0 multi-fec-client
ev "B1 c→1.3.1"          "$C" /usr/sbin/multi-fec-dist   1.3.1 multi-fec-client
ev "B2 경로1 1단→1.3.1"   "$R" /opt/mfx/1b/multi-fec-dist 1.3.1 multi-fec-relay-b
ev "B3 경로1 2단→1.3.1"   "$R" /opt/mfx/2b/multi-fec-dist 1.3.1 mfx-r2b
ev "B4 경로0 1단→1.3.1"   "$R" /opt/mfx/1a/multi-fec-dist 1.3.1 multi-fec-relay
ev "B5 경로0 2단→1.3.1"   "$R" /opt/mfx/2a/multi-fec-dist 1.3.1 mfx-r2a
ev "B6 s→1.3.1"          "$S" /usr/sbin/multi-fec-dist   1.3.1 multi-fec-server
echo "$(date +%s.%N) END" >> "$D/events.txt"
wait $LP
ssh "$C" 'pkill -INT -x ping; exit 0'; wait $PP 2>/dev/null
logs
grep -E '^\[run\]' "$D/run.out" | tail -3
python3 - "$D" <<'PY' | tee "$D/gaps.txt" | tee -a "$SUM"
import re, sys
d = sys.argv[1]
L = re.compile(r'^\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms')
pl = [(float(m[1]), int(m[2]), float(m[3])) for l in open(d + '/ping_load.txt', errors='replace') if (m := L.match(l))]
ev = [(float(a), b.strip()) for a, b in (l.split(' ', 1) for l in open(d + '/events.txt'))]
t0, s0 = pl[0][0], pl[0][1]
sent = lambda s: t0 + (s - s0) * 0.05          # 송신 시각 ≈ 시작 + seq × 50 ms
got = {s: (t, r) for t, s, r in pl}
print('event                     window  lost  최장공백  >200ms  maxRTT')
for i, (te, lab) in enumerate(ev[:-1]):
    tn = ev[i + 1][0]
    seqs = [s for s in range(s0, max(got) + 1) if te <= sent(s) < tn]
    lost = [s for s in seqs if s not in got]
    run = best = 0
    for s in seqs:
        run = run + 1 if s not in got else 0
        best = max(best, run)
    slow = sum(1 for s in seqs if s in got and got[s][1] > 200)
    mx = max([got[s][1] for s in seqs if s in got] or [0])
    print(f'{lab:24s} {tn-te:5.0f}s {len(lost):5d}  {best*50:6d}ms  {slow:6d}  {mx:6.0f}')
PY
echo "[$(date +%T)] 측정 완료"
