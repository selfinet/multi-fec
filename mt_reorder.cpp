/* mt_reorder — description in mt_reorder.h */
#include "mt_reorder.h"
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/mman.h>

#define RO_CAP      2048        /* reorder depth per stream (packets) */
#define RO_STREAMS  4           /* keypairs tracked at once (rotation overlaps) */
#define RO_MAXLEN   1600        /* WG MTU 1300 + headers; longer datagrams pass through */

struct ro_slot {
    bool     valid;
    uint64_t ctr;
    uint64_t t_in;              /* when it was buffered (diagnostics) */
    int      len;
    socklen_t alen;
    struct sockaddr_storage addr;
    char     data[RO_MAXLEN];
};

struct ro_stream {
    bool     used;
    uint32_t rx_index;
    uint64_t next;              /* next counter to release */
    int      count;             /* buffered packets */
    uint64_t hole_since;        /* when the current gap started waiting, 0 = no gap */
    uint64_t last_use;
    uint64_t skip_c[RO_CAP];    /* counters given up on, and when (diagnostics: how late do they come) */
    uint64_t skip_t[RO_CAP];
    ro_slot  slots[RO_CAP];
};

struct ro_shared {              /* one mapping shared by all workers (MAP_SHARED before fork) */
    pthread_mutex_t mu;
    uint64_t        hold_us;
    volatile int    total;      /* buffered packets over all streams (hint, read without lock) */
    uint64_t        ticket_next;   /* send turns: taken under the lock, served in order outside it */
    uint64_t        now_serving;
    mt_ro_stats     stats;
    ro_stream       st[RO_STREAMS];
};

static ro_shared    *s_sh = NULL;
static mt_ro_emit_fn s_emit = NULL;     /* per process */
static void         *s_arg = NULL;

#define s_st     (s_sh->st)
#define s_hold_us (s_sh->hold_us)
#define s_stats  (s_sh->stats)

