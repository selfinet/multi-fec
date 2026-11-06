/*
 * mf_probe.cpp — builtin reply to unauthenticated senders. See mf_probe.h.
 */
#include "mf_probe.h"
#include "log.h"

#include <string.h>
#include <stdlib.h>

namespace {

struct bucket_t {
    uint8_t   key[16];   /* source IP (v4 in the first 4 bytes) */
    uint8_t   family;    /* 0 = empty                            */
    double    tokens;
    my_time_t last_ms;
};

bucket_t           g_src[PROBE_TABLE_SIZE];
double             g_global_tokens  = PROBE_GLOBAL_BURST;
my_time_t          g_global_last_ms = 0;
struct probe_stats g_stats;
struct probe_stats g_logged;
my_time_t          g_last_log_ms = 0;

bool take(double &tokens, my_time_t &last_ms, my_time_t now,
          double rate, double burst)
{
    if (last_ms == 0 || now < last_ms) {
        tokens = burst;
    } else {
        tokens += (double)(now - last_ms) * rate / 1000.0;
        if (tokens > burst) tokens = burst;
    }
    last_ms = now;
    if (tokens < 1.0) return false;
    tokens -= 1.0;
    return true;
}

/* Keyed by IP only: the port is free for a spoofer to vary, and the IP is
 * the victim an amplification attack aims at. */
bucket_t &bucket_for(const address_t &src)
{
    uint8_t  key[16] = {0};
    uint8_t  family;
    address_t a = src;
    if (a.get_type() == AF_INET6) {
        memcpy(key, &a.inner.ipv6.sin6_addr, 16);
        family = 6;
    } else {
        memcpy(key, &a.inner.ipv4.sin_addr, 4);
        family = 4;
    }
    /* FNV-1a over the address bytes */
    uint32_t h = 2166136261u;
    for (int i = 0; i < 16; i++) { h ^= key[i]; h *= 16777619u; }
    bucket_t &b = g_src[h % PROBE_TABLE_SIZE];
    if (b.family != family || memcmp(b.key, key, 16) != 0) {
        memcpy(b.key, key, 16);
        b.family  = family;
        b.last_ms = 0;          /* fresh bucket for a new occupant */
    }
    return b;
}

void maybe_log(my_time_t now)
{
    if (now - g_last_log_ms < 60000) return;
    g_last_log_ms = now;
    uint64_t small   = g_stats.small   - g_logged.small;
    uint64_t limited = g_stats.limited - g_logged.limited;
    uint64_t sent    = g_stats.sent    - g_logged.sent;
    g_logged = g_stats;
    if (small || limited)
        mylog(log_info, "[probe] last period: replied %llu, dropped %llu below minimum size, "
                        "%llu by rate limit\n",
              (unsigned long long)sent, (unsigned long long)small,
              (unsigned long long)limited);
}

}  // namespace

int probe_reply(int fd, const address_t &src, int req_len, obfs_mode_t mode)
{
    my_time_t now = (my_time_t)get_current_time();
    maybe_log(now);

    static const uint8_t close_notify[] = { 0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00 };
    const int min_req = (mode == OBFS_MODE_TLS) ? (int)sizeof(close_notify)
                                                : QUIC_INITIAL_SIZE;
    if (req_len < min_req) {
        g_stats.small++;
        return 0;
    }

    bucket_t &b = bucket_for(src);
    if (!take(b.tokens, b.last_ms, now, PROBE_SRC_RATE, PROBE_SRC_BURST) ||
        !take(g_global_tokens, g_global_last_ms, now, PROBE_GLOBAL_RATE, PROBE_GLOBAL_BURST)) {
        g_stats.limited++;
        return 0;
    }

    address_t dst = src;
    const void *out;
    int out_len;
    static char buf[QUIC_INITIAL_SIZE + 256];

    if (mode == OBFS_MODE_TLS) {
        out     = close_notify;
        out_len = (int)sizeof(close_notify);
    } else {
        int n = obfs_encode_probe_reply(buf, (int)sizeof(buf));
        if (n <= 0) return 0;
        /* 0–255 extra bytes (QUIC coalesced-packet area) vary the size;
         * keep the total within 3x the request (RFC 9000 §8.1). */
        int extra = rand() % 256;
        if (n + extra > 3 * req_len) extra = 3 * req_len - n;
        if (extra < 0) extra = 0;
        for (int i = n; i < n + extra; i++)
            buf[i] = (char)(rand() & 0xFF);
        out     = buf;
        out_len = n + extra;
    }

    ssize_t r = sendto(fd, out, (size_t)out_len, 0,
                       (struct sockaddr *)&dst.inner, dst.get_len());
    if (r <= 0) return 0;
    g_stats.sent++;
    return (int)r;
}

void probe_get_stats(struct probe_stats *out)
{
    if (out) *out = g_stats;
}
