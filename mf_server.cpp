/*
 * mf_server.cpp — multi-fec server event loop
 *
 * Replaces speeder's tunnel_server.cpp.
 *
 * Data flow (inbound from clients):
 *   network → [obfs] → mud_recv() → FEC decode → strip conv → WireGuard server
 *
 * Data flow (outbound to clients):
 *   WireGuard server reply → add conv → FEC encode → mud_send() → [obfs] → network
 *
 * Key difference from speeder:
 *   The "local listen fd" for incoming data is replaced by mud_recv().
 *   mud is single-fd and demuxes multiple clients internally.
 *   We peek at the source address via recvfrom(MSG_PEEK) to identify the client
 *   before calling mud_recv() to consume the packet.
 */

#include "tunnel.h"
#include "mf_common.h"
#include "obfs.h"

extern "C" {
#include "mud_lite.h"
}

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unordered_map>
#include <stdint.h>
#include <fcntl.h>
#include <errno.h>

/* ────────────────────────────────────────────────────────────────
 * Forward declaration
 * ──────────────────────────────────────────────────────────────── */

extern "C" void mf_server_event_loop(struct mud *mud, const struct obfs_ctx *obfs,
                                     int decoy_fd, address_t decoy_addr);

/* ────────────────────────────────────────────────────────────────
 * Global mud pointer (accessible from static callbacks)
 * ──────────────────────────────────────────────────────────────── */

static struct mud            *g_mud  = NULL;
static const struct obfs_ctx *g_obfs = NULL;

static inline int mud_send_mp(struct mud *mud, const void *data, size_t size)
{
    switch (g_multipath_mode) {
    case MULTIPATH_DUPLICATE:
        return mud_send_all(mud, data, size);
    case MULTIPATH_AGGREGATE:
        return mud_send_next(mud, data, size, 1);
    case MULTIPATH_AGGREGATE_DUPLICATE:
        return mud_send_next(mud, data, size, g_dup_factor);
    default:
        return mud_send(mud, data, size);
    }
}
static struct ev_loop        *g_loop = NULL;

/* ────────────────────────────────────────────────────────────────
 * Pending packet queue — buffers packets on mud EAGAIN.
 * Flushed in mud_update_cb (100ms) when window has room.
 * ──────────────────────────────────────────────────────────────── */

#define SERVER_PENDING_Q_CAP 4096

struct server_pending_pkt_t {
    char data[buf_len];
    int  len;
};

static server_pending_pkt_t s_srv_pending_q[SERVER_PENDING_Q_CAP];
static int                  s_srv_pending_head  = 0;
static int                  s_srv_pending_tail  = 0;
static int                  s_srv_pending_count = 0;

static void enqueue_server_pending(const char *data, int len)
{
    if (s_srv_pending_count >= SERVER_PENDING_Q_CAP) {
        mylog(log_debug, "[server] pending queue full, drop pkt len=%d\n", len);
        return;
    }
    server_pending_pkt_t &p = s_srv_pending_q[s_srv_pending_tail];
    memcpy(p.data, data, (size_t)len);
    p.len = len;
    s_srv_pending_tail = (s_srv_pending_tail + 1) % SERVER_PENDING_Q_CAP;
    s_srv_pending_count++;
}

static void flush_server_pending()
{
    while (s_srv_pending_count > 0) {
        server_pending_pkt_t &p = s_srv_pending_q[s_srv_pending_head];
        int ret = mud_send_mp(g_mud, p.data, p.len);
        if (ret < 0) break;  /* window still short — retry next tick */
        s_srv_pending_head = (s_srv_pending_head + 1) % SERVER_PENDING_Q_CAP;
        s_srv_pending_count--;
    }
    mud_send_flush(g_mud);
}

/* session_id map is declared below */

/* session_id(8B) → canonical address_t
 * Even if the same client connects via multiple POPs, the first source
 * address seen is used as the canonical key, keeping a single conn_info. */
static unordered_map<uint64_t, address_t> g_session_to_addr;

/* ────────────────────────────────────────────────────────────────
 * Server TOTP sockets (port hopping)
 *
 * mud_lite supports only a single socket, so a separate raw UDP socket is
 * created per TOTP port and managed directly via ev_io.
 *
 * Recv direction: TOTP socket → obfs_decode → session_id → process_mud_data
 * Send direction: obfs_encode → sendto(totp_fd, client_addr)
 *            (bypasses mud_send to reply directly on the same TOTP port)
 * ──────────────────────────────────────────────────────────────── */

struct totp_entry_t {
    uint64_t slot;
    int      fd;
    ev_io    watcher;
    bool     active;
};

#define SERVER_TOTP_MAX 4
static totp_entry_t g_totp_entries[SERVER_TOTP_MAX];
static uint64_t     g_totp_cur_slot = (uint64_t)-1;

/* client_addr → TOTP fd (used for direct server→client sends) */
static unordered_map<address_t, int> g_addr_to_totp_fd;