int mt_ro_shm_init(uint64_t hold_us)
{
    void *p = mmap(NULL, sizeof(ro_shared), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    s_sh = (ro_shared *)p;                       /* zero-filled by mmap */
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_setpshared(&a, PTHREAD_PROCESS_SHARED);
    if (pthread_mutex_init(&s_sh->mu, &a) != 0) return -1;
    pthread_mutexattr_destroy(&a);
    s_sh->hold_us = hold_us;
    return 0;
}

void mt_ro_set_emit(mt_ro_emit_fn emit, void *arg) { s_emit = emit; s_arg = arg; }

void mt_ro_init(uint64_t hold_us, mt_ro_emit_fn emit, void *arg)
{
    if (!s_sh) mt_ro_shm_init(hold_us);
    s_sh->hold_us = hold_us;
    mt_ro_set_emit(emit, arg);
}

void mt_ro_lock()   { pthread_mutex_lock(&s_sh->mu); }
void mt_ro_unlock() { s_sh->total = 0; for (int i = 0; i < RO_STREAMS; i++) s_sh->total += s_sh->st[i].count; pthread_mutex_unlock(&s_sh->mu); }
bool mt_ro_pending() { return s_sh && s_sh->total > 0; }

#include <sched.h>
uint64_t mt_ro_take_ticket() { return s_sh->ticket_next++; }       /* lock held */
void mt_ro_wait_turn(uint64_t t)
{
    for (unsigned spins = 0; __atomic_load_n(&s_sh->now_serving, __ATOMIC_ACQUIRE) != t; spins++)
        if (spins > 64) sched_yield();
}
void mt_ro_done_turn() { __atomic_add_fetch(&s_sh->now_serving, 1, __ATOMIC_RELEASE); }

void mt_ro_get_stats(mt_ro_stats *s) { *s = s_stats; }

static void emit_raw(const char *data, int len, const struct sockaddr_storage *addr, socklen_t alen)
{
    mt_ro_out o;
    o.data = data; o.len = len; o.addr = addr; o.alen = alen;
    s_emit(o, s_arg);
}

static inline int hbucket(uint64_t us) { return us < 5000 ? 0 : us < 10000 ? 1 : us < 20000 ? 2 : us < 50000 ? 3 : us < 100000 ? 4 : 5; }

static void drain(ro_stream &st, uint64_t now)
{
    for (;;) {
        ro_slot &sl = st.slots[st.next % RO_CAP];
        if (!sl.valid || sl.ctr != st.next) break;
        emit_raw(sl.data, sl.len, &sl.addr, sl.alen);
        s_stats.hold_hist[hbucket(now - sl.t_in)]++;
        sl.valid = false;
        st.count--;
        st.next++;
    }
}

/* When the gap ahead of `next` started blocking: the arrival time of the first
 * buffered packet behind it. Using that (not "when this particular gap became
 * the head") bounds every packet's wait to hold_us. The first version reset the
 * clock whenever a gap partly filled, so a run of small gaps chained the waits:
 * with a 10 ms hold, loopback measured 1,637 packets held >100 ms, released in
 * bursts that overflowed the receiver's socket. */
static uint64_t head_wait_start(ro_stream &st)
{
    for (uint64_t c = st.next + 1; c < st.next + RO_CAP; c++) {
        ro_slot &sl = st.slots[c % RO_CAP];
        if (sl.valid && sl.ctr == c) return sl.t_in;
    }
    return 0;
}

/* give up on the current gap: jump to the lowest buffered counter */
static void skip_gap(ro_stream &st, uint64_t now)
{
    if (st.count <= 0) return;
    for (uint64_t c = st.next + 1; c < st.next + RO_CAP; c++) {
        ro_slot &sl = st.slots[c % RO_CAP];
        if (sl.valid && sl.ctr == c) {
            s_stats.skipped_gaps++;
            s_stats.skipped_pkts += c - st.next;
            for (uint64_t g = st.next; g < c; g++) { st.skip_c[g % RO_CAP] = g; st.skip_t[g % RO_CAP] = now; }
            st.next = c;
            drain(st, now);
            return;
        }
    }
    /* inconsistent (should not happen): drop the buffer */
    for (int i = 0; i < RO_CAP; i++) st.slots[i].valid = false;
    st.count = 0;
}

static void flush_all(ro_stream &st, uint64_t now)
{
    while (st.count > 0) skip_gap(st, now);
    st.hole_since = 0;
}

static ro_stream *find_stream(uint32_t idx, uint64_t now)
{
    ro_stream *lru = &s_st[0];
    for (int i = 0; i < RO_STREAMS; i++) {
        if (s_st[i].used && s_st[i].rx_index == idx) return &s_st[i];
        if (!s_st[i].used) { lru = &s_st[i]; break; }
        if (s_st[i].last_use < lru->last_use) lru = &s_st[i];
    }
    /* new keypair: reuse the least recently used slot after releasing what it holds */
    if (lru->used) flush_all(*lru, now);
    lru->used = true;
    lru->rx_index = idx;
    lru->count = 0;
    lru->hole_since = 0;
    lru->next = UINT64_MAX;     /* set by the first packet */
    lru->last_use = now;
    return lru;
}

void mt_ro_input(const char *data, int len, const struct sockaddr_storage *addr, socklen_t alen, uint64_t now)
{
    s_stats.in++;
    const unsigned char *p = (const unsigned char *)data;
    if (len > RO_MAXLEN) s_stats.toolong++;
    if (len < 32 || len > RO_MAXLEN || p[0] != 4 || p[1] || p[2] || p[3]) {   /* not a WG data message */
        s_stats.passthru++;
        emit_raw(data, len, addr, alen);
        return;
    }
    uint32_t idx; uint64_t ctr;
    memcpy(&idx, p + 4, 4);     /* little-endian on x86; ordering only needs consistency */
    memcpy(&ctr, p + 8, 8);
    ro_stream *st = find_stream(idx, now);
    if (!st) { s_stats.passthru++; emit_raw(data, len, addr, alen); return; }
    st->last_use = now;

    if (st->next == UINT64_MAX) st->next = ctr;
    if (ctr < st->next) {       /* late (its gap was skipped) or duplicate: WG decides */
        s_stats.late++;
        if (st->skip_c[ctr % RO_CAP] == ctr) s_stats.late_hist[hbucket(now - st->skip_t[ctr % RO_CAP])]++;
        else                                 s_stats.late_unknown++;
        emit_raw(data, len, addr, alen);
        return;
    }
    if (ctr - st->next >= RO_CAP) {   /* far ahead: release everything, restart here */
        flush_all(*st, now);
        st->next = ctr;
    }
    if (ctr == st->next) {
        s_stats.inorder++;
        emit_raw(data, len, addr, alen);
        st->next++;
        int before = st->count;
        drain(*st, now);
        if (st->count == 0) st->hole_since = 0;
        else if (st->count != before) st->hole_since = head_wait_start(*st);   /* progress: clock of the new head */
        return;
    }
    ro_slot &sl = st->slots[ctr % RO_CAP];
    if (sl.valid && sl.ctr == ctr) { s_stats.dups++; return; }
    sl.valid = true;
    sl.ctr = ctr;
    sl.len = len;
    sl.alen = alen;
    sl.t_in = now;
    if (alen) memcpy(&sl.addr, addr, alen);
    memcpy(sl.data, data, (size_t)len);
    st->count++;
    s_stats.buffered++;
    if (!st->hole_since) st->hole_since = now;
}

long long mt_ro_timer(uint64_t now)
{
    long long wait = -1;
    for (int i = 0; i < RO_STREAMS; i++) {
        ro_stream &st = s_st[i];
        if (!st.used || st.count <= 0) continue;
        while (st.count > 0 && now - st.hole_since >= s_hold_us) {
            skip_gap(st, now);
            st.hole_since = st.count ? head_wait_start(st) : 0;
        }
        if (st.count > 0) {
            long long w = (long long)(st.hole_since + s_hold_us - now);
            if (wait < 0 || w < wait) wait = w;
        }
    }
    return wait;
}
