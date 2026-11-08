/*
 * mf_relay.cpp — multi-fec relay event loop (POP mode)
 *
 * Transparent stateful UDP forwarder.
 *
 *   client ──[listen_fd recvfrom]──▶ relay ──[upstream_fd send]──▶ server
 *   client ◀──[listen_fd sendto]── relay ◀──[upstream_fd recv]── server
 *
 * obfs (optional):
 *   If --obfs / -k is supplied, the relay verifies the HMAC token before
 *   forwarding.  Packets that fail verification receive a TLS close_notify
 *   alert and are silently dropped — they never reach the server.
 *   If no key is supplied, the relay is fully transparent (original behaviour).
 *
 *   Either way the relay forwards the *original raw bytes* to the server;
 *   it does not re-encode after decoding.  The server decodes once, as usual.
 *
 * Per-client state:
 *   Each unique (src_ip, src_port) gets its own upstream UDP socket.
 *   The socket is connected to --upstream, so the server sees distinct
 *   (relay_ip, ephemeral_port) per client.
 */

#include "tunnel.h"
#include "mf_common.h"
#include "mf_probe.h"
#include "mf_logfp.h"
#include "obfs.h"

#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <string>
#include <vector>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <string.h>
#include <assert.h>

/* ────────────────────────────────────────────────────────────────
 * Forward declaration
 * ──────────────────────────────────────────────────────────────── */

extern "C" void mf_relay_event_loop(address_t &listen_addr,
                                    address_t &upstream_addr,
                                    const struct obfs_ctx *obfs,
                                    address_t decoy_addr);

/* ────────────────────────────────────────────────────────────────
 * Module-level state
 * ──────────────────────────────────────────────────────────────── */

static int                    g_listen_fd   = -1;
static address_t              g_upstream;           /* --upstream target */
static struct ev_loop        *g_loop        = NULL;
static const struct obfs_ctx *g_obfs        = NULL; /* NULL = transparent */
static struct obfs_ctx        g_builtin_ctx;        /* for builtin QUIC Initial response */

#define RELAY_SESSION_TIMEOUT_MS  60000     /* 60 s idle → evict */

/* 동시 세션 상한.
 *
 * 세션 하나가 upstream 소켓 + ev_io watcher 를 하나씩 잡으므로 세션 수가 곧 FD 수다.
 * idle 만료(60초)만으로는 부족했다 — 소스 포트를 계속 바꿔가며 보내면 만료가 오기
 * 전에 FD 가 고갈된다. 특히 -k / --route 없이 --upstream 만 준 투명 중계 모드에서는
 * HMAC 검증이 없어(find_route() 가 g_obfs==NULL 을 그대로 반환) 아무나 이걸 할 수
 * 있다. 서버는 v1.0.3 에서 SESSION_MAX + LRU 를 갖췄는데 릴레이만 빠져 있었다.
 *
 * 값은 서버 SESSION_MAX(max_conn_num*4) 와 같게 맞췄다. 기본 max_conn_num=200 이면
 * 800 세션 = 800 FD 로, 기본 RLIMIT_NOFILE(1024) 안에 리슨/타이머/decoy 몫을 남긴다. */
#define RELAY_SESSION_MAX  (max_conn_num * 4)

extern int report_interval;   /* connection.cpp — --report seconds (0 = off) */

/* ────────────────────────────────────────────────────────────────
 * Traffic accounting
 *
 * The relay had no traffic counters (--report was ignored). These feed a
 * periodic report so operators and a journald exporter can see throughput and
 * session churn without tcpdump/nft. Only the two forwarding choke points and
 * the session-lifecycle sites touch them; the periodic timer is the only place
 * that logs, so an attack cannot flood the log (per-event logs are debug).
 *
 * Clients are identified in logs by a one-way fingerprint (mf_logfp), never a
 * raw IP, so logs shipped off-host carry no client addresses.
 * ──────────────────────────────────────────────────────────────── */
struct relay_traffic_t {
    uint64_t up_bytes,   up_pkts;     /* client → server */
    uint64_t down_bytes, down_pkts;   /* server → client */
    uint64_t sess_new, sess_expired, sess_evicted, sess_fulldrop;
    uint64_t probe, decoy_bytes;      /* HMAC-failed (prober) packets / bytes to decoy */
};
static struct relay_traffic_t g_tr;        /* cumulative since start */
static struct relay_traffic_t g_tr_logged; /* snapshot at last report */
static my_time_t              g_report_last_ms = 0;