/* ────────────────────────────────────────────────────────────────
 * Decoy session management (--decoy ip:port)
 *
 * GFW active-probing countermeasure: forward HMAC-auth-failed packets to a
 * real QUIC/HTTPS server and relay its response back to the prober.
 * To the prober it looks like a normal QUIC server.
 *
 * A separate UDP socket is created per prober address (so the decoy can
 * distinguish connections). Sessions auto-removed after 10s idle.
 * ──────────────────────────────────────────────────────────────── */

struct decoy_sess_t {
    address_t prober_addr;
    int       listen_fd;    /* mud fd or TOTP fd: response is sendto'd on this fd */
    int       decoy_fd;     /* UDP socket connect()ed to the decoy server */
    ev_io     watcher;
    time_t    last_active;
};

static address_t                                g_decoy_upstream;
static bool                                     g_decoy_enabled = false;
static unordered_map<address_t, decoy_sess_t *> g_decoy_map;

static void decoy_cleanup_cb(struct ev_loop *loop, struct ev_timer *, int);

static void
decoy_io_cb(struct ev_loop * /*loop*/, struct ev_io *w, int /*revents*/)
{
    decoy_sess_t *s = static_cast<decoy_sess_t *>(w->data);
    char buf[buf_len];
    for (;;) {
        ssize_t n = recv(s->decoy_fd, buf, sizeof(buf), MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            mylog(log_debug, "[decoy] recv: %s\n", strerror(errno));
            break;
        }
        if (n == 0) break;
        s->last_active = time(NULL);
        sendto(s->listen_fd, buf, (size_t)n, 0,
               (struct sockaddr *)&s->prober_addr.inner, s->prober_addr.get_len());
        mylog(log_debug, "[decoy] → %s %zd bytes\n",
              const_cast<address_t &>(s->prober_addr).get_str(), n);
    }
}

static decoy_sess_t *
decoy_get_or_create(const address_t &prober, int listen_fd)
{
    auto it = g_decoy_map.find(const_cast<address_t &>(prober));
    if (it != g_decoy_map.end()) {
        decoy_sess_t *s = it->second;
        s->last_active = time(NULL);
        s->listen_fd   = listen_fd;
        return s;
    }

    int family = (g_decoy_upstream.get_type() == AF_INET6) ? AF_INET6 : AF_INET;
    int dfd = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (dfd < 0) {
        mylog(log_warn, "[decoy] socket: %s\n", strerror(errno));
        return NULL;
    }
    setnonblocking(dfd);

    int r = connect(dfd,
                    (family == AF_INET)
                        ? (struct sockaddr *)&g_decoy_upstream.inner.ipv4
                        : (struct sockaddr *)&g_decoy_upstream.inner.ipv6,
                    (family == AF_INET) ? (socklen_t)sizeof(struct sockaddr_in)
                                        : (socklen_t)sizeof(struct sockaddr_in6));
    if (r < 0) {
        mylog(log_warn, "[decoy] connect: %s\n", strerror(errno));
        close(dfd);
        return NULL;
    }

    decoy_sess_t *s = new decoy_sess_t;
    s->prober_addr  = prober;
    s->listen_fd    = listen_fd;
    s->decoy_fd     = dfd;
    s->last_active  = time(NULL);
    s->watcher.data = s;
    ev_io_init(&s->watcher, decoy_io_cb, dfd, EV_READ);
    ev_io_start(g_loop, &s->watcher);

    g_decoy_map[const_cast<address_t &>(prober)] = s;
    mylog(log_info, "[decoy] new session prober=%s\n",
          const_cast<address_t &>(prober).get_str());
    return s;
}

static void
decoy_forward(const address_t &prober, int listen_fd, const void *pkt, int pkt_len)
{
    decoy_sess_t *s = decoy_get_or_create(prober, listen_fd);
    if (!s) return;
    ssize_t n = send(s->decoy_fd, pkt, (size_t)pkt_len, 0);
    if (n < 0)
        mylog(log_debug, "[decoy] send: %s\n", strerror(errno));
    else
        mylog(log_debug, "[decoy] ← %s %d bytes forwarded\n",
              const_cast<address_t &>(prober).get_str(), pkt_len);
}

static void
decoy_cleanup_cb(struct ev_loop *loop, struct ev_timer * /*w*/, int /*revents*/)
{
    time_t now = time(NULL);
    for (auto it = g_decoy_map.begin(); it != g_decoy_map.end(); ) {
        decoy_sess_t *s = it->second;
        if (now - s->last_active > 10) {
            ev_io_stop(loop, &s->watcher);
            close(s->decoy_fd);
            mylog(log_debug, "[decoy] evict prober=%s\n",
                  const_cast<address_t &>(s->prober_addr).get_str());
            delete s;
            it = g_decoy_map.erase(it);
        } else {
            ++it;
        }
    }
}

/* forward declarations */
static void server_totp_io_cb(struct ev_loop *loop, struct ev_io *w, int revents);
static void server_add_totp_socket(struct ev_loop *loop, uint64_t slot);
static void server_remove_totp_socket(uint64_t slot);
static void server_update_totp_ports(struct ev_loop *loop);

