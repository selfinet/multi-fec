/*
 * mf_client.cpp — multi-fec client event loop
 *
 * Replaces speeder's tunnel_client.cpp.
 *
 * Data flow (outbound):
 *   WireGuard local UDP → conv header → FEC encode → mud_send() → [obfs] → network
 *
 * Data flow (inbound):
 *   network → [obfs] → mud_recv() → FEC decode → strip conv → WireGuard local UDP
 */

#include "tunnel.h"
#include "mf_common.h"

extern "C" {
#include "mud_lite.h"
}

/* ────────────────────────────────────────────────────────────────
 * Forward declaration
 * ──────────────────────────────────────────────────────────────── */

extern "C" void mf_client_event_loop(struct mud *mud, const struct obfs_ctx *obfs);

/* ────────────────────────────────────────────────────────────────
 * State shared between callbacks (stored on conn_info or passed via watcher->data)
 * ──────────────────────────────────────────────────────────────── */

/* We need the mud pointer accessible from static callbacks */
static struct mud            *g_mud  = NULL;
static const struct obfs_ctx *g_obfs = NULL;

/* ── multipath 모드별 송신 헬퍼 ──────────────────────────────────
 * 모든 mud_send 호출 지점에서 동일한 모드 분기 로직을 사용한다. */
static inline int mud_send_mp(struct mud *mud, const void *data, size_t size)
{
    switch (g_multipath_mode) {
    case MULTIPATH_DUPLICATE:
        return mud_send_all(mud, data, size);
    case MULTIPATH_AGGREGATE:
        return mud_send_next(mud, data, size, 1);
    case MULTIPATH_AGGREGATE_DUPLICATE:
        return mud_send_next(mud, data, size, g_dup_factor);
    default: /* MULTIPATH_FAILOVER */
        return mud_send(mud, data, size);
    }
}

/* ────────────────────────────────────────────────────────────────
 * Pending packet queue — buffers FEC-encoded packets while mud
 * paths are still PROBING (before first RUNNING).
 * Flushed by mud_update_cb() as soon as a path becomes RUNNING.
 * ──────────────────────────────────────────────────────────────── */

#define PENDING_Q_CAP 512

struct pending_pkt_t {
    char data[SESSION_ID_LEN + buf_len];
    int  len;
};

static pending_pkt_t s_pending_q[PENDING_Q_CAP];
static int           s_pending_head  = 0;
static int           s_pending_tail  = 0;
static int           s_pending_count = 0;

static void enqueue_pending(const char *data, int len)
{
    if (s_pending_count == PENDING_Q_CAP) {
        /* Ring full: drop oldest to keep the latest packets */
        s_pending_head = (s_pending_head + 1) % PENDING_Q_CAP;
        s_pending_count--;
    }
    memcpy(s_pending_q[s_pending_tail].data, data, len);
    s_pending_q[s_pending_tail].len = len;
    s_pending_tail = (s_pending_tail + 1) % PENDING_Q_CAP;
    s_pending_count++;
}

static void flush_pending_packets()
{
    int flushed = 0;
    while (s_pending_count > 0) {
        pending_pkt_t &pkt = s_pending_q[s_pending_head];
        int ret = mud_send_mp(g_mud, pkt.data, pkt.len);
        if (ret < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;  /* Still not ready */
        }
        s_pending_head = (s_pending_head + 1) % PENDING_Q_CAP;
        s_pending_count--;
        flushed++;
    }
    if (flushed > 0) {
        mylog(log_info, "[client] flushed %d pending packet(s)\n", flushed);
        mud_send_flush(g_mud);
    }
}

/* ────────────────────────────────────────────────────────────────
 * recvmmsg 배치 수신 인프라
 * WireGuard 소켓에서 최대 WG_RECV_BATCH개 패킷을 syscall 1회로 수신.
 * ──────────────────────────────────────────────────────────────── */

#define WG_RECV_BATCH 32

static struct mmsghdr            s_wg_msgs[WG_RECV_BATCH];
static struct iovec              s_wg_iovecs[WG_RECV_BATCH];
static char                      s_wg_bufs[WG_RECV_BATCH][buf_len];
static struct sockaddr_storage   s_wg_addrs[WG_RECV_BATCH];
static bool                      s_wg_mmsg_inited = false;

static void init_wg_recvmmsg()
{
    for (int i = 0; i < WG_RECV_BATCH; i++) {
        s_wg_iovecs[i].iov_base              = s_wg_bufs[i];
        s_wg_iovecs[i].iov_len               = buf_len;
        s_wg_msgs[i].msg_hdr.msg_iov         = &s_wg_iovecs[i];
        s_wg_msgs[i].msg_hdr.msg_iovlen      = 1;
        s_wg_msgs[i].msg_hdr.msg_name        = &s_wg_addrs[i];
        s_wg_msgs[i].msg_hdr.msg_namelen     = sizeof(s_wg_addrs[i]);
        s_wg_msgs[i].msg_hdr.msg_control     = NULL;
        s_wg_msgs[i].msg_hdr.msg_controllen  = 0;
        s_wg_msgs[i].msg_hdr.msg_flags       = 0;
    }
    s_wg_mmsg_inited = true;
}