/* ────────────────────────────────────────────────────────────────
 * Decoy session management (--decoy ip:port)
 *
 * Same structure as the server: forward HMAC-failed packets to a local
 * QUIC/HTTPS server and relay its response back to the prober.
 * Separate UDP socket per prober address, auto-removed after 10s idle.
 * ──────────────────────────────────────────────────────────────── */

struct decoy_sess_t {
    address_t prober_addr;
    int       decoy_fd;
    ev_io     watcher;
    time_t    last_active;
};

static address_t                                g_decoy_addr;
static bool                                     g_decoy_enabled = false;
static unordered_map<address_t, decoy_sess_t *> g_decoy_map;

static void
decoy_io_cb(struct ev_loop * /*loop*/, struct ev_io *w, int /*revents*/)
{
    decoy_sess_t *s = static_cast<decoy_sess_t *>(w->data);
    char buf[buf_len];
    for (;;) {
        ssize_t n = recv(s->decoy_fd, buf, sizeof(buf), MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            mylog(log_debug, "[relay/decoy] recv: %s\n", strerror(errno));
            break;
        }
        if (n == 0) break;
        s->last_active = time(NULL);
        sendto(g_listen_fd, buf, (size_t)n, 0,
               (struct sockaddr *)&s->prober_addr.inner, s->prober_addr.get_len());
        mylog(log_debug, "[relay/decoy] → prober %s %zd bytes\n",
              s->prober_addr.get_str(), n);
    }
}

/* Each decoy session holds a socket. Probers' source addresses are free to
 * spoof, so without a cap a flood of them exhausts FDs (fixed in 1.4.2).
 * Make room by dropping idle sessions first, then the least recently active. */
static bool
decoy_make_room()
{
    if (g_decoy_map.size() < (size_t)DECOY_SESSION_MAX) return true;
    time_t now = time(NULL);
    auto victim = g_decoy_map.end();
    for (auto it = g_decoy_map.begin(); it != g_decoy_map.end(); ++it) {
        if (victim == g_decoy_map.end() ||
            it->second->last_active < victim->second->last_active)
            victim = it;
        if (now - it->second->last_active > 10) { victim = it; break; }
    }
    if (victim == g_decoy_map.end()) return false;
    decoy_sess_t *s = victim->second;
    ev_io_stop(g_loop, &s->watcher);
    close(s->decoy_fd);
    delete s;
    g_decoy_map.erase(victim);
    static time_t last_warn = 0;
    if (now - last_warn >= 60) {
        last_warn = now;
        mylog(log_warn, "[relay/decoy] session table full (%d), evicting oldest\n", DECOY_SESSION_MAX);
    }
    return true;
}

static decoy_sess_t *
decoy_get_or_create(const address_t &prober)
{
    auto it = g_decoy_map.find(const_cast<address_t &>(prober));
    if (it != g_decoy_map.end()) {
        it->second->last_active = time(NULL);
        return it->second;
    }

    if (!decoy_make_room()) return NULL;

    int family = (g_decoy_addr.get_type() == AF_INET6) ? AF_INET6 : AF_INET;
    int dfd = socket(family, SOCK_DGRAM, IPPROTO_UDP);
    if (dfd < 0) {
        mylog(log_warn, "[relay/decoy] socket: %s\n", strerror(errno));
        return NULL;
    }
    setnonblocking(dfd);

    int r = connect(dfd,
                    (family == AF_INET)
                        ? (struct sockaddr *)&g_decoy_addr.inner.ipv4
                        : (struct sockaddr *)&g_decoy_addr.inner.ipv6,
                    (family == AF_INET) ? (socklen_t)sizeof(struct sockaddr_in)
                                        : (socklen_t)sizeof(struct sockaddr_in6));
    if (r < 0) {
        mylog(log_warn, "[relay/decoy] connect: %s\n", strerror(errno));
        close(dfd);
        return NULL;
    }

    decoy_sess_t *s = new decoy_sess_t;
    s->prober_addr  = prober;
    s->decoy_fd     = dfd;
    s->last_active  = time(NULL);
    s->watcher.data = s;
    ev_io_init(&s->watcher, decoy_io_cb, dfd, EV_READ);
    ev_io_start(g_loop, &s->watcher);

    g_decoy_map[const_cast<address_t &>(prober)] = s;
    mylog(log_info, "[relay/decoy] new session prober=%s\n",
          const_cast<address_t &>(prober).get_str());
    return s;
}