/* ────────────────────────────────────────────────────────────────
 * Forward declaration of callbacks that reference each other
 * ──────────────────────────────────────────────────────────────── */

static void conn_timer_cb(struct ev_loop *loop, struct ev_timer *watcher, int revents);
static void fec_encode_cb(struct ev_loop *loop, struct ev_timer *watcher, int revents);
static void wg_remote_cb(struct ev_loop *loop, struct ev_io *watcher, int revents);

/* ────────────────────────────────────────────────────────────────
 * Modes for the combined server handler (mirrors speeder's enum)
 * ──────────────────────────────────────────────────────────────── */

enum srv_mode_t {
    is_from_wg = 0,   /* data from WireGuard server → send back to client */
    is_fec_timeout,   /* FEC encode timer → flush partial group */
    is_conn_timer,    /* periodic cleanup timer */
};

/* ────────────────────────────────────────────────────────────────
 * data_from_wg_or_fec_timeout_or_conn_timer
 *
 *   conn_info : per-client connection state
 *   fd64      : WireGuard fd64 (used when mode==is_from_wg)
 *   mode      : what triggered this call
 * ──────────────────────────────────────────────────────────────── */

static void data_from_wg_or_fec_timeout_or_conn_timer(conn_info_t &conn_info,
                                                       fd64_t fd64,
                                                       srv_mode_t mode)
{
    int ret;
    (void)ret;
    u32_t conv = 0;

    address_t &addr = conn_info.addr;
    assert(conn_manager.exist(addr));

    int out_n = -2;
    char **out_arr  = NULL;
    int  *out_len   = NULL;
    my_time_t *out_delay = NULL;

    if (mode == is_fec_timeout) {
        from_normal_to_fec(conn_info, 0, 0, out_n, out_arr, out_len, out_delay);
    } else if (mode == is_conn_timer) {
        conn_info.conv_manager.s.clear_inactive();
        if (debug_force_flush_fec) {
            from_normal_to_fec(conn_info, 0, 0, out_n, out_arr, out_len, out_delay);
        }
        conn_info.stat.report_as_server(addr);
        return;
    } else if (mode == is_from_wg) {
        if (!fd_manager.exist(fd64)) {
            mylog(log_warn, "[server] !fd_manager.exist(fd64)\n");
            return;
        }
        assert(conn_info.conv_manager.s.is_data_used(fd64));

        conv = conn_info.conv_manager.s.find_conv_by_data(fd64);
        conn_info.conv_manager.s.update_active_time(conv);
        conn_info.update_active_time();

        int fd = fd_manager.to_fd(fd64);

        /* Batch-drain the WireGuard socket with recvmmsg */
#define SRV_WG_BATCH 32
        static struct mmsghdr srv_wg_msgs[SRV_WG_BATCH];
        static struct iovec   srv_wg_iovecs[SRV_WG_BATCH];
        static char           srv_wg_bufs[SRV_WG_BATCH][buf_len];
        static bool           srv_wg_inited = false;
        if (!srv_wg_inited) {
            for (int bi = 0; bi < SRV_WG_BATCH; bi++) {
                srv_wg_iovecs[bi].iov_base            = srv_wg_bufs[bi];
                srv_wg_iovecs[bi].iov_len             = buf_len;
                srv_wg_msgs[bi].msg_hdr.msg_iov       = &srv_wg_iovecs[bi];
                srv_wg_msgs[bi].msg_hdr.msg_iovlen    = 1;
                srv_wg_msgs[bi].msg_hdr.msg_name      = NULL;
                srv_wg_msgs[bi].msg_hdr.msg_namelen   = 0;
                srv_wg_msgs[bi].msg_hdr.msg_control   = NULL;
                srv_wg_msgs[bi].msg_hdr.msg_controllen= 0;
            }
            srv_wg_inited = true;
        }
        for (int bi = 0; bi < SRV_WG_BATCH; bi++)
            srv_wg_iovecs[bi].iov_len = buf_len;

        int nrecv = recvmmsg(fd, srv_wg_msgs, SRV_WG_BATCH, MSG_DONTWAIT, NULL);
        if (nrecv <= 0) return;

        for (int bi = 0; bi < nrecv; bi++) {
            int pkt_len = (int)srv_wg_msgs[bi].msg_len;
            if (pkt_len <= 0 || pkt_len > max_data_len) continue;
            if (!disable_mtu_warn && pkt_len >= mtu_warn)
                mylog(log_warn, "[server] large WG packet len=%d\n", pkt_len);

            char *new_data = NULL;
            int   new_len  = 0;
            put_conv(conv, srv_wg_bufs[bi], pkt_len, new_data, new_len);

            int        pkt_out_n   = -2;
            char     **pkt_out_arr = NULL;
            int       *pkt_out_len = NULL;
            my_time_t *pkt_delay   = NULL;
            from_normal_to_fec(conn_info, new_data, new_len,
                               pkt_out_n, pkt_out_arr, pkt_out_len, pkt_delay);

            for (int i = 0; i < pkt_out_n; i++) {
                auto totp_it = g_addr_to_totp_fd.find(conn_info.addr);
                if (g_obfs && totp_it != g_addr_to_totp_fd.end()) {
                    char enc_buf[buf_len + 300];
                    int enc_len = obfs_encode(g_obfs, pkt_out_arr[i], pkt_out_len[i],
                                              enc_buf, (int)sizeof(enc_buf), OBFS_TYPE_DATA);
                    if (enc_len > 0)
                        sendto(totp_it->second, enc_buf, (size_t)enc_len, 0,
                               (const struct sockaddr *)&conn_info.addr.inner,
                               conn_info.addr.get_len());
                } else {
                    int r2 = mud_send_mp(g_mud, pkt_out_arr[i], pkt_out_len[i]);
                    if (r2 < 0 && errno == EAGAIN)
                        enqueue_server_pending(pkt_out_arr[i], pkt_out_len[i]);
                }
            }
        }
        mud_send_flush(g_mud);
        return;
    } else {
        assert(0 == 1);
    }

    mylog(log_trace, "[server] fec output n=%d\n", out_n);

    for (int i = 0; i < out_n; i++) {
        /* Client connected via a TOTP port: obfs_encode then reply directly on the same TOTP socket */
        auto totp_it = g_addr_to_totp_fd.find(addr);
        if (g_obfs && totp_it != g_addr_to_totp_fd.end()) {
            char enc_buf[buf_len + 300];
            int enc_len = obfs_encode(g_obfs, out_arr[i], out_len[i],
                                      enc_buf, (int)sizeof(enc_buf), OBFS_TYPE_DATA);
            if (enc_len > 0) {
                int r = sendto(totp_it->second, enc_buf, (size_t)enc_len, 0,
                               (const struct sockaddr *)&addr.inner, addr.get_len());
                if (r < 0)
                    mylog(log_debug, "[server] totp sendto: %s\n", strerror(errno));
            }
        } else {
            int ret2 = mud_send_mp(g_mud, out_arr[i], out_len[i]);
            if (ret2 < 0) {
                if (errno == EAGAIN)
                    enqueue_server_pending(out_arr[i], out_len[i]);
                else
                    mylog(log_debug, "[server] mud_send failed: %s\n", strerror(errno));
            }
        }
    }
    (void)ret;
}

