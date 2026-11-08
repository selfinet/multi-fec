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

/* --decoy: concurrent prober sessions (one socket each), server and relay.
 * The effective cap is g_decoy_session_max: this value, lowered at start-up so
 * decoy sockets fit in the process FD budget (mf_fd_budget_init). */
#define DECOY_SESSION_MAX  256
extern int g_decoy_session_max;

/* FDs kept free for everything that is not a per-peer socket: listen/mud/TOTP
 * sockets, timers, epoll, stdio, log, /proc reads. */
#define MF_FD_RESERVE      64

/* Process FD budget for per-peer sockets (server: WG conv sockets, relay:
 * upstream session sockets) and decoy sockets, taken together.
 *
 * Until 1.4.2 each kind was capped on its own — server conv at soft−64, relay
 * sessions at 800, decoy at 256 — so with the default soft limit of 1024 the
 * caps summed past the limit, and a decoy flood, which needs no key, could
 * take the FDs authenticated clients were budgeted for. Now:
 *   avail = soft RLIMIT_NOFILE − FDs already open − MF_FD_RESERVE
 *   decoy = min(DECOY_SESSION_MAX, avail / 4)   (0 without --decoy)
 *   main  = min(main_cap, avail − decoy)        (main_cap 0 = no own cap)
 * Returns main (at least 1) and sets g_decoy_session_max. */
int mf_fd_budget_init(const char *who, bool decoy_enabled, int main_cap);

struct probe_stats {
    uint64_t sent;      /* replies sent                          */
    uint64_t small;     /* dropped: request below minimum size   */
    uint64_t limited;   /* dropped: rate limit                   */
};

/* Reply to an unauthenticated datagram of req_len bytes from src on fd.
 * Returns the number of bytes sent, or 0 when the reply was suppressed. */
int  probe_reply(int fd, const address_t &src, int req_len, obfs_mode_t mode,
                 const address_t *local = NULL);

/* sendto() from a chosen local address (IP_PKTINFO / IPV6_PKTINFO), so a reply
 * leaves from the address the request was sent to even on a wildcard-bound
 * socket. local NULL → plain sendto(). */
ssize_t mf_sendto_from(int fd, const void *buf, size_t len,
                       const address_t &dst, const address_t *local);
void probe_get_stats(struct probe_stats *out);

#endif
