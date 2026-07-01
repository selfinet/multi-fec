/*
 * obfs.cpp — GFW/DPI evasion obfuscation layer implementation
 */
#include "obfs.h"
#include "siphash.h"
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>

const int obfs_buckets[OBFS_BUCKET_COUNT] = {300, 500, 700, 900, 1100, 1300, 1400, 1500};

/* ─── PSK derivation ───────────────────────────────────────────── */

static void
derive_psk(uint8_t psk[OBFS_PSK_LEN], const char *key_str)
{
    static const uint8_t deriv_key[16] = {
        0x6d, 0x75, 0x6c, 0x74, 0x69, 0x2d, 0x66, 0x65,
        0x63, 0x2d, 0x70, 0x73, 0x6b, 0x2d, 0x76, 0x31
    };
    size_t klen = strlen(key_str);
    uint64_t h0 = siphash24((const uint8_t *)key_str, klen, deriv_key);
    uint8_t buf[512];
    if (klen >= sizeof(buf) - 1) klen = sizeof(buf) - 2;
    memcpy(buf, key_str, klen);
    buf[klen] = 0x01;
    uint64_t h1 = siphash24(buf, klen + 1, deriv_key);
    memcpy(psk,     &h0, 8);
    memcpy(psk + 8, &h1, 8);
}

void
obfs_init(struct obfs_ctx *ctx, const char *key_str, obfs_mode_t mode)
{
    memset(ctx, 0, sizeof(*ctx));
    derive_psk(ctx->psk, key_str ? key_str : "");
    ctx->auth_interval = OBFS_AUTH_INTERVAL;
    ctx->mode          = mode;
}

/* ─── Auth token ───────────────────────────────────────────────── */

static uint64_t
current_slot(const struct obfs_ctx *ctx)
{
    return (uint64_t)time(NULL) / ctx->auth_interval;
}

static void
make_token(const struct obfs_ctx *ctx, uint64_t slot, uint8_t token[8])
{
    uint64_t h = siphash24((const uint8_t *)&slot, sizeof(slot), ctx->psk);
    memcpy(token, &h, 8);
}

static int
verify_token(const struct obfs_ctx *ctx, const uint8_t token[8])
{
    uint64_t slot = current_slot(ctx);
    uint8_t expected[8];

    make_token(ctx, slot, expected);
    if (memcmp(token, expected, 8) == 0) return 1;

    if (slot > 0) {
        make_token(ctx, slot - 1, expected);
        if (memcmp(token, expected, 8) == 0) return 1;
    }
    make_token(ctx, slot + 1, expected);
    if (memcmp(token, expected, 8) == 0) return 1;

    return 0;
}

/* ─── Padding size selection ───────────────────────────────────── */

static int
obfs_bucket_for(int total_needed)
{
    for (int i = 0; i < OBFS_BUCKET_COUNT; i++) {
        if (obfs_buckets[i] >= total_needed)
            return obfs_buckets[i];
    }
    /* If it exceeds the largest bucket (1500B), return the top bucket.
     * pad_len = bucket - total_needed < 0 → clamped to 0, so it is sent without padding. */
    return obfs_buckets[OBFS_BUCKET_COUNT - 1];
}

static uint64_t prng_state = UINT64_C(0xdeadbeefcafebabe);
static void fill_random(void *buf, int len)
{
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        prng_state ^= prng_state << 13;
        prng_state ^= prng_state >> 7;
        prng_state ^= prng_state << 17;
        int chunk = (len < 8) ? len : 8;
        memcpy(p, &prng_state, (size_t)chunk);
        p   += chunk;
        len -= chunk;
    }
}