/* ────────────────────────────────────────────────────────────────
 * Process mud data received from a specific client address.
 *
 * data/data_len: already received via mud_recv (FEC packet).
 * src_addr: client address (from recvfrom peek).
 * ──────────────────────────────────────────────────────────────── */

static void process_mud_data(const address_t &src_addr, char *data, int data_len)
{
    /* Get or create per-client conn_info */
    if (!conn_manager.exist(const_cast<address_t&>(src_addr))) {
        if (conn_manager.mp.size() >= (size_t)max_conn_num) {
            mylog(log_warn, "[server] max_conn_num exceeded for %s\n",
                  const_cast<address_t&>(src_addr).get_str());
            return;
        }

        conn_info_t &ci = conn_manager.find_insert(const_cast<address_t&>(src_addr));
        ci.addr             = src_addr;
        ci.loop             = g_loop;
        ci.local_listen_fd  = -1;  /* not used on server for incoming data */

        ci.timer.data = &ci;
        ev_init(&ci.timer, conn_timer_cb);
        ev_timer_set(&ci.timer, 0, (double)timer_interval / 1000.0);
        ev_timer_start(g_loop, &ci.timer);

        ci.fec_encode_manager.set_data(&ci);
        ci.fec_encode_manager.set_loop_and_cb(g_loop, fec_encode_cb);
        ci.rnlc_encode_manager.set_data(&ci);
        ci.rnlc_encode_manager.set_loop_and_cb(g_loop, fec_encode_cb);

        mylog(log_info, "[server] new client %s\n",
              const_cast<address_t&>(src_addr).get_str());
    }

    conn_info_t &conn_info = conn_manager.find_insert(const_cast<address_t&>(src_addr));
    conn_info.update_active_time();

    if (!disable_mtu_warn && data_len >= mtu_warn) {
        mylog(log_warn, "[server] large mud packet len=%d from %s\n",
              data_len, const_cast<address_t&>(src_addr).get_str());
    }

    int out_n = 0;
    char **out_arr  = NULL;
    int  *out_len   = NULL;
    my_time_t *out_delay = NULL;

    from_fec_to_normal(conn_info, data, data_len, out_n, out_arr, out_len, out_delay);

    mylog(log_trace, "[server] fec decoded n=%d from %s\n", out_n,
          const_cast<address_t&>(src_addr).get_str());

    for (int i = 0; i < out_n; i++) {
        u32_t conv;
        char *new_data = NULL;
        int   new_len  = 0;
        if (get_conv(conv, out_arr[i], out_len[i], new_data, new_len) != 0) {
            mylog(log_debug, "[server] get_conv failed\n");
            continue;
        }

        if (!conn_info.conv_manager.s.is_conv_used(conv)) {
            if (conn_info.conv_manager.s.get_size() >= max_conv_num) {
                mylog(log_warn, "[server] max_conv_num exceeded\n");
                continue;
            }

            /* Create a new connected UDP socket to WireGuard server for this conv */
            int new_udp_fd = -1;
            int ret = new_connected_socket2(new_udp_fd, g_wg_addr,
                                            out_addr, out_interface);
            if (ret != 0) {
                mylog(log_warn, "[server][%s] new_connected_socket failed\n",
                      const_cast<address_t&>(src_addr).get_str());
                continue;
            }

            fd64_t fd64 = fd_manager.create(new_udp_fd);

            conn_info.conv_manager.s.insert_conv(conv, fd64);
            fd_manager.get_info(fd64).addr = src_addr;

            ev_io &io_watcher = fd_manager.get_info(fd64).io_watcher;
            io_watcher.u64  = fd64;
            io_watcher.data = &conn_info;

            ev_init(&io_watcher, wg_remote_cb);
            ev_io_set(&io_watcher, new_udp_fd, EV_READ);
            ev_io_start(conn_info.loop, &io_watcher);

            mylog(log_info, "[server][%s] new conv %x fd=%d fd64=%llu\n",
                  const_cast<address_t&>(src_addr).get_str(), conv, new_udp_fd, fd64);
        }

        conn_info.conv_manager.s.update_active_time(conv);
        fd64_t fd64 = conn_info.conv_manager.s.find_data_by_conv(conv);

        dest_t dest;
        dest.type       = type_fd64;
        dest.inner.fd64 = fd64;

        delay_send(out_delay[i], dest, new_data, new_len);
    }
}

