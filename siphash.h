#pragma once
/*
 * SipHash-2-4: 64-bit output, 128-bit key
 * Reference implementation by Jean-Philippe Aumasson and Daniel J. Bernstein
 * Public Domain
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define SIPHASH_ROTL(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))

#define SIPHASH_SIPROUND(v0,v1,v2,v3) do { \
    v0 += v1; v1 = SIPHASH_ROTL(v1,13); v1 ^= v0; v0 = SIPHASH_ROTL(v0,32); \
    v2 += v3; v3 = SIPHASH_ROTL(v3,16); v3 ^= v2;                            \
    v0 += v3; v3 = SIPHASH_ROTL(v3,21); v3 ^= v0;                            \
    v2 += v1; v1 = SIPHASH_ROTL(v1,17); v1 ^= v2; v2 = SIPHASH_ROTL(v2,32); \
} while(0)

static inline uint64_t
siphash24(const uint8_t *in, size_t inlen, const uint8_t key[16])
{
    uint64_t k0, k1;
    memcpy(&k0, key,     8);
    memcpy(&k1, key + 8, 8);

    uint64_t v0 = k0 ^ UINT64_C(0x736f6d6570736575);
    uint64_t v1 = k1 ^ UINT64_C(0x646f72616e646f6d);
    uint64_t v2 = k0 ^ UINT64_C(0x6c7967656e657261);
    uint64_t v3 = k1 ^ UINT64_C(0x7465646279746573);

    const uint8_t *end  = in + inlen - (inlen % 8);
    const int left      = (int)(inlen & 7);

    for (; in != end; in += 8) {
        uint64_t m;
        memcpy(&m, in, 8);
        v3 ^= m;
        SIPHASH_SIPROUND(v0,v1,v2,v3);
        SIPHASH_SIPROUND(v0,v1,v2,v3);
        v0 ^= m;
    }

    uint64_t b = ((uint64_t)inlen) << 56;
    switch (left) {
        case 7: b |= ((uint64_t)in[6]) << 48; /* fallthrough */
        case 6: b |= ((uint64_t)in[5]) << 40; /* fallthrough */
        case 5: b |= ((uint64_t)in[4]) << 32; /* fallthrough */
        case 4: b |= ((uint64_t)in[3]) << 24; /* fallthrough */
        case 3: b |= ((uint64_t)in[2]) << 16; /* fallthrough */
        case 2: b |= ((uint64_t)in[1]) <<  8; /* fallthrough */
        case 1: b |= ((uint64_t)in[0]);        break;
        case 0: break;
    }
    v3 ^= b;
    SIPHASH_SIPROUND(v0,v1,v2,v3);
    SIPHASH_SIPROUND(v0,v1,v2,v3);
    v0 ^= b;

    v2 ^= 0xff;
    SIPHASH_SIPROUND(v0,v1,v2,v3);
    SIPHASH_SIPROUND(v0,v1,v2,v3);
    SIPHASH_SIPROUND(v0,v1,v2,v3);
    SIPHASH_SIPROUND(v0,v1,v2,v3);

    return v0 ^ v1 ^ v2 ^ v3;
}