static void
decoy_forward(const address_t &prober, const void *pkt, int pkt_len)
{
    g_tr.probe++;
    g_tr.decoy_bytes += (uint64_t)pkt_len;
    decoy_sess_t *s = decoy_get_or_create(prober);
    if (!s) return;
    ssize_t n = send(s->decoy_fd, pkt, (size_t)pkt_len, 0);
    if (n < 0)
        mylog(log_debug, "[relay/decoy] send: %s\n", strerror(errno));
    else
        mylog(log_debug, "[relay/decoy] ← prober %s %d bytes forwarded\n",
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
            mylog(log_debug, "[relay/decoy] evict prober=%s\n",
                  s->prober_addr.get_str());
            delete s;
            it = g_decoy_map.erase(it);
        } else {
            ++it;
        }
    }
}

/* ────────────────────────────────────────────────────────────────
 * Per-client relay session
 * ──────────────────────────────────────────────────────────────── */

struct relay_session_t {
    address_t              client_addr;
    int                    upstream_fd;
    ev_io                  upstream_watcher;
    my_time_t              last_active;
    const struct obfs_ctx *route_obfs;  /* obfs of the key matched for this session. NULL=transparent */
    uint64_t               up_bytes, up_pkts;     /* per-session, client → server */
    uint64_t               down_bytes, down_pkts; /* per-session, server → client */
};

/* Two lookup tables — O(1) in both directions */
static unordered_map<address_t, relay_session_t *> g_addr_to_sess;
static unordered_map<int,       relay_session_t *> g_fd_to_sess;

/* ────────────────────────────────────────────────────────────────
 * Helper: destroy a session and free resources
 * ──────────────────────────────────────────────────────────────── */

static void delete_session(relay_session_t *sess)
{
    ev_io_stop(g_loop, &sess->upstream_watcher);
    close(sess->upstream_fd);
    g_fd_to_sess.erase(sess->upstream_fd);
    g_addr_to_sess.erase(sess->client_addr);

    if (log_level >= log_debug) {
        char fp[MF_LOG_FP_LEN];
        mf_client_fp(sess->client_addr, fp, sizeof(fp));
        mylog(log_debug, "[relay] session removed: client=%s fd=%d up=%lluB down=%lluB\n",
              fp, sess->upstream_fd,
              (unsigned long long)sess->up_bytes, (unsigned long long)sess->down_bytes);
    }
    delete sess;
}

/* ────────────────────────────────────────────────────────────────
 * Helper: drop sessions idle past RELAY_SESSION_TIMEOUT_MS
 *
 * No unit conversion: get_current_time() and last_active are both in
 * milliseconds, and so is the timeout. The stray ×1000 that used to be here
 * stretched the 60 s idle limit to ~16.7 hours, pinning one upstream socket and
 * watcher per client address for that long.
 * ──────────────────────────────────────────────────────────────── */

static size_t session_sweep(my_time_t now)
{
    std::vector<relay_session_t *> to_del;

    for (auto &kv : g_fd_to_sess) {
        relay_session_t *s = kv.second;
        if (now - s->last_active > (my_time_t)RELAY_SESSION_TIMEOUT_MS)
            to_del.push_back(s);
    }
    for (relay_session_t *s : to_del)
        delete_session(s);

    g_tr.sess_expired += to_del.size();
    return to_del.size();
}

/* ────────────────────────────────────────────────────────────────
 * Helper: make room for one more session
 *
 * Sweep first so a burst that merely outlived its idle window is reclaimed
 * without disturbing live sessions; only if that is not enough evict the least
 * recently active one, so a flood cannot starve an established client.
 * Returns false when no slot could be freed — caller drops the packet.
 * ──────────────────────────────────────────────────────────────── */

static bool session_reserve_slot(my_time_t now)
{
    if (g_addr_to_sess.size() < (size_t)RELAY_SESSION_MAX) return true;

    session_sweep(now);
    if (g_addr_to_sess.size() < (size_t)RELAY_SESSION_MAX) return true;

    relay_session_t *lru = NULL;
    for (auto &kv : g_fd_to_sess) {
        if (lru == NULL || kv.second->last_active < lru->last_active)
            lru = kv.second;
    }
    if (lru == NULL) return false;

    g_tr.sess_evicted++;
    mylog(log_debug, "[relay] session table full (%zu), evicting LRU\n",
          g_addr_to_sess.size());
    delete_session(lru);
    return true;
}