/* ────────────────────────────────────────────────────────────────
 * FEC 인코딩 후 mud 송신 (단일 패킷 처리 헬퍼)
 * ──────────────────────────────────────────────────────────────── */

static void send_fec_output(conn_info_t &conn_info,
                             int out_n, char **out_arr, int *out_len)
{
    for (int i = 0; i < out_n; i++) {
        char sbuf[SESSION_ID_LEN + buf_len];
        memcpy(sbuf, g_session_id, SESSION_ID_LEN);
        memcpy(sbuf + SESSION_ID_LEN, out_arr[i], out_len[i]);
        int sbuf_len = SESSION_ID_LEN + out_len[i];

        int ret = mud_send_mp(g_mud, sbuf, sbuf_len);
        if (ret < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                enqueue_pending(sbuf, sbuf_len);
                static uint64_t s_eagain = 0;
                s_eagain++;
                if (s_eagain == 1 || s_eagain % 50 == 0)
                    mylog(log_warn, "[client] mud_send EAGAIN #%llu\n",
                          (unsigned long long)s_eagain);
            } else {
                mylog(log_warn, "[client] mud_send error: %s\n", strerror(errno));
            }
        }
    }
}

/* ────────────────────────────────────────────────────────────────
 * process_one_wg_packet: 단일 WG 패킷 → FEC 인코딩 → mud 큐잉
 * ──────────────────────────────────────────────────────────────── */

static void process_one_wg_packet(conn_info_t &conn_info,
                                   const char *data, int data_len,
                                   struct sockaddr *src_addr, socklen_t src_len)
{
    if (data_len <= 0) return;
    if (data_len == max_data_len + 1) {
        mylog(log_warn, "[client] huge packet truncated, dropped\n");
        return;
    }
    if (!disable_mtu_warn && data_len >= mtu_warn)
        mylog(log_warn, "[client] large packet len=%d\n", data_len);

    address_t addr;
    addr.from_sockaddr(src_addr, src_len);
    mylog(log_trace, "[client] recv from local %s len=%d\n", addr.get_str(), data_len);

    u32_t conv;
    if (!conn_info.conv_manager.c.is_data_used(addr)) {
        if (conn_info.conv_manager.c.get_size() >= max_conv_num) {
            mylog(log_warn, "[client] max_conv_num exceeded, ignoring\n");
            return;
        }
        conv = conn_info.conv_manager.c.get_new_conv();
        conn_info.conv_manager.c.insert_conv(conv, addr);
        mylog(log_info, "[client] new conv from %s conv_id=%x\n", addr.get_str(), conv);
    } else {
        conv = conn_info.conv_manager.c.find_conv_by_data(addr);
    }
    conn_info.conv_manager.c.update_active_time(conv);

    char *new_data = NULL;
    int   new_len  = 0;
    put_conv(conv, data, data_len, new_data, new_len);

    int        out_n    = 0;
    char     **out_arr  = NULL;
    int       *out_len  = NULL;
    my_time_t *out_delay = NULL;
    from_normal_to_fec(conn_info, new_data, new_len, out_n, out_arr, out_len, out_delay);

    mylog(log_trace, "[client] fec output n=%d\n", out_n);
    send_fec_output(conn_info, out_n, out_arr, out_len);
}

/* ────────────────────────────────────────────────────────────────
 * data_from_local_or_fec_timeout
 *   is_time_out == 0 : recvmmsg 배치 수신 (WireGuard → FEC → mud)
 *   is_time_out == 1 : FEC 타이머 flush
 * ──────────────────────────────────────────────────────────────── */

static void data_from_local_or_fec_timeout(conn_info_t &conn_info, int is_time_out)
{
    if (is_time_out) {
        mylog(log_trace, "[client] fec timeout flush\n");
        int        out_n    = 0;
        char     **out_arr  = NULL;
        int       *out_len  = NULL;
        my_time_t *out_delay = NULL;
        from_normal_to_fec(conn_info, 0, 0, out_n, out_arr, out_len, out_delay);
        send_fec_output(conn_info, out_n, out_arr, out_len);
        mud_send_flush(g_mud);
        return;
    }

    /* recvmmsg: WG 소켓에서 최대 WG_RECV_BATCH개 패킷을 한 번에 수신 */
    if (!s_wg_mmsg_inited) init_wg_recvmmsg();

    /* recvmmsg는 msg_namelen을 매 호출 전에 리셋해야 함 */
    for (int i = 0; i < WG_RECV_BATCH; i++)
        s_wg_msgs[i].msg_hdr.msg_namelen = sizeof(s_wg_addrs[i]);

    int nrecv = recvmmsg(conn_info.local_listen_fd,
                         s_wg_msgs, WG_RECV_BATCH, MSG_DONTWAIT, NULL);
    if (nrecv <= 0) return;

    for (int i = 0; i < nrecv; i++) {
        process_one_wg_packet(conn_info,
                              s_wg_bufs[i],
                              (int)s_wg_msgs[i].msg_len,
                              (struct sockaddr *)&s_wg_addrs[i],
                              s_wg_msgs[i].msg_hdr.msg_namelen);
    }

    /* 배치 처리 후 mud 송신 큐를 한 번에 플러시 → sendmmsg 1회 */
    mud_send_flush(g_mud);
}

