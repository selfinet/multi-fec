/*
 * mt_reorder — mmulti-fec --workers: put WireGuard data packets back in order
 * before they reach WireGuard (prototype, 2026-11-21).
 *
 * With --workers the packets of one inner TCP flow are spread over N independent
 * worker pipelines, so they reach the far side out of order and inner TCP
 * retransmits spuriously (J1900 run42–45: with ordering restored, -P1
 * retransmits went from ~2,000 to 0–5).
 *
 * The reorder state lives in shared memory created before fork, guarded by a
 * process-shared mutex. Each worker inserts its WG-bound datagrams under the
 * lock and sends whatever became in-order right there, still under the lock, so
 * the send order on the shared WG socket is the counter order. (The first
 * version passed everything through the supervisor over a unix socket: one core
 * and an 8 MB queue made it the bottleneck — run45 -P8/30 lost 20–35 % and
 * ping went to 250–400 ms.)
 *
 * WireGuard data message (type 4): [u8 type][3 reserved][le32 receiver][le64 counter][...].
 * The counter is per keypair and increases by one per packet, so a missing
 * counter is a packet that has not arrived (yet). Everything else (handshake,
 * cookie, short packets) is passed through at once.
 * A gap is waited for at most `hold_us`, then skipped; a packet that arrives
 * after its gap was skipped is still delivered (WG's replay window accepts it).
 */
#ifndef MT_REORDER_H
#define MT_REORDER_H
#include <stdint.h>
#include <stddef.h>
#include <sys/socket.h>

struct mt_ro_out {             /* one datagram ready for WireGuard */
    const char *data;
    int         len;
    const struct sockaddr_storage *addr;
    socklen_t   alen;          /* 0 = connected socket */
};

typedef void (*mt_ro_emit_fn)(const mt_ro_out &o, void *arg);

struct mt_ro_stats {
    unsigned long long in, passthru, inorder, buffered, late, skipped_gaps, skipped_pkts, dups, toolong;
    /* buckets <5 <10 <20 <50 <100 >=100 ms */
    unsigned long long hold_hist[6];   /* how long buffered packets waited */
    unsigned long long late_hist[6];   /* how long after its gap was skipped a late packet came */
    unsigned long long late_unknown;
};

/* create the shared state (call before fork); 0 = ok */
int  mt_ro_shm_init(uint64_t hold_us);
/* per process: where released datagrams go (called with the lock held) */
void mt_ro_set_emit(mt_ro_emit_fn emit, void *arg);
/* convenience for tests: shm_init + set_emit */
void mt_ro_init(uint64_t hold_us, mt_ro_emit_fn emit, void *arg);

void mt_ro_lock();
void mt_ro_unlock();
/* the following require the lock */
void mt_ro_input(const char *data, int len, const struct sockaddr_storage *addr, socklen_t alen, uint64_t now_us);
/* release gaps older than hold_us; returns µs until the next deadline, or -1 if nothing waits */
long long mt_ro_timer(uint64_t now_us);
/* lock-free hint: is anything buffered? */
bool mt_ro_pending();
/* send turns: take a ticket while holding the lock (only if there is something
 * to send), unlock, wait for the turn, send, mark done — sends stay in release
 * order across workers but no longer hold up insertion by the others */
uint64_t mt_ro_take_ticket();
void     mt_ro_wait_turn(uint64_t t);
void     mt_ro_done_turn();
void mt_ro_get_stats(mt_ro_stats *s);
#endif