/* ────────────────────────────────────────────────────────────────
 * Helper: create a non-blocking UDP socket connected to upstream
 * ──────────────────────────────────────────────────────────────── */

static int new_upstream_fd(address_t &remote, const route_entry_t *route)
{
    int fd = socket(remote.get_type(), SOCK_DGRAM, 0);
    if (fd < 0) {
        mylog(log_warn, "[relay] socket(): %s\n", strerror(errno));
        return -1;
    }

    /* --upstream-local: pin the source IP. Without this the kernel picks the
     * route-preferred source, so every relay instance on a host leaves from the
     * same address regardless of which IP its listen socket is bound to.
     * Port stays 0 (ephemeral) — from_str_ip_only() zeroes it and the CLI
     * rejects an explicit port, since there is one such socket per session. */
    /* v1.4.0: a route line's own "local" wins over --upstream-local */
    address_t src = g_upstream_local;
    if (route) {
        address_t rl = route->local;   /* address_t methods are not const-qualified */
        if (rl.is_vaild()) src = rl;
    }
    if (src.is_vaild()) {
        if (src.get_type() != remote.get_type()) {
            mylog(log_warn, "[relay] upstream source %s family differs from upstream %s — not bound\n",
                  src.get_str(), remote.get_str());
        } else if (bind(fd, (struct sockaddr *)&src.inner, src.get_len()) < 0) {
            /* Fatal for this session: the caller asked for a specific source
             * address, and falling back to another one would silently defeat it. */
            mylog(log_warn, "[relay] bind upstream source %s: %s\n",
                  src.get_str(), strerror(errno));
            close(fd);
            return -1;
        }
    }

    /* v1.4.0 route "via <if>": pin the egress interface. The source address alone
     * does not choose it — Linux routes by destination (DESIGN-1.4.0 §6-1). One
     * socket per session makes this a plain per-socket option, unlike mud. */
    if (route && route->ifname[0] &&
        setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, route->ifname, strlen(route->ifname)) < 0) {
        mylog(log_warn, "[relay] SO_BINDTODEVICE %s: %s\n", route->ifname, strerror(errno));
        close(fd);
        return -1;
    }

    /* --sock-buf: before v1.3.5 relay mode ignored it, and these per-session
     * sockets ran on rmem_default (208 KB) — the first place drops showed up
     * under load (2026-10-05). Warn once on a cap; this runs per session. */
    if (g_sock_buf > 0) {
        static bool warned = false;
        int rcv_kb = 0, snd_kb = 0;
        int r = mf_set_sock_buf(fd, g_sock_buf, &rcv_kb, &snd_kb);
        if (r != 0 && !warned) {
            warned = true;
            if (r < 0)
                mylog(log_warn, "[relay] upstream sock-buf setsockopt failed: %s\n", strerror(errno));
            else
                mylog(log_warn, "[relay] upstream sock-buf=%d kB capped at rcv=%d snd=%d kB — "
                      "raise net.core.rmem_max/wmem_max or run with CAP_NET_ADMIN\n",
                      g_sock_buf, rcv_kb, snd_kb);
        }
    }

    if (connect(fd, (struct sockaddr *)&remote.inner, remote.get_len()) < 0) {
        mylog(log_warn, "[relay] connect upstream: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    setnonblocking(fd);
    return fd;
}

/* ────────────────────────────────────────────────────────────────
 * Callback: data arrived from upstream server → forward to client
 * ──────────────────────────────────────────────────────────────── */

static void upstream_read_cb(struct ev_loop * /*loop*/, struct ev_io *watcher,
                             int revents)
{
    assert(!(revents & EV_ERROR));
    relay_session_t *sess = static_cast<relay_session_t *>(watcher->data);
    static char buf[buf_len];

    for (;;) {
        int n = recv(sess->upstream_fd, buf, sizeof(buf), 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            mylog(log_debug, "[relay] upstream recv: %s\n", strerror(errno));
            break;
        }
        if (n == 0) break;

        sess->last_active = get_current_time();

        sendto(g_listen_fd, buf, n, 0,
               (struct sockaddr *)&sess->client_addr.inner,
               sess->client_addr.get_len());

        sess->down_bytes += (uint64_t)n; sess->down_pkts++;
        g_tr.down_bytes  += (uint64_t)n; g_tr.down_pkts++;

        mylog(log_trace, "[relay] ← upstream %d bytes to %s\n",
              n, sess->client_addr.get_str());
    }
}

/* ────────────────────────────────────────────────────────────────
 * Builtin reply on HMAC failure (no --decoy): QUIC Server Initial with a
 * random DCID, or TLS close_notify. Size floor and rate limits: mf_probe.cpp.
 * ──────────────────────────────────────────────────────────────── */

static void probe_respond_builtin(address_t &src, int req_len)
{
    g_tr.probe++;
    probe_reply(g_listen_fd, src, req_len, g_builtin_ctx.mode);
}

/* ────────────────────────────────────────────────────────────────
 * Callback: data arrived from client → forward to upstream
 * ──────────────────────────────────────────────────────────────── */

/*
 * Determine the upstream address and obfs context for a new session.
 *
 * g_routes empty → single-upstream mode (legacy behavior)
 *   upstream = g_upstream, obfs = g_obfs
 *
 * g_routes present → key-routing mode
 *   Try each route's HMAC in order. Use the first successful route.
 *   All fail → upstream = NULL (close_notify response)
 */
static const struct obfs_ctx *find_route(const char *buf, int n,
                                         address_t &upstream_out,
                                         const route_entry_t **route_out)
{
    *route_out = NULL;
    static char decoded[buf_len];

    if (g_routes.empty()) {
        /* single-upstream mode */
        if (g_obfs != NULL) {
            int plen = obfs_decode(g_obfs, buf, n,
                                   decoded, (int)sizeof(decoded), NULL);
            if (plen == 0 || (plen < 0 && plen != OBFS_DECODE_INITIAL))
                return NULL;  /* HMAC failure */
        }
        upstream_out = g_upstream;
        return g_obfs;  /* NULL means transparent mode */
    }

    /* key routing: try HMAC in order */
    for (const route_entry_t &route : g_routes) {
        int plen = obfs_decode(&route.obfs, buf, n,
                               decoded, (int)sizeof(decoded), NULL);
        if (plen > 0 || plen == OBFS_DECODE_INITIAL) {
            upstream_out = route.upstream_addr;
            *route_out   = &route;
            return &route.obfs;
        }
    }
    return NULL;  /* no key matched */
}

static void listen_read_cb(struct ev_loop * /*loop*/, struct ev_io * /*watcher*/,
                           int revents)
{
    assert(!(revents & EV_ERROR));
    static char buf[buf_len];

    for (;;) {
        address_t::storage_t ss;
        socklen_t ssl = sizeof(ss);

        int n = recvfrom(g_listen_fd, buf, sizeof(buf), MSG_DONTWAIT,
                         (struct sockaddr *)&ss, &ssl);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            mylog(log_debug, "[relay] listen recvfrom: %s\n", strerror(errno));
            break;
        }
        if (n == 0) break;

        address_t src;
        src.from_sockaddr((struct sockaddr *)&ss, ssl);

        relay_session_t *sess;
        auto it = g_addr_to_sess.find(src);

        if (it != g_addr_to_sess.end()) {
            /* ── existing session: re-verify HMAC with stored obfs ── */
            sess = it->second;
            if (sess->route_obfs != NULL) {
                static char decoded[buf_len];
                int plen = obfs_decode(sess->route_obfs, buf, n,
                                       decoded, (int)sizeof(decoded), NULL);
                if (plen == 0 || (plen < 0 && plen != OBFS_DECODE_INITIAL)) {
                    if (g_decoy_enabled)
                        decoy_forward(src, buf, n);
                    else
                        probe_respond_builtin(src, n);
                    mylog(log_debug, "[relay] HMAC fail (existing session) from %s\n",
                          src.get_str());
                    continue;
                }
            }
        } else {
            /* ── new session: determine upstream via route lookup ── */
            address_t upstream;
            const route_entry_t *matched_route = NULL;
            const struct obfs_ctx *matched_obfs = find_route(buf, n, upstream, &matched_route);

            if (matched_obfs == NULL && !g_routes.empty()) {
                /* no match in key-routing mode */
                if (g_decoy_enabled)
                    decoy_forward(src, buf, n);
                else
                    probe_respond_builtin(src, n);
                mylog(log_debug, "[relay] no route matched from %s → %s\n",
                      src.get_str(), g_decoy_enabled ? "decoy" : "builtin-quic");
                continue;
            }
            if (matched_obfs == NULL && g_obfs != NULL) {
                /* HMAC failure in single-key mode */
                if (g_decoy_enabled)
                    decoy_forward(src, buf, n);
                else
                    probe_respond_builtin(src, n);
                mylog(log_debug, "[relay] HMAC fail from %s → %s\n",
                      src.get_str(), g_decoy_enabled ? "decoy" : "builtin-quic");
                continue;
            }

            /* Cap the table before allocating the socket, not after: the point
             * of the limit is to never hold more than RELAY_SESSION_MAX FDs. */
            if (!session_reserve_slot(get_current_time())) {
                g_tr.sess_fulldrop++;   /* surfaced in the periodic report, not per-drop (flood-safe) */
                continue;
            }

            int ufd = new_upstream_fd(upstream, matched_route);
            if (ufd < 0) continue;

            sess               = new relay_session_t;
            sess->client_addr  = src;
            sess->upstream_fd  = ufd;
            sess->last_active  = get_current_time();
            sess->route_obfs   = matched_obfs;
            sess->up_bytes = sess->up_pkts = sess->down_bytes = sess->down_pkts = 0;

            sess->upstream_watcher.data = sess;
            ev_io_init(&sess->upstream_watcher, upstream_read_cb, ufd, EV_READ);
            ev_io_start(g_loop, &sess->upstream_watcher);

            g_addr_to_sess[src] = sess;
            g_fd_to_sess[ufd]   = sess;

            g_tr.sess_new++;
            if (log_level >= log_debug) {
                char fp[MF_LOG_FP_LEN];
                mf_client_fp(src, fp, sizeof(fp));
                mylog(log_debug, "[relay] new session: client=%s upstream=%s fd=%d\n",
                      fp, upstream.get_str(), ufd);
            }
        }

        sess->last_active = get_current_time();
        send(sess->upstream_fd, buf, n, 0);

        sess->up_bytes += (uint64_t)n; sess->up_pkts++;
        g_tr.up_bytes  += (uint64_t)n; g_tr.up_pkts++;

        mylog(log_trace, "[relay] → upstream %d bytes from %s\n",
              n, src.get_str());
    }
}