/* ─── QUIC Long Header Initial ─────────────────────────────────── */
/*
 * RFC 9000 §17.2.2 Initial packet layout (QUIC_INITIAL_SIZE = 1200B fixed):
 *
 *   p[ 0]      0xC1   LongHeader|Fixed|Initial|Reserved|PN_LEN=2
 *   p[ 1- 4]   0x00000001   QUIC version 1
 *   p[ 5]      0x08   DCID length = 8
 *   p[ 6-13]   HMAC token   for receiver HMAC auth (based on current_slot)
 *   p[14]      0x08   SCID length = 8
 *   p[15-22]   random  (p[15]=0x00 Client Initial, 0xFF Server Initial)
 *   p[23]      0x00   Token length = 0
 *   p[24-25]   0x44 0x96   pkt_len varint = 1174 (PN 2B + PADDING 1172B)
 *   p[26-27]   0x00 0x00   Packet Number
 *   p[28-1199] 0x00        PADDING frames
 *
 * SCID[0] direction marker:
 *   0x00 → Client Initial  → server replies with Server Initial
 *   0xFF → Server Initial  → client silently discards (loop prevention)
 */
int
obfs_encode_initial(const struct obfs_ctx *ctx,
                    void *out, int out_max,
                    int is_server)
{
    if (out_max < QUIC_INITIAL_SIZE) return -1;

    uint8_t *p = (uint8_t *)out;
    memset(p, 0, QUIC_INITIAL_SIZE);

    uint64_t slot = current_slot(ctx);
    uint8_t  token[8];
    make_token(ctx, slot, token);

    p[0] = 0xC1;                              /* LH|Fixed|Initial|PN_LEN=2 */
    p[1] = 0x00; p[2] = 0x00;
    p[3] = 0x00; p[4] = 0x01;                /* QUIC v1 */
    p[5] = 0x08;                              /* DCID length = 8 */
    memcpy(p + 6, token, 8);                  /* DCID = HMAC token */
    p[14] = 0x08;                             /* SCID length = 8 */
    fill_random(p + 15, 8);                   /* SCID = random */
    p[15] = (uint8_t)(is_server ? 0xFF : 0x00); /* direction marker */
    p[23] = 0x00;                             /* Token length = 0 */
    /* pkt_len = 1174: PN(2B) + PADDING(1172B).
     * QUIC 2-byte varint: 0x40|(1174>>8)=0x44, 1174&0xFF=0x96 */
    p[24] = 0x44;
    p[25] = 0x96;
    /* p[26..27] = PN = 0x0000  (already zeroed) */
    /* p[28..1199] = PADDING    (already zeroed) */

    return QUIC_INITIAL_SIZE;
}

/* ─── QUIC Long Header Initial decoding ────────────────────────── */

static int
decode_initial(const struct obfs_ctx *ctx,
               const uint8_t *p, int in_len,
               void *out, int out_max, uint8_t *pkt_type_out)
{
    (void)out; (void)out_max;

    /* Minimum header: flags(1)+ver(4)+dcid_len(1)+dcid(8)+scid_len(1)+scid(8)
     *              +token_len(1)+pkt_len_varint(2) = 26B */
    if (in_len < 26) return -1;

    /* QUIC version 1 */
    if (p[1] != 0x00 || p[2] != 0x00 || p[3] != 0x00 || p[4] != 0x01) return -1;

    /* DCID length = 8 (our format) */
    if (p[5] != 0x08) return -1;

    /* Verify DCID = HMAC token */
    if (!verify_token(ctx, p + 6)) return 0; /* auth failure → silent drop */

    if (pkt_type_out) *pkt_type_out = OBFS_PKT_INITIAL;

    /* SCID[0]=0xFF → Server Initial → client side silently discards (loop prevention) */
    if (p[14] == 0x08 && p[15] == 0xFF) return 0;

    /* Client Initial → server must respond */
    return OBFS_DECODE_INITIAL;
}

/* ─── QUIC encoding ──────────────────────────────────────────────── */
/*
 * Wire format:
 *   [1B flags:0x40-0x7F][8B token][1B pad_len][payload...][padding...]
 */
