/* wg_batch — 설명은 wg_batch.h */
#include "wg_batch.h"
#include "misc.h"
#include "log.h"
#include "fd_manager.h"
#include "mt_reorder.h"
#include <time.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <errno.h>
#include <string.h>

extern int random_drop;
bool g_reorder_shm = false;   /* mmulti-fec --reorder-ms: WG-bound datagrams go through the shared reorder buffer */
extern int g_shared_wg_fd;     /* main.cpp */

static int reorder_flush(int n_items);

#define WG_BATCH_CAP 64

struct wg_batch_item {
    int fd;
    struct sockaddr_storage addr;
    socklen_t alen;             /* 0 = 연결된 소켓(send) */
    int len;
    char data[buf_len];
};
static wg_batch_item s_items[WG_BATCH_CAP];
static int s_n = 0;
static unsigned long long s_err = 0;

int wg_batch_flush()
{
    if (g_reorder_shm) { int r = reorder_flush(s_n); s_n = 0; return r; }
    int sent_total = 0;
    struct mmsghdr msgs[WG_BATCH_CAP];
    struct iovec iov[WG_BATCH_CAP];
    int i = 0;
    while (i < s_n) {
        int j = i;
        while (j < s_n && s_items[j].fd == s_items[i].fd) j++;   /* 같은 소켓이 이어지는 구간 */
        int cnt = j - i;
        for (int k = 0; k < cnt; k++) {
            wg_batch_item &it = s_items[i + k];
            iov[k].iov_base = it.data;
            iov[k].iov_len  = (size_t)it.len;
            memset(&msgs[k], 0, sizeof(msgs[k]));
            msgs[k].msg_hdr.msg_iov     = &iov[k];
            msgs[k].msg_hdr.msg_iovlen  = 1;
            msgs[k].msg_hdr.msg_name    = it.alen ? (void *)&it.addr : NULL;
            msgs[k].msg_hdr.msg_namelen = it.alen;
        }
        int off = 0;
        while (off < cnt) {
            int r = sendmmsg(s_items[i].fd, msgs + off, (unsigned)(cnt - off), MSG_DONTWAIT);
            if (r <= 0) {
                /* sendto() 한 번이 실패하면 그 패킷만 잃던 것과 맞춘다 — 실패한 하나를 건너뛰고 계속 */
                s_err++;
                if (s_err == 1 || s_err % 1000 == 0)
                    mylog(log_warn, "[wg_batch] sendmmsg fd=%d: %s (total %llu)\n", s_items[i].fd, strerror(errno), s_err);
                off++;
                continue;
            }
            off += r;
            sent_total += r;
        }
        i = j;
    }
    s_n = 0;
    return sent_total;
}

int wg_batch_send(my_time_t delay, const dest_t &dest, char *data, int len)
{
    if (delay != 0 || random_drop != 0 || dest.cook || len <= 0 || len > buf_len)
        return delay_send(delay, dest, data, len);
    int fd = -1;
    const address_t *addr = NULL;
    switch (dest.type) {
        case type_fd_addr:
            fd = dest.inner.fd_addr.fd; addr = &dest.inner.fd_addr.addr; break;
        case type_fd64:
            if (!fd_manager.exist(dest.inner.fd64)) return -1;
            fd = fd_manager.to_fd(dest.inner.fd64); break;
        case type_fd:
            fd = dest.inner.fd; break;
        default:
            return delay_send(delay, dest, data, len);
    }
    if (s_n == WG_BATCH_CAP) wg_batch_flush();
    wg_batch_item &it = s_items[s_n++];
    it.fd  = fd;
    it.len = len;
    memcpy(it.data, data, (size_t)len);
    if (addr) {
        it.alen = const_cast<address_t *>(addr)->get_len();   /* get_len() 이 const 가 아니다(upstream) */
        memcpy(&it.addr, &addr->inner, it.alen);
    } else {
        it.alen = 0;
    }
    return 0;
}

