#!/bin/bash
# mf-newkey.sh — multi-fec PSK 생성기
#
#   ./mf-newkey.sh          키 1개 생성 (키 + 지문)
#   ./mf-newkey.sh 5        키 5개 생성
#   ./mf-newkey.sh fp KEY   기존 키의 지문만 계산 (홉 간 대조용)
#
# 지문(kf:)은 multi-fec 바이너리로 계산한다 — 재구현하면 언젠가 코드와 갈라진다.
# bind 를 일부러 실패시켜(192.0.2.1 = RFC 5737 문서용 주소) 소켓을 남기지 않고 즉시 끝낸다.
# 바이너리 위치는 MF_BIN 으로 지정할 수 있다.
set -u

find_bin() {
    [ -n "${MF_BIN:-}" ] && { echo "$MF_BIN"; return 0; }
    for c in ./multi-fec ./multi-fec-dist /usr/sbin/multi-fec-dist /usr/local/bin/multi-fec; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    command -v multi-fec-dist 2>/dev/null && return 0
    return 1
}

# 키는 --route 파서(sscanf "%999s %255s") · systemd · 셸을 차례로 지나간다.
# 공백이 있으면 키가 잘리고, $ % # " ' \ ` 는 어느 한 단계에서 해석될 수 있다.
validate() {
    case "$1" in
        ''|*[[:space:]]*)                       return 1 ;;
        *'$'*|*'%'*|*'#'*|*'"'*|*"'"*|*'\'*|*'`'*) return 1 ;;
    esac
    [ ${#1} -le 999 ]
}

fingerprint() {
    timeout 3 "$BIN" -r -l 192.0.2.1:443 --route "$1 192.0.2.2:443" 2>&1 \
        | grep -oE 'kf:[0-9a-f]{8}' | head -1
}

BIN=$(find_bin) || { echo "multi-fec 바이너리를 못 찾았다 — MF_BIN=/경로 로 지정" >&2; exit 1; }

if [ "${1:-}" = "fp" ]; then
    [ $# -ge 2 ] || { echo "사용법: $0 fp KEY" >&2; exit 1; }
    validate "$2" || { echo "키에 공백 또는 특수문자($ % # \" ' \\ \`)가 있다" >&2; exit 1; }
    fingerprint "$2"
    exit 0
fi

N=${1:-1}
case "$N" in ''|*[!0-9]*) echo "사용법: $0 [개수] | $0 fp KEY" >&2; exit 1 ;; esac

i=0
while [ "$i" -lt "$N" ]; do
    # 32바이트. derive_psk() 가 어차피 128비트로 압축하므로 더 길게 할 이유가 없다.
    if command -v openssl >/dev/null 2>&1; then k=$(openssl rand -hex 32)
    else k=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'); fi
    validate "$k" || continue
    fp=$(fingerprint "$k")
    [ -n "$fp" ] || { echo "지문 계산 실패 — 바이너리 확인 ($BIN)" >&2; exit 1; }
    printf '%s  %s\n' "$k" "$fp"
    i=$((i + 1))
done