/* ────────────────────────────────────────────────────────────────
 * libev callbacks
 * ──────────────────────────────────────────────────────────────── */

static void wg_remote_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &conn_info = *static_cast<conn_info_t *>(watcher->data);
    fd64_t fd64 = watcher->u64;
    data_from_wg_or_fec_timeout_or_conn_timer(conn_info, fd64, is_from_wg);
}

static void fec_encode_cb(struct ev_loop * /*loop*/, struct ev_timer *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &conn_info = *static_cast<conn_info_t *>(watcher->data);
    data_from_wg_or_fec_timeout_or_conn_timer(conn_info, 0, is_fec_timeout);
    mud_send_flush(g_mud);
}

static void conn_timer_cb(struct ev_loop * /*loop*/, struct ev_timer *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    conn_info_t &conn_info = *static_cast<conn_info_t *>(watcher->data);
    data_from_wg_or_fec_timeout_or_conn_timer(conn_info, 0, is_conn_timer);
}

/* ────────────────────────────────────────────────────────────────
 * Send builtin QUIC Server Initial response (default when --decoy unset)
 *
 * RFC 9000 §17.2.2 Long Header Initial, fixed 1200B.
 * SCID[0]=0xFF → Server Initial marker.
 * Looks like a normal QUIC server response to the prober.
 * ──────────────────────────────────────────────────────────────── */
static void probe_respond_builtin(int fd, address_t &src)
{
    if (g_obfs && g_obfs->mode == OBFS_MODE_TLS) {
        static const uint8_t close_notify[] = {
            0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00
        };
        sendto(fd, close_notify, sizeof(close_notify), 0,
               (struct sockaddr *)&src.inner, src.get_len());
    } else {
        static char buf[QUIC_INITIAL_SIZE + 256];
        int n = obfs_encode_initial(g_obfs, buf, sizeof(buf), 1);
        if (n <= 0) return;
        /* Append 0-255 random bytes: QUIC coalesced-packet area, varies size */
        int extra = rand() % 256;
        for (int i = n; i < n + extra; i++)
            buf[i] = (char)(rand() & 0xFF);
        sendto(fd, buf, (size_t)(n + extra), 0,
               (struct sockaddr *)&src.inner, src.get_len());
    }
}

/* ────────────────────────────────────────────────────────────────
 * TOTP socket management
 * ──────────────────────────────────────────────────────────────── */

