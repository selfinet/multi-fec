/*
 * mf_probe.h — builtin reply to unauthenticated senders (server/relay)
 *
 * When a datagram fails authentication and --decoy is not set, multi-fec
 * answers like a QUIC (or TLS) server would, so an active prober sees a
 * plausible service instead of silence. Since 1.4.2 the reply is guarded:
 *
 *   - QUIC mode answers only datagrams of at least QUIC_INITIAL_SIZE (1200 B),
 *     as RFC 9000 §14.1 requires of a real server. Smaller ones are dropped
 *     silently. A 10-byte request used to buy a 1200–1455 B reply (~140x),
 *     which made every listener an open UDP amplifier — and a reply no real
 *     QUIC server would send.
 *   - The reply never exceeds 3x the request (RFC 9000 §8.1).
 *   - Token-bucket limits per source IP and in total, so spoofed floods
 *     cannot aim the replies at a third party.
 *   - The reply's DCID is random (obfs_encode_probe_reply), never the token.
 */
#ifndef MF_PROBE_H
#define MF_PROBE_H

#include "common.h"
#include "obfs.h"

#define PROBE_SRC_RATE     2      /* replies/s per source IP          */
#define PROBE_SRC_BURST    5
#define PROBE_GLOBAL_RATE  200    /* replies/s for the whole process  */
#define PROBE_GLOBAL_BURST 400
#define PROBE_TABLE_SIZE   4096   /* per-IP buckets, direct-mapped    */

/* --decoy: concurrent prober sessions (one socket each), server and relay. */
#define DECOY_SESSION_MAX  256

struct probe_stats {
    uint64_t sent;      /* replies sent                          */
    uint64_t small;     /* dropped: request below minimum size   */
    uint64_t limited;   /* dropped: rate limit                   */
};

/* Reply to an unauthenticated datagram of req_len bytes from src on fd.
 * Returns the number of bytes sent, or 0 when the reply was suppressed. */
int  probe_reply(int fd, const address_t &src, int req_len, obfs_mode_t mode);
void probe_get_stats(struct probe_stats *out);

#endif