static int
encode_quic(const struct obfs_ctx *ctx,
            const void *payload, int payload_len,
            void *out, int out_max, uint8_t pkt_type)
{
    uint64_t slot = current_slot(ctx);
    uint8_t  token[8];
    make_token(ctx, slot, token);

    int raw_total = OBFS_HEADER_QUIC + payload_len;
    int bucket    = obfs_bucket_for(raw_total);
    int pad_len   = bucket - raw_total;
    if (pad_len < 0)                pad_len = 0;
    if (pad_len > OBFS_MAX_PADDING) pad_len = OBFS_MAX_PADDING;

    int wire_len = OBFS_HEADER_QUIC + payload_len + pad_len;
    if (wire_len > out_max) return -1;

    uint8_t *p = (uint8_t *)out;
    p[0] = (uint8_t)(0x40 | (token[0] & 0x3F) | ((pkt_type & 0x03) << 4));
    memcpy(p + 1, token + 1, 7);
    p[8] = token[0];
    p[9] = (uint8_t)pad_len;
    memcpy(p + OBFS_HEADER_QUIC, payload, (size_t)payload_len);
    if (pad_len > 0)
        fill_random(p + OBFS_HEADER_QUIC + payload_len, pad_len);
    return wire_len;
}

/* ─── TLS encoding ───────────────────────────────────────────────── */
/*
 * TLS Application Data record format (RFC 8446 §5.1):
 *
 *   [0x17]        content_type = Application Data
 *   [0x03][0x03]  legacy_record_version = TLS 1.2
 *   [hi][lo]      length = (8 + 1 + payload_len + pad_len)
 *   [8B token]    HMAC auth token
 *   [1B pad_len]  padding length
 *   [payload...]
 *   [padding...]  high-entropy random (to look like real ciphertext)
 *
 * DPI perspective:
 *   - first 3 bytes: 0x17 0x03 0x03  → exact match for TLS 1.3 Application Data
 *   - length field matches the actual packet size
 *   - high-entropy payload (HMAC + random padding) → seen as encrypted content
 *   - bucket normalization makes the packet-size distribution resemble HTTPS traffic
 */
static int
encode_tls(const struct obfs_ctx *ctx,
           const void *payload, int payload_len,
           void *out, int out_max, uint8_t /*pkt_type*/)
{
    uint64_t slot = current_slot(ctx);
    uint8_t  token[8];
    make_token(ctx, slot, token);

    int raw_total = OBFS_HEADER_TLS + payload_len;
    int bucket    = obfs_bucket_for(raw_total);
    int pad_len   = bucket - raw_total;
    if (pad_len < 0)                pad_len = 0;
    if (pad_len > OBFS_MAX_PADDING) pad_len = OBFS_MAX_PADDING;

    int wire_len = OBFS_HEADER_TLS + payload_len + pad_len;
    if (wire_len > out_max) return -1;

    /* TLS record body length: token(8) + pad_len_byte(1) + payload + padding */
    int record_body = 8 + 1 + payload_len + pad_len;
    if (record_body > 0x3FFF) return -1;  /* TLS max record ~16KB */

    uint8_t *p = (uint8_t *)out;
    p[0] = 0x17;                                /* Application Data */
    p[1] = 0x03;                                /* TLS 1.2/1.3 */
    p[2] = 0x03;
    p[3] = (uint8_t)((record_body >> 8) & 0xFF);
    p[4] = (uint8_t)(record_body & 0xFF);
    memcpy(p + 5, token, 8);                    /* auth token */
    p[13] = (uint8_t)pad_len;                   /* padding length */
    memcpy(p + OBFS_HEADER_TLS, payload, (size_t)payload_len);
    if (pad_len > 0)
        fill_random(p + OBFS_HEADER_TLS + payload_len, pad_len);
    return wire_len;
}

/* ─── Unified encoding ───────────────────────────────────────────── */

int
obfs_encode(const struct obfs_ctx *ctx,
            const void *payload, int payload_len,
            void *out, int out_max,
            uint8_t pkt_type)
{
    if (payload_len < 0 || payload_len > 65535) return -1;

    if (ctx->mode == OBFS_MODE_TLS)
        return encode_tls(ctx, payload, payload_len, out, out_max, pkt_type);
    else
        return encode_quic(ctx, payload, payload_len, out, out_max, pkt_type);
}

