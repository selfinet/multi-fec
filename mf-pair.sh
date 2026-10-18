#!/bin/bash
# mf-pair.sh — multi-fec 1.4.0 고객 키트 생성기 (c·s 한 벌)
#
#   ./mf-pair.sh --name customerA --server 0.0.0.0:443 \
#                --path 198.51.100.20:443 --path 198.51.100.30:443 [--via eth0,eth1] \
#                [--upstream 203.0.113.10:443] [--tunnel 10.9.30] [--wg-port 51820] [--out DIR]
#
#   --server   server 의 listen (예: 0.0.0.0:443 또는 공인IP:443)
#   --path     client 가 보낼 목적지(relay 또는 server). 반복
#   --via      path 순서대로 client 회선 인터페이스(쉼표). 회선을 나눌 때만
#   --upstream relay 를 거칠 때 relay 의 route 줄에 넣을 server 주소(공인IP:포트)
#   --tunnel   WG 터널 /30 의 앞 3옥텟 (server=.1, client=.2) [기본 10.9.30]
#
# 출력 (DIR, 기본 ./mf-kit-<name>, 전부 600):
#   client/client.conf  client/wg-fec.conf
#   server/server.conf  server/wg-fec.conf
#   relay-route.txt      우리 relay 의 routes 파일에 넣을 한 줄
#   CHECKLIST.txt        설치·확인 절차
#
# 키는 화면·명령행에 찍지 않는다(지문 kf: 만). 양쪽이 같아야 하는 값(key, auth-interval)을
# 한 번에 쓰므로 어긋날 수 없다. 배경: DESIGN-1.4.0.md §9-4.
set -euo pipefail
umask 077

NAME= SERVER= UPSTREAM= VIA= TUN=10.9.30 WGPORT=51820 OUT=
PATHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name)     NAME=$2; shift 2 ;;
        --server)   SERVER=$2; shift 2 ;;
        --path)     PATHS+=("$2"); shift 2 ;;
        --via)      VIA=$2; shift 2 ;;
        --upstream) UPSTREAM=$2; shift 2 ;;
        --tunnel)   TUN=$2; shift 2 ;;
        --wg-port)  WGPORT=$2; shift 2 ;;
        --out)      OUT=$2; shift 2 ;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
    esac
done
[ -n "$NAME" ] && [ -n "$SERVER" ] && [ ${#PATHS[@]} -gt 0 ] || { sed -n '2,22p' "$0" >&2; exit 1; }
command -v wg >/dev/null || { echo "wg(wireguard-tools)가 필요하다" >&2; exit 1; }

BIN=${MF_BIN:-}
for c in ./multi-fec-dist ./multi-fec /usr/sbin/multi-fec-dist; do
    [ -z "$BIN" ] && [ -x "$c" ] && BIN=$c
done
[ -n "$BIN" ] || { echo "multi-fec 바이너리를 못 찾았다 — MF_BIN=/경로" >&2; exit 1; }
"$BIN" --version | grep -q '^multi-fec 1\.[4-9]' || { echo "$BIN 은 1.4.0 이상이 아니다 (--config 필요)" >&2; exit 1; }

IFS=, read -r -a VIAS <<< "${VIA}"
OUT=${OUT:-./mf-kit-$NAME}
[ -e "$OUT" ] && { echo "$OUT 이 이미 있다 — 덮어쓰지 않는다" >&2; exit 1; }
mkdir -p "$OUT/client" "$OUT/server"

# PSK: mf-newkey.sh 와 같은 규칙(32바이트 hex — 공백·특수문자 없음)
KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
CPRIV=$(wg genkey); CPUB=$(printf '%s' "$CPRIV" | wg pubkey)
SPRIV=$(wg genkey); SPUB=$(printf '%s' "$SPRIV" | wg pubkey)

{
    echo "# multi-fec client — $NAME ($(date +%F))"
    echo "mode          = client"
    for i in "${!PATHS[@]}"; do
        v=${VIAS[$i]:-}
        echo "path          = ${PATHS[$i]}${v:+ via $v}"
    done
    echo "key           = $KEY"
    echo "auth-interval = 60"
} > "$OUT/client/client.conf"

{
    echo "# multi-fec server — $NAME ($(date +%F))"
    echo "mode          = server"
    echo "listen        = $SERVER"
    echo "wg            = 127.0.0.1:$WGPORT"
    echo "key           = $KEY"
    echo "auth-interval = 60"
} > "$OUT/server/server.conf"

cat > "$OUT/client/wg-fec.conf" <<EOF
[Interface]
PrivateKey = $CPRIV
Address    = $TUN.2/32
MTU        = 1300

[Peer]
PublicKey  = $SPUB
Endpoint   = 127.0.0.1:51821
AllowedIPs = $TUN.1/32
PersistentKeepalive = 25
EOF

cat > "$OUT/server/wg-fec.conf" <<EOF
[Interface]
PrivateKey = $SPRIV
Address    = $TUN.1/32
ListenPort = $WGPORT
MTU        = 1300

[Peer]
PublicKey  = $CPUB
AllowedIPs = $TUN.2/32
EOF

# 지문: 키를 명령행에 올리지 않고 --check 로 계산한다
# (--check 는 이 호스트에 없는 인터페이스·쓰는 포트를 오류로 보고하고 exit 1 이다 — 지문만 필요하므로 종료 코드는 보지 않는다)
FP=$( { "$BIN" --config "$OUT/client/client.conf" --check 2>/dev/null || true; } | grep -oE 'kf:[0-9a-f]{8}' | head -1)
[ -n "$FP" ] || { echo "지문 계산 실패" >&2; exit 1; }

if [ -n "$UPSTREAM" ]; then
    printf '# %s %s\n%s  %s\n' "$NAME" "$FP" "$KEY" "$UPSTREAM" > "$OUT/relay-route.txt"
fi

cat > "$OUT/CHECKLIST.txt" <<EOF
multi-fec 키트: $NAME   키 지문 $FP   ($(date +%F))

[server]
  install -m 600 server.conf  /etc/multi-fec/server.conf
  install -m 600 wg-fec.conf  /etc/wireguard/wg-fec.conf
  systemctl enable --now multi-fec@server wg-quick@wg-fec
  multi-fec-dist --config /etc/multi-fec/server.conf --check     # 0 error(s)

[client]
  install -m 600 client.conf  /etc/multi-fec/client.conf
  install -m 600 wg-fec.conf  /etc/wireguard/wg-fec.conf
  multi-fec-dist --config /etc/multi-fec/client.conf --check     # 0 error(s)
  systemctl enable --now multi-fec@client wg-quick@wg-fec

[공통 전제]
  - 시간 동기(chrony 또는 systemd-timesyncd) 필수 — 30초 넘게 틀어지면 무음 폐기
  - /etc/systemd/system/multi-fec@.service (리포 systemd/) 설치 후 systemctl daemon-reload
$( [ -n "$UPSTREAM" ] && echo "  - 우리 relay 의 routes 파일에 relay-route.txt 한 줄 추가 후 재시작 (지문 $FP)" )

[확인]
  ping $TUN.1                                  # client 에서
  journalctl -u multi-fec@client | grep -E 'key kf|path\\['   # 지문 $FP, 경로 RUNNING
  회선 2개(via)면: 경로별 dev= 가 서로 달라야 한다 (--check 의 "leaves dev")
EOF

echo "생성: $OUT  (키 지문 $FP)"
ls -l "$OUT" "$OUT/client" "$OUT/server"