static void server_totp_io_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int revents)
{
    assert(!(revents & EV_ERROR));
    totp_entry_t *e = static_cast<totp_entry_t *>(watcher->data);

    static char raw_buf[buf_len];
    static char dec_buf[buf_len];

    for (;;) {
        struct sockaddr_storage ss;
        socklen_t ssl = sizeof(ss);
        ssize_t rn = recvfrom(e->fd, raw_buf, sizeof(raw_buf), MSG_DONTWAIT,
                              (struct sockaddr *)&ss, &ssl);
        if (rn < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            mylog(log_warn, "[server] totp recvfrom: %s\n", strerror(errno));
            break;
        }

        if (!g_obfs) continue;

        uint8_t pkt_type = 0;
        int n = obfs_decode(g_obfs, raw_buf, (int)rn, dec_buf, sizeof(dec_buf), &pkt_type);
        if (n <= 0) {
            /* n<0: unknown format, n==0: HMAC auth failure — treated as prober */
            if (rn >= 1) {
                address_t src;
                src.from_sockaddr((struct sockaddr *)&ss, ssl);
                if (g_decoy_enabled) {
                    decoy_forward(src, e->fd, raw_buf, (int)rn);
                    mylog(log_debug, "[server] totp: probe from %s → decoy\n",
                          src.get_str());
                } else {
                    probe_respond_builtin(e->fd, src);
                    mylog(log_debug, "[server] totp: probe from %s → builtin-quic\n",
                          src.get_str());
                }
            }
            continue;
        }
        if (n < (int)SESSION_ID_LEN) {
            mylog(log_debug, "[server] totp: packet too short (%d)\n", n);
            continue;
        }

        address_t src_addr;
        src_addr.from_sockaddr((struct sockaddr *)&ss, ssl);

        /* Register this client's reply path as the TOTP socket */
        g_addr_to_totp_fd[src_addr] = e->fd;

        /* session_id routing (same as mud_io_cb) */
        uint64_t sid = 0;
        memcpy(&sid, dec_buf, SESSION_ID_LEN);

        address_t routing_addr;
        auto sit = g_session_to_addr.find(sid);
        if (sit == g_session_to_addr.end()) {
            g_session_to_addr[sid] = src_addr;
            routing_addr = src_addr;
            mylog(log_info, "[server] totp: new session %016llx from %s\n",
                  (unsigned long long)sid, src_addr.get_str());
        } else {
            routing_addr = sit->second;
            if (!(routing_addr == src_addr))
                mylog(log_debug, "[server] totp: session %016llx alt path %s\n",
                      (unsigned long long)sid, src_addr.get_str());
        }

        process_mud_data(routing_addr, dec_buf + SESSION_ID_LEN, n - SESSION_ID_LEN);
    }
}

static void server_add_totp_socket(struct ev_loop *loop, uint64_t slot)
{
    if (!g_obfs) return;
    uint16_t port = obfs_port_for_slot(g_obfs, slot);

    /* Avoid collision with the main listen port */
    uint16_t main_port = ntohs(local_addr.get_type() == AF_INET6
                               ? local_addr.inner.ipv6.sin6_port
                               : local_addr.inner.ipv4.sin_port);
    if (port == main_port) {
        mylog(log_info, "[server] totp: slot %llu port %u == main port, skip\n",
              (unsigned long long)slot, port);
        return;
    }

    /* Find an empty slot */
    totp_entry_t *e = NULL;
    for (int i = 0; i < SERVER_TOTP_MAX; i++) {
        if (!g_totp_entries[i].active) { e = &g_totp_entries[i]; break; }
    }
    if (!e) {
        mylog(log_warn, "[server] totp: no free entry (slot %llu port %u)\n",
              (unsigned long long)slot, port);
        return;
    }

    int family = (local_addr.get_type() == AF_INET6) ? AF_INET6 : AF_INET;
    int fd = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        mylog(log_warn, "[server] totp: socket(): %s\n", strerror(errno));
        return;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    int ret;
    if (family == AF_INET) {
        struct sockaddr_in sin = {};
        sin.sin_family      = AF_INET;
        sin.sin_addr.s_addr = htonl(INADDR_ANY);
        sin.sin_port        = htons(port);
        ret = bind(fd, (struct sockaddr *)&sin, sizeof(sin));
    } else {
        struct sockaddr_in6 sin6 = {};
        sin6.sin6_family = AF_INET6;
        sin6.sin6_addr   = in6addr_any;
        sin6.sin6_port   = htons(port);
        ret = bind(fd, (struct sockaddr *)&sin6, sizeof(sin6));
    }
    if (ret < 0) {
        mylog(log_warn, "[server] totp: bind port %u: %s\n", port, strerror(errno));
        close(fd);
        return;
    }

    setnonblocking(fd);

    e->slot         = slot;
    e->fd           = fd;
    e->active       = true;
    e->watcher.data = e;
    ev_io_init(&e->watcher, server_totp_io_cb, fd, EV_READ);
    ev_io_start(loop, &e->watcher);

    mylog(log_info, "[server] totp: listening port %u (slot %llu)\n",
          port, (unsigned long long)slot);
}

static void server_remove_totp_socket(uint64_t slot)
{
    for (int i = 0; i < SERVER_TOTP_MAX; i++) {
        totp_entry_t &e = g_totp_entries[i];
        if (!e.active || e.slot != slot) continue;

        uint16_t port = g_obfs ? obfs_port_for_slot(g_obfs, slot) : 0;

        ev_io_stop(g_loop, &e.watcher);

        /* Remove entries in g_addr_to_totp_fd that hold this fd */
        for (auto it = g_addr_to_totp_fd.begin(); it != g_addr_to_totp_fd.end(); ) {
            if (it->second == e.fd) it = g_addr_to_totp_fd.erase(it);
            else ++it;
        }

        close(e.fd);
        e.active = false;

        mylog(log_info, "[server] totp: closed port %u (slot %llu)\n",
              port, (unsigned long long)slot);
        return;
    }
}