/* ────────────────────────────────────────────────────────────────
 * mud fd readable: mud_recv → FEC decode → send to local WireGuard
 * ──────────────────────────────────────────────────────────────── */

static void mud_recv_and_forward(conn_info_t &conn_info)
{
    int &local_listen_fd = conn_info.local_listen_fd;

    static char buf[buf_len];

    for (;;) {
        int n = mud_recv(g_mud, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            mylog(log_warn, "[client] mud_recv error: %s\n", strerror(errno));
            break;
        }
        if (n == 0) {
            /* probe/keepalive — 큐에 남은 항목이 있으면 계속 처리 */
            if (mud_recv_pending(g_mud)) continue;
            break;
        }

        mylog(log_trace, "[client] mud_recv %d bytes\n", n);

        if (!disable_mtu_warn && n > mtu_warn) {
            mylog(log_warn, "[client] large mud packet len=%d\n", n);
        }

        /* de_cook equivalent: mud_lite handles obfs; but we still need
         * to process speeder's cook layer if it was applied.
         * In our design we do NOT apply do_cook/de_cook since mud+obfs
         * handles all wire encoding. */

        int        out_n    = 0;
        char     **out_arr  = NULL;
        int       *out_len  = NULL;
        my_time_t *out_delay = NULL;

        from_fec_to_normal(conn_info, buf, n, out_n, out_arr, out_len, out_delay);

        mylog(log_trace, "[client] fec decoded n=%d\n", out_n);

        for (int i = 0; i < out_n; i++) {
            u32_t conv;
            char *new_data = NULL;
            int   new_len  = 0;
            if (get_conv(conv, out_arr[i], out_len[i], new_data, new_len) != 0) {
                mylog(log_debug, "[client] get_conv failed\n");
                continue;
            }
            if (!conn_info.conv_manager.c.is_conv_used(conv)) {
                mylog(log_trace, "[client] conv not found: %x\n", conv);
                continue;
            }
            conn_info.conv_manager.c.update_active_time(conv);

            address_t addr = conn_info.conv_manager.c.find_data_by_conv(conv);
            dest_t dest;
            dest.inner.fd_addr.fd   = local_listen_fd;
            dest.inner.fd_addr.addr = addr;
            dest.type               = type_fd_addr;

            delay_send(out_delay[i], dest, new_data, new_len);
        }
    }
}

/* ────────────────────────────────────────────────────────────────
 * libev callbacks
 * ──────────────────────────────────────────────────────────────── */

static void local_listen_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &ci = *static_cast<conn_info_t *>(watcher->data);
    data_from_local_or_fec_timeout(ci, 0);
}

static void mud_io_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &ci = *static_cast<conn_info_t *>(watcher->data);
    mud_recv_and_forward(ci);
}

static void fec_encode_cb(struct ev_loop * /*loop*/, struct ev_timer *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &ci = *static_cast<conn_info_t *>(watcher->data);
    data_from_local_or_fec_timeout(ci, 1);
}

static void conn_timer_cb(struct ev_loop * /*loop*/, struct ev_timer *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &ci = *static_cast<conn_info_t *>(watcher->data);
    ci.conv_manager.c.clear_inactive();
    ci.stat.report_as_client();

    {
        static unsigned s_path_ticks = 0;
        if (++s_path_ticks % 75 == 0) {  /* ~30s at 400ms interval */
            struct mud_paths paths;
            mud_get_paths(g_mud, &paths, NULL, NULL);
            static const char *s_status_names[] = {
                "DELETING","PROBING","DEGRADED","LOSSY","WAITING","READY","RUNNING"
            };
            for (unsigned i = 0; i < paths.count; i++) {
                struct mud_path *p = &paths.path[i];
                const char *st = (unsigned)p->status <= (unsigned)MUD_RUNNING
                                 ? s_status_names[p->status] : "?";
                mylog(log_info,
                      "[client] path[%u] %s rtt=%lluus jit=%lluus loss=%u%% rate=%.1fMbps tx=%llu rx=%llu\n",
                      i, st,
                      (unsigned long long)(p->rtt.val / 1000),
                      (unsigned long long)(p->rtt.var / 1000),
                      (unsigned)((unsigned)p->tx.loss * 100U / 255U),
                      (double)p->tx.rate * 8.0 / 1.0e6,
                      (unsigned long long)p->tx.total,
                      (unsigned long long)p->rx.total);
            }
        }
    }

    if (debug_force_flush_fec) {
        int        out_n    = 0;
        char     **out_arr  = NULL;
        int       *out_len  = NULL;
        my_time_t *out_delay = NULL;
        from_normal_to_fec(ci, 0, 0, out_n, out_arr, out_len, out_delay);
        send_fec_output(ci, out_n, out_arr, out_len);
        mud_send_flush(g_mud);
    }
}

