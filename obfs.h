#pragma once
/*
 * obfs.h — GFW/DPI evasion obfuscation layer
 *
 * Supported disguise modes (--obfs-mode):
 *
 *   QUIC (default)
 *     Priority 1: HMAC auth token (SipHash-2-4, 30s slot)
 *     Priority 2: QUIC Short Header mimicry (first byte 0x40–0x7F)
 *     Priority 3: packet-size bucket normalization
 *
 *   TLS
 *     Priority 1: HMAC auth token (same)
 *     Priority 2: TLS 1.3 Application Data record mimicry
 *                   [0x17][0x03][0x03][len_hi][len_lo] + payload
 *     Priority 3: packet-size bucket normalization (same)
 *
 * Active-probing response (--decoy):
 *   On HMAC auth failure (= external prober), relay the raw packet to the decoy address.
 *   The decoy points to a real HTTPS/QUIC server (e.g. nginx, caddy).
 *
 * Wire format summary:
 *   QUIC: [1B flags:0x40-0x7F][8B token][1B pad_len][payload][padding]
 *   TLS:  [0x17][0x03][0x03][2B length][8B token][1B pad_len][payload][padding]
 */
#include <stdint.h>
#include <stddef.h>

/* ─── Header sizes ──────────────────────────────────────────── */
#define OBFS_HEADER_QUIC   10     /* 1(flags)+8(token)+1(pad_len) */
#define OBFS_HEADER_TLS    14     /* 5(TLS record)+8(token)+1(pad_len) */
#define OBFS_HEADER_SIZE   OBFS_HEADER_QUIC   /* backward compat */

#define OBFS_MAX_PADDING   245
#define OBFS_PSK_LEN       16
#define OBFS_TOKEN_LEN     8
#define OBFS_AUTH_INTERVAL 30     /* auth token slot length (seconds) */

/* Packet type (QUIC mode flags bits [5:4]) */
#define OBFS_TYPE_DATA     0x00
#define OBFS_TYPE_PROBE    0x01
#define OBFS_TYPE_PAD      0x02
#define OBFS_PKT_INITIAL   0x10  /* QUIC Long Header Initial */

/* ─── Disguise modes ────────────────────────────────────────── */
typedef enum {
    OBFS_MODE_QUIC = 0,   /* QUIC Short Header (default) */
    OBFS_MODE_TLS  = 1,   /* TLS Application Data record */
} obfs_mode_t;

/* Bucket size table */
#define OBFS_BUCKET_COUNT  8
extern const int obfs_buckets[OBFS_BUCKET_COUNT];

/* ─── Context ────────────────────────────────────────────────── */
struct obfs_ctx {
    uint8_t     psk[OBFS_PSK_LEN];
    uint32_t    auth_interval;     /* HMAC token slot length (seconds) */
    uint32_t    hop_interval;      /* port-hopping slot length (seconds, 0=disabled) */
    obfs_mode_t mode;         /* OBFS_MODE_QUIC or OBFS_MODE_TLS */
};

/* Header size for the current mode */
static inline int obfs_hdr_size(const struct obfs_ctx *ctx) {
    return (ctx->mode == OBFS_MODE_TLS) ? OBFS_HEADER_TLS : OBFS_HEADER_QUIC;
}

/* ─── QUIC Long Header Initial handshake simulation ──────────── */
/*
 * RFC 9000 §14.1: a ClientInitial must be at least 1200B.
 * If DPI sees "first packet = Long Header Initial", it classifies the flow as QUIC.
 */
#define QUIC_INITIAL_SIZE   1200
#define OBFS_DECODE_INITIAL (-2)  /* obfs_decode return: Client Initial received */

/* ─── API ────────────────────────────────────────────────────── */

/*
 * Init: derive PSK from key_str, set mode
 */
void obfs_init(struct obfs_ctx *ctx, const char *key_str, obfs_mode_t mode);

/*
 * Port hopping: return current slot number (hop_interval==0 → 0)
 */
uint64_t obfs_current_slot(const struct obfs_ctx *ctx);

/*
 * Port hopping: compute port number from slot number (PSK + slot → 1025-65535)
 */
uint16_t obfs_port_for_slot(const struct obfs_ctx *ctx, uint64_t slot);

/*
 * Encode: payload → wire format
 * Returns: bytes written, -1=error
 */
int obfs_encode(const struct obfs_ctx *ctx,
                const void *payload, int payload_len,
                void *out, int out_max,
                uint8_t pkt_type);

/*
 * Decode: wire format → payload  (auto-detects QUIC Long/Short Header, TLS)
 * Returns: payload length
 *         0  = auth failure (silent drop) or Server Initial (ignored)
 *        -1  = format error
 *        -2  = OBFS_DECODE_INITIAL: valid Client Initial received
 *              → mud_lite auto-replies with Server Initial
 */
int obfs_decode(const struct obfs_ctx *ctx,
                const void *in, int in_len,
                void *out, int out_max,
                uint8_t *pkt_type_out);

/*
 * Encode a QUIC Long Header Initial packet (fixed QUIC_INITIAL_SIZE bytes).
 *
 *   is_server == 0: Client Initial  (SCID[0]=0x00)
 *   is_server != 0: Server Initial  (SCID[0]=0xFF, client discards without looping)
 *
 * HMAC token embedded in the DCID (8B) — the receiver verifies it.
 * Returns: QUIC_INITIAL_SIZE, or -1 if out_max is insufficient.
 */
int obfs_encode_initial(const struct obfs_ctx *ctx,
                        void *out, int out_max,
                        int is_server);