/* ── mmulti-fec shared reorder ────────────────────────────────────
 * Released datagrams are collected here (process-local) and sent while the
 * reorder lock is still held, so sends on the shared WG socket follow counter
 * order across workers. */
#define RO_OUT_CAP 4200          /* one release can be a whole stream (2048) plus this batch */
struct ro_out_item { int len; socklen_t alen; struct sockaddr_storage addr; char data[1600]; };
static ro_out_item *s_ro_out = NULL;      /* heap, per process */
static int s_ro_n = 0;

static void ro_out_send(int from, int cnt)
{
    struct mmsghdr msgs[64];
    struct iovec iov[64];
    for (int k = 0; k < cnt; k++) {
        ro_out_item &it = s_ro_out[from + k];
        iov[k].iov_base = it.data;
        iov[k].iov_len  = (size_t)it.len;
        memset(&msgs[k], 0, sizeof(msgs[k]));
        msgs[k].msg_hdr.msg_iov     = &iov[k];
        msgs[k].msg_hdr.msg_iovlen  = 1;
        msgs[k].msg_hdr.msg_name    = it.alen ? (void *)&it.addr : NULL;
        msgs[k].msg_hdr.msg_namelen = it.alen;
    }
    int off = 0;
    while (off < cnt) {
        int r = sendmmsg(g_shared_wg_fd, msgs + off, (unsigned)(cnt - off), MSG_DONTWAIT);
        if (r <= 0) {
            s_err++;
            if (s_err == 1 || s_err % 1000 == 0)
                mylog(log_warn, "[wg_batch] reorder sendmmsg: %s (total %llu)\n", strerror(errno), s_err);
            off++;
            continue;
        }
        off += r;
    }
}

static void ro_out_flush()
{
    for (int i = 0; i < s_ro_n; i += 64) ro_out_send(i, s_ro_n - i < 64 ? s_ro_n - i : 64);
    s_ro_n = 0;
}

static void ro_emit(const mt_ro_out &o, void *)
{
    if (s_ro_n == RO_OUT_CAP) {   /* cannot happen with RO_OUT_CAP > RO_CAP + batch; keep order anyway */
        static unsigned long long s_ovf = 0;
        if (++s_ovf == 1 || s_ovf % 1000 == 0) mylog(log_warn, "[wg_batch] reorder out buffer full (%llu)\n", s_ovf);
        return;
    }
    ro_out_item &e = s_ro_out[s_ro_n++];
    e.len = o.len < (int)sizeof(e.data) ? o.len : (int)sizeof(e.data);
    memcpy(e.data, o.data, (size_t)e.len);
    e.alen = o.alen;
    if (o.alen) memcpy(&e.addr, o.addr, o.alen);
}

static uint64_t ro_now_us()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000;
}

void wg_reorder_worker_init()
{
    s_ro_out = (ro_out_item *)malloc(sizeof(ro_out_item) * RO_OUT_CAP);
    if (!s_ro_out) { mylog(log_fatal, "reorder out buffer alloc failed\n"); myexit(1); }
    mt_ro_set_emit(ro_emit, NULL);
}

/* called with the reorder lock held: hand off the released packets outside it */
static void ro_release_and_send()
{
    if (s_ro_n == 0) { mt_ro_unlock(); return; }
    uint64_t t = mt_ro_take_ticket();
    mt_ro_unlock();
    mt_ro_wait_turn(t);
    ro_out_flush();
    mt_ro_done_turn();
}

static int reorder_flush(int n)
{
    if (n <= 0) return 0;
    mt_ro_lock();
    uint64_t now = ro_now_us();
    for (int k = 0; k < n; k++) {
        wg_batch_item &it = s_items[k];
        /* server items carry no address (connected per-conv dup); the shared socket is connected the same way */
        mt_ro_input(it.data, it.len, &it.addr, it.alen, now);
    }
    mt_ro_timer(now);
    ro_release_and_send();
    return n;
}

void wg_reorder_tick()
{
    if (!g_reorder_shm || !mt_ro_pending()) return;
    mt_ro_lock();
    mt_ro_timer(ro_now_us());
    ro_release_and_send();
}
