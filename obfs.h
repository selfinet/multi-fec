#pragma once
/*
 * obfs.h — GFW/DPI 우회 난독화 계층
 *
 * 지원하는 위장 모드 (--obfs-mode):
 *
 *   QUIC (default)
 *     Priority 1: HMAC 인증 토큰 (SipHash-2-4, 30초 슬롯)
 *     Priority 2: QUIC Short Header 모방 (첫 바이트 0x40–0x7F)
 *     Priority 3: 패킷 크기 버킷 정규화
 *
 *   TLS
 *     Priority 1: HMAC 인증 토큰 (동일)
 *     Priority 2: TLS 1.3 Application Data 레코드 모방
 *                   [0x17][0x03][0x03][len_hi][len_lo] + payload
 *     Priority 3: 패킷 크기 버킷 정규화 (동일)
 *
 * 액티브 프로빙 대응 (--decoy):
 *   HMAC 인증 실패(=외부 프로버) 시 raw 패킷을 decoy 주소로 중계.
 *   decoy는 실제 HTTPS/QUIC 서버(예: nginx, caddy)를 가리킨다.
 *
 * Wire 포맷 요약:
 *   QUIC: [1B flags:0x40-0x7F][8B token][1B pad_len][payload][padding]
 *   TLS:  [0x17][0x03][0x03][2B length][8B token][1B pad_len][payload][padding]
 */
#include <stdint.h>
#include <stddef.h>

/* ─── 헤더 크기 ─────────────────────────────────────────────── */
#define OBFS_HEADER_QUIC   10     /* 1(flags)+8(token)+1(pad_len) */
#define OBFS_HEADER_TLS    14     /* 5(TLS record)+8(token)+1(pad_len) */
#define OBFS_HEADER_SIZE   OBFS_HEADER_QUIC   /* 하위 호환 */

#define OBFS_MAX_PADDING   245
#define OBFS_PSK_LEN       16
#define OBFS_TOKEN_LEN     8
#define OBFS_AUTH_INTERVAL 30     /* 인증 토큰 슬롯 길이 (초) */

/* 패킷 타입 (QUIC 모드 flags 비트[5:4]) */
#define OBFS_TYPE_DATA     0x00
#define OBFS_TYPE_PROBE    0x01
#define OBFS_TYPE_PAD      0x02
#define OBFS_PKT_INITIAL   0x10  /* QUIC Long Header Initial */

/* ─── 위장 모드 ─────────────────────────────────────────────── */
typedef enum {
    OBFS_MODE_QUIC = 0,   /* QUIC Short Header (default) */
    OBFS_MODE_TLS  = 1,   /* TLS Application Data record */
} obfs_mode_t;

/* 버킷 크기 테이블 */
#define OBFS_BUCKET_COUNT  8
extern const int obfs_buckets[OBFS_BUCKET_COUNT];

/* ─── 컨텍스트 ───────────────────────────────────────────────── */
struct obfs_ctx {
    uint8_t     psk[OBFS_PSK_LEN];
    uint32_t    auth_interval;     /* HMAC 토큰 슬롯 길이 (초) */
    uint32_t    hop_interval;      /* 포트 호핑 슬롯 길이 (초, 0=비활성화) */
    obfs_mode_t mode;         /* OBFS_MODE_QUIC or OBFS_MODE_TLS */
};

/* 현재 모드의 헤더 크기 */
static inline int obfs_hdr_size(const struct obfs_ctx *ctx) {
    return (ctx->mode == OBFS_MODE_TLS) ? OBFS_HEADER_TLS : OBFS_HEADER_QUIC;
}

/* ─── QUIC Long Header Initial 핸드쉐이크 시뮬레이션 ──────────── */
/*
 * RFC 9000 §14.1: ClientInitial은 1200B 이상이어야 한다.
 * DPI가 "첫 패킷 = Long Header Initial" 을 확인하면 QUIC로 분류한다.
 */
#define QUIC_INITIAL_SIZE   1200
#define OBFS_DECODE_INITIAL (-2)  /* obfs_decode 리턴: Client Initial 수신 확인 */

/* ─── API ────────────────────────────────────────────────────── */

/*
 * 초기화: key_str에서 PSK 파생, mode 설정
 */
void obfs_init(struct obfs_ctx *ctx, const char *key_str, obfs_mode_t mode);

/*
 * 포트 호핑: 현재 슬롯 번호 반환 (hop_interval==0 → 0)
 */
uint64_t obfs_current_slot(const struct obfs_ctx *ctx);

/*
 * 포트 호핑: 슬롯 번호에서 포트 번호 계산 (PSK + slot → 1025-65535)
 */
uint16_t obfs_port_for_slot(const struct obfs_ctx *ctx, uint64_t slot);

/*
 * 인코딩: payload → wire 포맷
 * 반환값: 쓴 바이트 수, -1=오류
 */
int obfs_encode(const struct obfs_ctx *ctx,
                const void *payload, int payload_len,
                void *out, int out_max,
                uint8_t pkt_type);

/*
 * 디코딩: wire 포맷 → payload  (QUIC Long/Short Header, TLS 자동 판별)
 * 반환값: payload 길이
 *         0  = 인증 실패(묵음 드롭) 또는 Server Initial(무시)
 *        -1  = 포맷 오류
 *        -2  = OBFS_DECODE_INITIAL: 유효한 Client Initial 수신
 *              → mud_lite가 Server Initial 자동 응답
 */
int obfs_decode(const struct obfs_ctx *ctx,
                const void *in, int in_len,
                void *out, int out_max,
                uint8_t *pkt_type_out);

/*
 * QUIC Long Header Initial 패킷 인코딩 (QUIC_INITIAL_SIZE 바이트 고정).
 *
 *   is_server == 0: Client Initial  (SCID[0]=0x00)
 *   is_server != 0: Server Initial  (SCID[0]=0xFF, 클라이언트가 루프 없이 폐기)
 *
 * HMAC 토큰을 DCID(8B)에 삽입 — 수신측이 검증한다.
 * 반환값: QUIC_INITIAL_SIZE, 또는 out_max 부족 시 -1.
 */
int obfs_encode_initial(const struct obfs_ctx *ctx,
                        void *out, int out_max,
                        int is_server);
