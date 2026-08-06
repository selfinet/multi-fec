#pragma once
/*
 * mud_lite.h — glorytun mud with libsodium encryption removed
 *
 * Origin: glorytun (https://github.com/angt/glorytun), BSD 2-Clause License,
 *         Copyright (c) Adrien Gallouet <adrien@gallouet.fr>.
 *         See mud_lite.c and THIRD_PARTY_NOTICES.md for the full license notice.
 *
 * Removed: key exchange, AEAD encryption, libsodium dependency
 * Kept:    multipath path selection, RTT measurement, loss rate, rate control, MTU discovery
 *
 * Packet format (wire, before obfs layer applied):
 *   Data : [6B time (bit0=0)] [payload]
 *   Probe: [6B time (bit0=1)] [mud_lite_msg]
 */
#include <stddef.h>
#include <inttypes.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* obfs layer function pointers (avoids circular dependency) */
typedef int (*mud_obfs_enc_t)(void *ctx,
                              const unsigned char *in,  int in_len,
                              unsigned char       *out, int out_max);
typedef int (*mud_obfs_dec_t)(void *ctx,
                              const unsigned char *in,  int in_len,
                              unsigned char       *out, int out_max);
/* QUIC Initial packet builder function pointer
 * is_server=0: Client Initial, is_server=1: Server Initial */
typedef int (*mud_obfs_init_t)(void *ctx, void *out, int out_max, int is_server);

#define MUD_PATH_MAX    (32U)

enum mud_state {
    MUD_EMPTY   = 0,
    MUD_DOWN,
    MUD_PASSIVE,
    MUD_UP,
    MUD_LAST,
};

enum mud_path_status {
    MUD_DELETING = 0,
    MUD_PROBING,
    MUD_DEGRADED,
    MUD_LOSSY,
    MUD_WAITING,
    MUD_READY,
    MUD_RUNNING,
};

struct mud_stat {
    uint64_t val;
    uint64_t var;
    int      setup;
};

struct mud_conf {
    uint64_t keepalive;
    uint64_t timetolerance;
};

union mud_sockaddr {
    struct sockaddr     sa;
    struct sockaddr_in  sin;
    struct sockaddr_in6 sin6;
};

struct mud_path_conf {
    enum mud_state    state;
    union mud_sockaddr local;
    union mud_sockaddr remote;
    uint64_t tx_max_rate;
    uint64_t rx_max_rate;
    uint64_t beat;
    unsigned char pref;
    unsigned char fixed_rate;
    unsigned char loss_limit;
};

struct mud_path {
    struct mud_path_conf conf;
    enum mud_path_status status;
    union mud_sockaddr   remote;   /* observed remote (reflects NAT) */
    struct mud_stat rtt;
    struct {
        uint64_t total;
        uint64_t bytes;
        uint64_t time;
        uint64_t rate;
        uint64_t loss;
    } tx, rx;
    struct {
        struct {
            uint64_t total;
            uint64_t bytes;
            uint64_t time;
            uint64_t acc;
            uint64_t acc_time;
        } tx, rx;
        /* The tx/rx blocks above mirror what the *peer* reported. Loss is a
         * cross-side ratio (what one end sent vs what the other end received),
         * so it also needs snapshots of our own counters — these two. */
        uint64_t loss_tx_acc;   /* snapshot of path->tx.total */
        uint64_t loss_rx_acc;   /* snapshot of path->rx.total */
        uint64_t time;
        uint64_t sent;
        uint64_t set;
    } msg;
    struct {
        size_t min, max, probe, last, ok;
    } mtu;
    uint64_t idle;
    int64_t  agg_credit;  /* weighted round-robin credit (aggregate mode) */
    uint64_t peer_id;     /* owning peer (0 = untagged, matches every send) */
};

struct mud_error {
    union mud_sockaddr addr;
    uint64_t time;
    uint64_t count;
};
/* Maximum number of --accept-local entries. 16 covers a /28 (14 usable hosts);
 * a host serving more distinct local addresses than that on one socket is
 * better off accepting all of them and filtering in the firewall. The lookup is
 * a linear scan per received packet, so the constant is kept small on purpose. */
#define MUD_ACCEPT_LOCAL_MAX 16

