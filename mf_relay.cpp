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
#include "obfs.h"

#include <unordered_map>
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
static struct obfs_ctx        g_builtin_ctx;        /* 내장 QUIC Initial 응답용 */

#define RELAY_SESSION_TIMEOUT_MS  60000     /* 60 s idle → evict */

/* ────────────────────────────────────────────────────────────────
 * Decoy session management (--decoy ip:port)
 *
 * 서버와 동일한 구조: HMAC 실패 패킷을 로컬 QUIC/HTTPS 서버로
 * 포워딩하고 그 응답을 프로버에게 되돌려 보낸다.
 * 프로버 주소마다 독립 UDP 소켓, 10초 idle → 자동 제거.
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

static decoy_sess_t *
decoy_get_or_create(const address_t &prober)
{
    auto it = g_decoy_map.find(const_cast<address_t &>(prober));
    if (it != g_decoy_map.end()) {
        it->second->last_active = time(NULL);
        return it->second;
    }

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
    const struct obfs_ctx *route_obfs;  /* 이 세션에 매칭된 키의 obfs. NULL=투명 */
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

    mylog(log_info, "[relay] session removed: client=%s fd=%d\n",
          sess->client_addr.get_str(), sess->upstream_fd);
    delete sess;
}

/* ────────────────────────────────────────────────────────────────
 * Helper: create a non-blocking UDP socket connected to upstream
 * ──────────────────────────────────────────────────────────────── */

static int new_upstream_fd(address_t &remote)
{
    int fd = socket(remote.get_type(), SOCK_DGRAM, 0);
    if (fd < 0) {
        mylog(log_warn, "[relay] socket(): %s\n", strerror(errno));
        return -1;
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

        mylog(log_trace, "[relay] ← upstream %d bytes to %s\n",
              n, sess->client_addr.get_str());
    }
}

/* ────────────────────────────────────────────────────────────────
 * Helper: TLS close_notify alert (7 bytes) → prober
 *   Sent when HMAC verification fails so active probers see a
 *   realistic TLS server response instead of silence.
 * ──────────────────────────────────────────────────────────────── */

static void probe_respond_builtin(address_t &src)
{
    if (g_builtin_ctx.mode == OBFS_MODE_TLS) {
        static const uint8_t close_notify[] = {
            0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00
        };
        sendto(g_listen_fd, close_notify, sizeof(close_notify), 0,
               (struct sockaddr *)&src.inner, src.get_len());
    } else {
        static char buf[QUIC_INITIAL_SIZE + 256];
        int n = obfs_encode_initial(&g_builtin_ctx, buf, sizeof(buf), 1);
        if (n <= 0) return;
        int extra = rand() % 256;
        for (int i = n; i < n + extra; i++)
            buf[i] = (char)(rand() & 0xFF);
        sendto(g_listen_fd, buf, (size_t)(n + extra), 0,
               (struct sockaddr *)&src.inner, src.get_len());
    }
}

/* ────────────────────────────────────────────────────────────────
 * Callback: data arrived from client → forward to upstream
 * ──────────────────────────────────────────────────────────────── */

/*
 * 새 세션의 upstream 주소와 obfs 컨텍스트를 결정한다.
 *
 * g_routes 비어 있음 → 단일 upstream 모드 (기존 동작)
 *   upstream = g_upstream, obfs = g_obfs
 *
 * g_routes 있음 → 키별 라우팅 모드
 *   각 route의 HMAC을 순서대로 시도. 첫 성공 route를 사용.
 *   모두 실패 → upstream = NULL (close_notify 응답)
 */