/* ─── QUIC decoding ──────────────────────────────────────────────── */

static int
decode_quic(const struct obfs_ctx *ctx,
            const uint8_t *p, int in_len,
            void *out, int out_max, uint8_t *pkt_type_out)
{
    if (in_len < OBFS_HEADER_QUIC) return -1;

    uint8_t token[8];
    token[0] = p[8];
    memcpy(token + 1, p + 1, 7);

    if (!verify_token(ctx, token)) return 0;  /* auth failure → silent drop */

    uint8_t pad_len     = p[9];
    int     payload_len = in_len - OBFS_HEADER_QUIC - (int)pad_len;
    if (payload_len < 0 || payload_len > out_max) return -1;

    if (pkt_type_out) *pkt_type_out = (uint8_t)((p[0] >> 4) & 0x03);
    memcpy(out, p + OBFS_HEADER_QUIC, (size_t)payload_len);
    return payload_len;
}

/* ─── TLS decoding ───────────────────────────────────────────────── */

static int
decode_tls(const struct obfs_ctx *ctx,
           const uint8_t *p, int in_len,
           void *out, int out_max, uint8_t *pkt_type_out)
{
    if (in_len < OBFS_HEADER_TLS) return -1;

    /* Validate TLS record header */
    if (p[0] != 0x17 || p[1] != 0x03 || p[2] != 0x03) return -1;

    int claimed_body = ((int)p[3] << 8) | p[4];
    if (claimed_body != in_len - 5) return -1;  /* length mismatch */
    if (claimed_body < 9) return -1;            /* token(8) + pad_len(1) minimum */

    /* Verify auth token */
    const uint8_t *token = p + 5;
    if (!verify_token(ctx, token)) return 0;    /* auth failure → silent drop */

    uint8_t pad_len     = p[13];
    int     payload_len = in_len - OBFS_HEADER_TLS - (int)pad_len;
    if (payload_len < 0 || payload_len > out_max) return -1;

    if (pkt_type_out) *pkt_type_out = OBFS_TYPE_DATA;
    memcpy(out, p + OBFS_HEADER_TLS, (size_t)payload_len);
    return payload_len;
}

/* ─── Port-hopping slot/port calculation ───────────────────────── */

uint64_t
obfs_current_slot(const struct obfs_ctx *ctx)
{
    if (!ctx->hop_interval) return 0;
    return (uint64_t)time(NULL) / ctx->hop_interval;
}

uint16_t
obfs_port_for_slot(const struct obfs_ctx *ctx, uint64_t slot)
{
    uint64_t h = siphash24((const uint8_t *)&slot, sizeof(slot), ctx->psk);
    /* Map to 1025-65535 range (excludes below well-known ports) */
    return (uint16_t)(1025 + (h % (65535 - 1024)));
}

/* ─── Unified decoding (auto-detect QUIC/TLS) ─────────────────────── */
/*
 * Detect mode from the first byte:
 *   0x40–0x7F → QUIC Short Header
 *   0x17      → TLS Application Data
 *
 * Handled automatically even if the two endpoints use different modes,
 * so a simultaneous restart of both sides is not required on upgrade.
 */
int
obfs_decode(const struct obfs_ctx *ctx,
            const void *in, int in_len,
            void *out, int out_max,
            uint8_t *pkt_type_out)
{
    if (in_len < 1) return -1;
    const uint8_t *p = (const uint8_t *)in;

    /* QUIC Long Header (top 2 bits = 11): Initial/0-RTT/Handshake/Retry */
    if ((p[0] & 0xC0) == 0xC0)
        return decode_initial(ctx, p, in_len, out, out_max, pkt_type_out);

    /* QUIC Short Header (top 2 bits = 01) */
    if ((p[0] & 0xC0) == 0x40)
        return decode_quic(ctx, p, in_len, out, out_max, pkt_type_out);

    /* TLS Application Data */
    if (p[0] == 0x17)
        return decode_tls(ctx, p, in_len, out, out_max, pkt_type_out);

    return -1;  /* unknown format */
}