static void server_update_totp_ports(struct ev_loop *loop)
{
    if (!g_obfs || !g_obfs->hop_interval) return;

    uint64_t new_slot = obfs_current_slot(g_obfs);
    if (new_slot == g_totp_cur_slot) return;

    mylog(log_info, "[server] totp: slot %llu → %llu\n",
          (unsigned long long)g_totp_cur_slot,
          (unsigned long long)new_slot);

    if (g_totp_cur_slot == (uint64_t)-1) {
        /* First run: previous slot (standby) + current slot */
        if (new_slot > 0) server_add_totp_socket(loop, new_slot - 1);
        server_add_totp_socket(loop, new_slot);
    } else {
        /* Slot switch: remove slot from 2 ago, add current slot */
        if (new_slot >= 2) server_remove_totp_socket(new_slot - 2);
        server_add_totp_socket(loop, new_slot);
    }

    g_totp_cur_slot = new_slot;
}

static void server_totp_timer_cb(struct ev_loop *loop, struct ev_timer * /*w*/, int /*revents*/)
{
    server_update_totp_ports(loop);
}

static void mud_io_cb(struct ev_loop * /*loop*/, struct ev_io * /*watcher*/, int revents)
{
    assert(!(revents & EV_ERROR));

    int mfd = mud_get_fd(g_mud);
    static char peek_buf[buf_len];
    static char recv_buf[buf_len];

    for (;;) {
        /* Peek to get source address */
        struct sockaddr_storage ss;
        socklen_t ssl = sizeof(ss);
        ssize_t pn = recvfrom(mfd, peek_buf, sizeof(peek_buf),
                              MSG_PEEK | MSG_DONTWAIT,
                              (struct sockaddr *)&ss, &ssl);
        if (pn < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            mylog(log_warn, "[server] recvfrom peek: %s\n", strerror(errno));
            break;
        }

        address_t src_addr;
        src_addr.from_sockaddr((struct sockaddr *)&ss, ssl);

        /* Consume via mud_recv — this applies obfs decode */
        struct mud_errors _e0;
        mud_get_errors(g_mud, &_e0);
        int n = mud_recv(g_mud, recv_buf, sizeof(recv_buf));
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            /* HMAC auth failure = external prober (GFW active probing, etc.).
             *
             * Determine probe type from the first byte of peek_buf:
             *   0x16 → TLS Handshake (ClientHello)
             *   0x17 → TLS Application Data
             *   0x15 → TLS Alert
             *   0x14 → TLS ChangeCipherSpec
             *   0xC0+ → QUIC Long Header (Initial)
             *   0x40-0x7F → QUIC Short Header
             *
             * In all cases respond with a TLS close_notify Alert.
             *   → prober's view: "a TLS server that closed the connection" = normal behavior
             *   → GFW: confirms a TLS server exists on port 443 → avoids blocking
             *
             * TCP/443 probes are handled by nginx/caddy independently of multi-fec.
             * (TCP and UDP are independent in the kernel — same port can be bound simultaneously) */
            if (pn >= 1) {
                if (g_decoy_enabled) {
                    decoy_forward(src_addr, mfd, peek_buf, (int)pn);
                    mylog(log_debug, "[server] probe from %s (0x%02x) → decoy\n",
                          src_addr.get_str(), (unsigned char)peek_buf[0]);
                } else {
                    probe_respond_builtin(mfd, src_addr);
                    mylog(log_debug, "[server] probe from %s (0x%02x) → builtin-quic\n",
                          src_addr.get_str(), (unsigned char)peek_buf[0]);
                }
            }
            break;
        }
        if (n == 0) {
            struct mud_errors _e1;
            mud_get_errors(g_mud, &_e1);
            bool auth_fail = (_e1.auth.count > _e0.auth.count);
            const char *_why =
                auth_fail                                       ? "auth-fail" :
                (_e1.clocksync.count > _e0.clocksync.count)    ? "clocksync" :
                "probe";
            mylog(log_trace, "[server] mud_recv=0 from %s: %s\n",
                  src_addr.get_str(), _why);
            if (auth_fail && pn >= 1) {
                if (g_decoy_enabled)
                    decoy_forward(src_addr, mfd, peek_buf, (int)pn);
                else
                    probe_respond_builtin(mfd, src_addr);
            }
            continue;
        }

        /* Extract session_id (first SESSION_ID_LEN bytes of mud payload).
         * Map to a canonical address so packets arriving via different POPs
         * all feed into the same conn_info / FEC decoder. */
        if (n < (int)SESSION_ID_LEN) {
            mylog(log_debug, "[server] packet too short for session_id (%d)\n", n);
            continue;
        }
        uint64_t sid = 0;
        memcpy(&sid, recv_buf, SESSION_ID_LEN);

        address_t routing_addr;
        auto sit = g_session_to_addr.find(sid);
        if (sit == g_session_to_addr.end()) {
            g_session_to_addr[sid] = src_addr;
            routing_addr = src_addr;
            mylog(log_info, "[server] new session %016llx from %s\n",
                  (unsigned long long)sid, src_addr.get_str());
        } else {
            routing_addr = sit->second;
            if (!(routing_addr == src_addr)) {
                mylog(log_debug, "[server] session %016llx: alt path %s\n",
                      (unsigned long long)sid, src_addr.get_str());
            }
        }

        /* Strip session_id before FEC processing */
        process_mud_data(routing_addr,
                         recv_buf + SESSION_ID_LEN,
                         n - SESSION_ID_LEN);
    }

    /* Drain items left in the recvmmsg queue.
     * Even after the MSG_PEEK loop ends by exhausting the socket buffer,
     * unprocessed packets received in the recvmmsg batch may remain.
     * They are already authenticated, so do session_id routing only, no probe handling. */
    while (mud_recv_pending(g_mud)) {
        int n2 = mud_recv(g_mud, recv_buf, sizeof(recv_buf));
        if (n2 < 0) break;
        if (n2 == 0) continue;
        if (n2 < (int)SESSION_ID_LEN) continue;

        uint64_t sid2 = 0;
        memcpy(&sid2, recv_buf, SESSION_ID_LEN);
        auto sit2 = g_session_to_addr.find(sid2);
        if (sit2 == g_session_to_addr.end()) continue; /* new session handled on next event */

        process_mud_data(sit2->second,
                         recv_buf + SESSION_ID_LEN,
                         n2 - SESSION_ID_LEN);
    }
}