static void mud_update_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/, int /*revents*/)
{
    mud_update(g_mud);
    if (s_pending_count > 0)
        flush_pending_packets();
}

static void delay_manager_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/, int /*revents*/)
{
    /* nothing — delay_manager checks happen via ev_prepare */
}

static void prepare_cb(struct ev_loop * /*loop*/, struct ev_prepare * /*watcher*/, int /*revents*/)
{
    delay_manager.check();
}

/* ────────────────────────────────────────────────────────────────
 * mf_client_event_loop()
 * ──────────────────────────────────────────────────────────────── */

void mf_client_event_loop(struct mud *mud, const struct obfs_ctx *obfs)
{
    g_mud  = mud;
    g_obfs = obfs;

    mylog(log_info, "[client] starting event loop\n");

    /* conn_info is large — heap allocate */
    conn_info_t *conn_info_p = new conn_info_t;
    conn_info_t &conn_info   = *conn_info_p;

    struct ev_loop *loop = ev_default_loop(0);
    assert(loop != NULL);
    conn_info.loop = loop;

    /* Local listen socket (WireGuard proxy port) */
    int &local_listen_fd = conn_info.local_listen_fd;
    new_listen_socket2(local_listen_fd, local_addr);
    mylog(log_info, "[client] local listen fd=%d addr=%s\n",
          local_listen_fd, local_addr.get_str());

    /* FEC encode manager */
    conn_info.fec_encode_manager.set_data(&conn_info);
    conn_info.fec_encode_manager.set_loop_and_cb(loop, fec_encode_cb);
    conn_info.rnlc_encode_manager.set_data(&conn_info);
    conn_info.rnlc_encode_manager.set_loop_and_cb(loop, fec_encode_cb);

    /* delay manager */
    delay_manager.set_loop_and_cb(loop, delay_manager_cb);

    /* ev_io: local WireGuard UDP */
    struct ev_io local_watcher;
    local_watcher.data = &conn_info;
    ev_io_init(&local_watcher, local_listen_cb, local_listen_fd, EV_READ);
    ev_io_start(loop, &local_watcher);

    /* ev_io: mud fd */
    struct ev_io mud_watcher;
    mud_watcher.data = &conn_info;
    ev_io_init(&mud_watcher, mud_io_cb, mud_get_fd(mud), EV_READ);
    ev_io_start(loop, &mud_watcher);

    /* ev_timer: conn cleanup + stats */
    conn_info.timer.data = &conn_info;
    ev_init(&conn_info.timer, conn_timer_cb);
    ev_timer_set(&conn_info.timer, 0, (double)timer_interval / 1000.0);
    ev_timer_start(loop, &conn_info.timer);

    /* ev_timer: mud_update every 100ms */
    struct ev_timer mud_timer;
    ev_timer_init(&mud_timer, mud_update_cb, 0.1, 0.1);
    ev_timer_start(loop, &mud_timer);

    /* ev_prepare: delay_manager */
    ev_prepare prepare_watcher;
    ev_init(&prepare_watcher, prepare_cb);
    ev_prepare_start(loop, &prepare_watcher);

    mylog(log_info, "[client] listening at %s, %zu static path(s)\n",
          local_addr.get_str(), g_paths.size());

    /* QUIC Long Header Initial 전송: 이벤트 루프 시작 전에 전송해야
     * mud probe보다 먼저 나가서 DPI가 올바른 순서로 본다.
     * → C→S: Initial (Long Header, 1200B)
     * → S→C: Initial response (Long Header, 1200B)
     * → 이후: Short Header 데이터 패킷 */
    {
        int n = mud_send_initials(g_mud);
        if (n > 0) {
            mylog(log_info, "[client] sent QUIC Initial on %d path(s)\n", n);
            mud_send_flush(g_mud);  /* 이벤트 루프 시작 전 즉시 전송 */
        }
    }

    ev_run(loop, 0);

    mylog(log_warn, "[client] ev_run returned\n");

    delete conn_info_p;
}