struct mud_errors {
    struct mud_error clocksync;
    struct mud_error auth;      /* originally decrypt → changed to auth failure */
    struct mud_error local;     /* packet arrived on a local address not in the accept list */
    /* Path table full — every one of MUD_PATH_MAX slots is taken, so a packet
     * from a new peer cannot be assigned a path and is dropped.
     *
     * This used to be entirely silent: the 33rd concurrent peer simply stopped
     * being delivered, with no log and no counter, while the relay's session cap
     * (800) and the server's session table (800) both said there was room.
     * Measured 2026-08-06: clients 1–32 deliver 10/10, client 33 delivers 0/10. */
    struct mud_error path_full;
};

struct mud_paths {
    struct mud_path path[MUD_PATH_MAX];
    unsigned        count;
};

struct mud;

struct mud *mud_create  (union mud_sockaddr *addr);
void        mud_delete  (struct mud *);

/* Register obfs hooks (optional)
 * init_fn: QUIC Initial packet builder. NULL disables the Initial feature. */
void mud_set_obfs(struct mud *mud,
                  mud_obfs_enc_t  enc_fn,
                  mud_obfs_dec_t  dec_fn,
                  mud_obfs_init_t init_fn,
                  void           *obfs_ctx);

/* Send a QUIC Client Initial packet on every UP path.
 * Call before the event loop starts → presents the first packet to DPI as a Long Header. */
int mud_send_initials(struct mud *mud);

int mud_set      (struct mud *, struct mud_conf *);
int mud_set_path (struct mud *, struct mud_path_conf *);

int mud_update     (struct mud *);
int mud_send_wait  (struct mud *);
int mud_send_flush (struct mud *);  /* flush sendmmsg queue immediately */

int mud_recv         (struct mud *, void *, size_t);
int mud_recv_pending (struct mud *);  /* whether the recvmmsg queue has unprocessed items */
int mud_send      (struct mud *, const void *, size_t);
int mud_send_all  (struct mud *, const void *, size_t);
/* Send to dup_count paths via weighted round-robin.
 * dup_count=1: pure aggregate, dup_count>1: aggregate-duplicate.
 * Distributes packets proportionally to each path's tx.rate → faster paths carry more. */
int mud_send_next (struct mud *, const void *, size_t, unsigned dup_count);

/* Peer-scoped sends.
 *
 * A client has one peer (the server) reachable over several paths, so the
 * plain sends above are correct there. A server has the opposite shape: one
 * socket, one path set, many clients — selecting a path globally sends client
 * A's downstream packet over client B's path. The receiving client drops it as
 * an unknown conv, so the traffic is silently lost rather than mis-delivered.
 *
 * Tag each path with the client it belongs to via mud_set_path_peer(), then
 * send with the matching peer id. peer 0 means "untagged": it matches every
 * path, so mud_send()/mud_send_all()/mud_send_next() keep their old behaviour
 * exactly, and a server with a single client selects from the same path set it
 * did before. */
int mud_set_path_peer (struct mud *, union mud_sockaddr *remote, uint64_t peer);

/* Source address of the packet mud_recv() returned most recently.
 * mud_recv() drains an internal recvmmsg batch, so a caller that separately
 * peeks the socket to learn the sender can observe a different packet than the
 * one it was handed. Servers must use this instead of a peeked address. */
int mud_get_last_remote (struct mud *, union mud_sockaddr *out);

/* Restrict which *local* address a received packet may have arrived on.
 *
 * Only meaningful with a wildcard bind (-l 0.0.0.0 / [::]): a socket bound to a
 * specific address already gets this from the kernel. With one or more entries
 * set, packets that arrived on any other local address are dropped silently —
 * answering them would advertise the service on an address we do not serve.
 * Empty list (the default) accepts every local address, matching prior behavior.
 * The port is ignored; only the address is compared. */
int mud_add_accept_local (struct mud *, union mud_sockaddr *);

int mud_send_peer      (struct mud *, uint64_t peer, const void *, size_t);
int mud_send_all_peer  (struct mud *, uint64_t peer, const void *, size_t);
int mud_send_next_peer (struct mud *, uint64_t peer, const void *, size_t,
                        unsigned dup_count);

int    mud_get_errors (struct mud *, struct mud_errors *);
int    mud_get_fd     (struct mud *);
size_t mud_get_mtu    (struct mud *);
int    mud_get_paths  (struct mud *, struct mud_paths *,
                       union mud_sockaddr *, union mud_sockaddr *);