/* ────────────────────────────────────────────────────────────────
 * Callback: periodic session cleanup
 * ──────────────────────────────────────────────────────────────── */

static void cleanup_cb(struct ev_loop * /*loop*/, struct ev_timer * /*watcher*/,
                       int /*revents*/)
{
    size_t n = session_sweep(get_current_time());

    if (n != 0)
        mylog(log_debug, "[relay] cleanup: removed %zu stale sessions\n", n);
}

/* ────────────────────────────────────────────────────────────────
 * Periodic traffic report (driven by --report; relay used to ignore it)
 *
 * This is the ONLY place traffic is logged. Aggregate totals (no IP) go at
 * info; per-session detail (fingerprint, capped at top-N by bytes) goes at
 * debug. Per-event logs were demoted to debug/counters, so no attack pattern
 * can flood the log.
 * ──────────────────────────────────────────────────────────────── */

static void human_bytes(uint64_t b, char *out, size_t n)
{
    static const char *u[] = { "B", "KB", "MB", "GB", "TB" };
    double v = (double)b; int i = 0;
    while (v >= 1024.0 && i < 4) { v /= 1024.0; i++; }
    snprintf(out, n, "%.1f%s", v, u[i]);
}

static void report_cb(struct ev_loop * /*loop*/, struct ev_timer * /*w*/, int /*revents*/)
{
    if (report_interval <= 0) return;

    my_time_t now = get_current_time();
    double period_s = g_report_last_ms ? (double)(now - g_report_last_ms) / 1000.0
                                       : (double)report_interval;
    if (period_s < 0.001) period_s = report_interval;
    g_report_last_ms = now;

    uint64_t up_b  = g_tr.up_bytes   - g_tr_logged.up_bytes;
    uint64_t up_p  = g_tr.up_pkts    - g_tr_logged.up_pkts;
    uint64_t dn_b  = g_tr.down_bytes - g_tr_logged.down_bytes;
    uint64_t dn_p  = g_tr.down_pkts  - g_tr_logged.down_pkts;
    uint64_t s_new = g_tr.sess_new      - g_tr_logged.sess_new;
    uint64_t s_exp = g_tr.sess_expired  - g_tr_logged.sess_expired;
    uint64_t s_evi = g_tr.sess_evicted  - g_tr_logged.sess_evicted;
    uint64_t s_drp = g_tr.sess_fulldrop - g_tr_logged.sess_fulldrop;
    uint64_t prb   = g_tr.probe       - g_tr_logged.probe;
    uint64_t dcy   = g_tr.decoy_bytes - g_tr_logged.decoy_bytes;
    g_tr_logged = g_tr;

    /* distinct clients this instant, by fingerprint (non-identifying count) */
    std::unordered_set<std::string> uniq;
    for (auto &kv : g_addr_to_sess) {
        char fp[MF_LOG_FP_LEN];
        mf_client_fp(kv.second->client_addr, fp, sizeof(fp));
        uniq.insert(fp);
    }

    char ub[24], db[24], yb[24];
    human_bytes(up_b, ub, sizeof(ub));
    human_bytes(dn_b, db, sizeof(db));
    human_bytes(dcy, yb, sizeof(yb));

    mylog(log_info, "[relay][report] period=%.0fs up=%s/%llu down=%s/%llu "
                    "rate up=%.1f down=%.1f Mbps live=%zu uniq=%zu "
                    "new=%llu expired=%llu evicted=%llu probe=%llu decoy=%s drop(full)=%llu\n",
          period_s, ub, (unsigned long long)up_p, db, (unsigned long long)dn_p,
          up_b * 8.0 / period_s / 1e6, dn_b * 8.0 / period_s / 1e6,
          g_addr_to_sess.size(), uniq.size(),
          (unsigned long long)s_new, (unsigned long long)s_exp,
          (unsigned long long)s_evi, (unsigned long long)prb, yb,
          (unsigned long long)s_drp);

    if (log_level >= log_debug && !g_addr_to_sess.empty()) {
        std::vector<relay_session_t *> v;
        v.reserve(g_addr_to_sess.size());
        for (auto &kv : g_addr_to_sess) v.push_back(kv.second);
        std::sort(v.begin(), v.end(), [](relay_session_t *a, relay_session_t *b) {
            return (a->up_bytes + a->down_bytes) > (b->up_bytes + b->down_bytes);
        });
        const size_t TOPN = 20;
        size_t shown = v.size() < TOPN ? v.size() : TOPN;
        for (size_t i = 0; i < shown; i++) {
            char fp[MF_LOG_FP_LEN], a[24], c[24];
            mf_client_fp(v[i]->client_addr, fp, sizeof(fp));
            human_bytes(v[i]->up_bytes, a, sizeof(a));
            human_bytes(v[i]->down_bytes, c, sizeof(c));
            mylog(log_debug, "[relay][report] sess %s up=%s/%llu down=%s/%llu\n",
                  fp, a, (unsigned long long)v[i]->up_pkts,
                  c, (unsigned long long)v[i]->down_pkts);
        }
        if (v.size() > shown)
            mylog(log_debug, "[relay][report] (+%zu sessions omitted)\n", v.size() - shown);
    }
}