static const struct obfs_ctx *find_route(const char *buf, int n,
                                         address_t &upstream_out)
{
    static char decoded[buf_len];

    if (g_routes.empty()) {
        /* 단일 upstream 모드 */
        if (g_obfs != NULL) {
            int plen = obfs_decode(g_obfs, buf, n,
                                   decoded, (int)sizeof(decoded), NULL);
            if (plen == 0 || (plen < 0 && plen != OBFS_DECODE_INITIAL))
                return NULL;  /* HMAC 실패 */
        }
        upstream_out = g_upstream;
        return g_obfs;  /* NULL이면 투명 모드 */
    }

    /* 키별 라우팅: 순서대로 HMAC 시도 */
    for (const route_entry_t &route : g_routes) {
        int plen = obfs_decode(&route.obfs, buf, n,
                               decoded, (int)sizeof(decoded), NULL);
        if (plen > 0 || plen == OBFS_DECODE_INITIAL) {
            upstream_out = route.upstream_addr;
            return &route.obfs;
        }
    }
    return NULL;  /* 어떤 키도 불일치 */
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
            /* ── 기존 세션: 저장된 obfs로 HMAC 재검증 ── */
            sess = it->second;
            if (sess->route_obfs != NULL) {
                static char decoded[buf_len];
                int plen = obfs_decode(sess->route_obfs, buf, n,
                                       decoded, (int)sizeof(decoded), NULL);
                if (plen == 0 || (plen < 0 && plen != OBFS_DECODE_INITIAL)) {
                    if (g_decoy_enabled)
                        decoy_forward(src, buf, n);
                    else
                        probe_respond_builtin(src);
                    mylog(log_debug, "[relay] HMAC fail (existing session) from %s\n",
                          src.get_str());
                    continue;
                }
            }
        } else {
            /* ── 신규 세션: route 탐색으로 upstream 결정 ── */
            address_t upstream;
            const struct obfs_ctx *matched_obfs = find_route(buf, n, upstream);

            if (matched_obfs == NULL && !g_routes.empty()) {
                /* 키별 라우팅 모드에서 불일치 */
                if (g_decoy_enabled)
                    decoy_forward(src, buf, n);
                else
                    probe_respond_builtin(src);
                mylog(log_debug, "[relay] no route matched from %s → %s\n",
                      src.get_str(), g_decoy_enabled ? "decoy" : "builtin-quic");
                continue;
            }
            if (matched_obfs == NULL && g_obfs != NULL) {
                /* 단일 키 모드에서 HMAC 실패 */
                if (g_decoy_enabled)
                    decoy_forward(src, buf, n);
                else
                    probe_respond_builtin(src);
                mylog(log_debug, "[relay] HMAC fail from %s → %s\n",
                      src.get_str(), g_decoy_enabled ? "decoy" : "builtin-quic");
                continue;
            }

            int ufd = new_upstream_fd(upstream);
            if (ufd < 0) continue;

            sess               = new relay_session_t;
            sess->client_addr  = src;
            sess->upstream_fd  = ufd;
            sess->last_active  = get_current_time();
            sess->route_obfs   = matched_obfs;

            sess->upstream_watcher.data = sess;
            ev_io_init(&sess->upstream_watcher, upstream_read_cb, ufd, EV_READ);
            ev_io_start(g_loop, &sess->upstream_watcher);

            g_addr_to_sess[src] = sess;
            g_fd_to_sess[ufd]   = sess;

            mylog(log_info, "[relay] new session: client=%s upstream=%s fd=%d\n",
                  src.get_str(), upstream.get_str(), ufd);
        }

        sess->last_active = get_current_time();
        send(sess->upstream_fd, buf, n, 0);

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
    my_time_t now = get_current_time();
    std::vector<relay_session_t *> to_del;

    for (auto &kv : g_fd_to_sess) {
        relay_session_t *s = kv.second;
        if (now - s->last_active > (my_time_t)RELAY_SESSION_TIMEOUT_MS * 1000LL)
            to_del.push_back(s);
    }
    for (relay_session_t *s : to_del)
        delete_session(s);

    if (!to_del.empty())
        mylog(log_debug, "[relay] cleanup: removed %zu stale sessions\n",
              to_del.size());
}

/* ────────────────────────────────────────────────────────────────
 * mf_relay_event_loop()
 * ──────────────────────────────────────────────────────────────── */

void mf_relay_event_loop(address_t &listen_addr, address_t &upstream_addr,
                         const struct obfs_ctx *obfs, address_t decoy_addr)
{
    g_upstream = upstream_addr;
    g_obfs     = obfs;

    if (decoy_addr.is_vaild()) {
        g_decoy_addr    = decoy_addr;
        g_decoy_enabled = true;
        mylog(log_info, "[relay] decoy: forwarding probes to %s\n",
              decoy_addr.get_str());
    }

    /* g_builtin_ctx: HMAC 실패 시 내장 QUIC Initial 응답에 사용할 obfs 컨텍스트.
     * PSK는 응답의 DCID 토큰 생성에만 쓰이며 프로버가 검증하지 않으므로
     * 어떤 키를 써도 무방하다. 가용한 키 중 첫 번째를 우선 사용. */
    if (g_obfs)
        g_builtin_ctx = *g_obfs;
    else if (!g_routes.empty())
        g_builtin_ctx = g_routes[0].obfs;
    else
        obfs_init(&g_builtin_ctx, "", OBFS_MODE_QUIC);

    if (!g_routes.empty()) {
        mylog(log_info, "[relay] listen=%s  mode=key-routing  routes=%zu\n",
              listen_addr.get_str(), g_routes.size());
        for (size_t i = 0; i < g_routes.size(); i++)
            mylog(log_info, "[relay]   route[%zu] key=%s upstream=%s\n",
                  i, g_routes[i].key_str, g_routes[i].upstream_addr.get_str());
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

    if (!g_routes.empty())
        mylog(log_info, "[relay] ready, key-routing on %s\n", listen_addr.get_str());
    else
        mylog(log_info, "[relay] ready, forwarding %s → %s\n",
              listen_addr.get_str(),
              upstream_addr.is_vaild() ? upstream_addr.get_str() : "(none)");

    ev_run(loop, 0);

    mylog(log_warn, "[relay] ev_run returned\n");
}