static void mud_update_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/, int /*revents*/)
{
    mud_update(g_mud);
    flush_server_pending();
}

static void global_timer_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/, int /*revents*/)
{
    conn_manager.clear_inactive();
}

static void delay_manager_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/, int /*revents*/)
{
    /* nothing */
}

static void prepare_cb(struct ev_loop * /*loop*/, struct ev_prepare * /*watcher*/, int /*revents*/)
{
    delay_manager.check();
}

/* ────────────────────────────────────────────────────────────────
 * mf_server_event_loop()
 * ──────────────────────────────────────────────────────────────── */

void mf_server_event_loop(struct mud *mud, const struct obfs_ctx *obfs,
                          int /*unused*/, address_t decoy_addr)
{
    g_mud  = mud;
    g_obfs = obfs;

    if (decoy_addr.is_vaild()) {
        g_decoy_upstream = decoy_addr;
        g_decoy_enabled  = true;
        mylog(log_info, "[server] decoy: forwarding probes to %s\n",
              decoy_addr.get_str());
    }

    mylog(log_info, "[server] starting event loop\n");

    struct ev_loop *loop = ev_default_loop(0);
    assert(loop != NULL);
    g_loop = loop;

    /* ev_io: mud fd for inbound */
    struct ev_io mud_watcher;
    mud_watcher.data = NULL;
    ev_io_init(&mud_watcher, mud_io_cb, mud_get_fd(mud), EV_READ);
    ev_io_start(loop, &mud_watcher);

    /* ev_timer: mud_update every 100ms */
    struct ev_timer mud_timer;
    ev_timer_init(&mud_timer, mud_update_cb, 0.02, 0.02);
    ev_timer_start(loop, &mud_timer);

    /* ev_timer: global connection cleanup */
    struct ev_timer global_timer;
    ev_timer_init(&global_timer, global_timer_cb,
                  (double)conn_clear_interval / 1000.0,
                  (double)conn_clear_interval / 1000.0);
    ev_timer_start(loop, &global_timer);

    /* delay manager */
    delay_manager.set_loop_and_cb(loop, delay_manager_cb);

    /* ev_prepare: delay_manager dispatch */
    ev_prepare prepare_watcher;
    ev_init(&prepare_watcher, prepare_cb);
    ev_prepare_start(loop, &prepare_watcher);

    /* TOTP port-hopping timer (only when hop_interval > 0) */
    struct ev_timer totp_timer;
    if (g_obfs && g_obfs->hop_interval > 0) {
        memset(g_totp_entries, 0, sizeof(g_totp_entries));
        g_totp_cur_slot = (uint64_t)-1;
        server_update_totp_ports(loop);

        double iv = (double)g_obfs->hop_interval / 2.0;
        if (iv < 1.0) iv = 1.0;
        ev_timer_init(&totp_timer, server_totp_timer_cb, iv, iv);
        ev_timer_start(loop, &totp_timer);
        mylog(log_info, "[server] totp: hop_interval=%us, check_interval=%.0fs\n",
              g_obfs->hop_interval, iv);
    }

    /* decoy cleanup timer: remove idle sessions every 10s */
    struct ev_timer decoy_timer;
    if (g_decoy_enabled) {
        ev_timer_init(&decoy_timer, decoy_cleanup_cb, 10.0, 10.0);
        ev_timer_start(loop, &decoy_timer);
    }

    mylog(log_info, "[server] listening, forwarding to WireGuard at %s\n",
          g_wg_addr.get_str());

    ev_run(loop, 0);

    mylog(log_warn, "[server] ev_run returned\n");
}