/* ────────────────────────────────────────────────────────────────
 * mf_relay_event_loop()
 * ──────────────────────────────────────────────────────────────── */

void mf_relay_event_loop(address_t &listen_addr, address_t &upstream_addr,
                         const struct obfs_ctx *obfs, address_t decoy_addr)
{
    g_upstream = upstream_addr;
    g_obfs     = obfs;

    /* Client-IP log fingerprint salt (0600, auto-created). See mf_logfp. */
    mf_log_salt_init();

    if (decoy_addr.is_vaild()) {
        g_decoy_addr    = decoy_addr;
        g_decoy_enabled = true;
        mylog(log_info, "[relay] decoy: forwarding probes to %s\n",
              decoy_addr.get_str());
    }

    /* g_builtin_ctx: obfs context used for the builtin QUIC Initial response on HMAC failure.
     * The PSK is used only to generate the response's DCID token, which the prober
     * cannot verify, so any key works. Prefer the first available key. */
    if (g_obfs)
        g_builtin_ctx = *g_obfs;
    else if (!g_routes.empty())
        g_builtin_ctx = g_routes[0].obfs;
    else
        obfs_init(&g_builtin_ctx, "", OBFS_MODE_QUIC);

    if (g_upstream_local.is_vaild())
        mylog(log_info, "[relay] upstream source IP = %s (bound)\n",
              g_upstream_local.get_str());

    if (!g_routes.empty()) {
        mylog(log_info, "[relay] listen=%s  mode=key-routing  routes=%zu\n",
              listen_addr.get_str(), g_routes.size());
        for (size_t i = 0; i < g_routes.size(); i++) {
            /* Fingerprint only. See obfs_key_fingerprint(): this is an info-level
             * line, so printing the key handed the PSK to every log reader. */
            char kfp[OBFS_KEY_FP_LEN];
            obfs_key_fingerprint(g_routes[i].key_str, kfp, sizeof(kfp));
            mylog(log_info, "[relay]   route[%zu] key=%s upstream=%s%s%s%s%s\n",
                  i, kfp, g_routes[i].upstream_addr.get_str(),
                  g_routes[i].ifname[0] ? " via " : "", g_routes[i].ifname,
                  g_routes[i].local.is_vaild() ? " local " : "",
                  g_routes[i].local.is_vaild() ? g_routes[i].local.get_str() : "");
        }
    } else {
        mylog(log_info, "[relay] listen=%s  upstream=%s  hmac=%s\n",
              listen_addr.get_str(),
              upstream_addr.is_vaild() ? upstream_addr.get_str() : "(none)",
              obfs ? "enabled" : "disabled (transparent)");
    }

    struct ev_loop *loop = ev_default_loop(0);
    assert(loop != NULL);
    g_loop = loop;

    /* Listen socket */
    new_listen_socket2(g_listen_fd, listen_addr);
    mylog(log_info, "[relay] listen fd=%d\n", g_listen_fd);
    if (g_sock_buf > 0) {
        int rcv_kb = 0, snd_kb = 0;
        int r = mf_set_sock_buf(g_listen_fd, g_sock_buf, &rcv_kb, &snd_kb);
        if (r < 0)
            mylog(log_warn, "[relay] sock-buf setsockopt failed: %s\n", strerror(errno));
        else if (r > 0)
            mylog(log_warn, "[relay] sock-buf=%d kB requested but kernel capped it at rcv=%d snd=%d kB — "
                  "raise net.core.rmem_max/wmem_max or run with CAP_NET_ADMIN\n",
                  g_sock_buf, rcv_kb, snd_kb);
        else
            mylog(log_info, "[relay] sock-buf=%d kB (listen + each upstream socket, rcv=%d snd=%d kB)\n",
                  g_sock_buf, rcv_kb, snd_kb);
    }

    struct ev_io listen_watcher;
    ev_io_init(&listen_watcher, listen_read_cb, g_listen_fd, EV_READ);
    ev_io_start(loop, &listen_watcher);

    /* Session cleanup every 10 s */
    struct ev_timer cleanup_timer;
    ev_timer_init(&cleanup_timer, cleanup_cb, 10.0, 10.0);
    ev_timer_start(loop, &cleanup_timer);

    /* Decoy cleanup every 10 s */
    struct ev_timer decoy_timer;
    if (g_decoy_enabled) {
        ev_timer_init(&decoy_timer, decoy_cleanup_cb, 10.0, 10.0);
        ev_timer_start(loop, &decoy_timer);
    }

    /* Periodic traffic report (--report seconds; 0 = off) */
    struct ev_timer report_timer;
    if (report_interval > 0) {
        g_report_last_ms = get_current_time();
        ev_timer_init(&report_timer, report_cb,
                      (double)report_interval, (double)report_interval);
        ev_timer_start(loop, &report_timer);
        mylog(log_info, "[relay] traffic report every %ds\n", report_interval);
    }

    if (!g_routes.empty())
        mylog(log_info, "[relay] ready, key-routing on %s\n", listen_addr.get_str());
    else
        mylog(log_info, "[relay] ready, forwarding %s → %s\n",
              listen_addr.get_str(),
              upstream_addr.is_vaild() ? upstream_addr.get_str() : "(none)");

    ev_run(loop, 0);

    mylog(log_warn, "[relay] ev_run returned\n");
}
