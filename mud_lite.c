/*
 * mud_lite.c — glorytun mud, libsodium 암호화 제거 버전
 *
 * 원본: glorytun/mud/mud.c (2024)
 * 변경: 키 교환, AEAD 암호화, sodium 의존성 완전 제거
 *       obfs 훅으로 상위 계층 난독화 위임
 *
 * 패킷 포맷:
 *   Data:  [6B time (bit0=0)][payload]
 *   Probe: [6B time (bit0=1)][mud_lite_msg struct]
 */
#if defined __linux__ && !defined _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "mud_lite.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

#include <sys/ioctl.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <net/if.h>

#if !defined MSG_CONFIRM
#define MSG_CONFIRM 0
#endif

/* 80–120ms 범위 랜덤 beat 생성 (경로별 probe 주기 다양화).
 * 경로 포인터와 현재 시각을 엔트로피 소스로 사용해 srand 없이도 분산됨. */
static uint64_t mud_random_beat(const void *path_ptr)
{
    uint64_t h = (uint64_t)(uintptr_t)path_ptr ^ (uint64_t)time(NULL);
    h ^= h >> 33; h *= UINT64_C(0xff51afd7ed558ccd);
    h ^= h >> 33; h *= UINT64_C(0xc4ceb9fe1a85ec53);
    h ^= h >> 33;
    return (uint64_t)(80 + (h % 41)) * UINT64_C(1000);  /* 80–120ms (1000µs = 1ms) */
}

#if defined __linux__
#define MUD_V4V6 1
#else
#define MUD_V4V6 0
#endif

/* ─── 상수 ──────────────────────────────────────────────────────── */

#define MUD_ONE_MSEC (UINT64_C(1000))
#define MUD_ONE_SEC  (1000 * MUD_ONE_MSEC)
#define MUD_ONE_MIN  (60  * MUD_ONE_SEC)

#define MUD_TIME_SIZE    (6U)
#define MUD_TIME_BITS    (MUD_TIME_SIZE * 8U)
#define MUD_TIME_MASK(X) ((X) & ((UINT64_C(1) << MUD_TIME_BITS) - 2))

/* bit0: MSG 플래그 (0=data, 1=probe) */
#define MUD_MSG(X)       ((X) & UINT64_C(1))
#define MUD_MSG_MARK(X)  ((X) | UINT64_C(1))
#define MUD_MSG_SENT_MAX (5)

/* 암호화 제거 후 오버헤드: 6바이트 시간 헤더만 */
#define MUD_TIME_OVERHEAD MUD_TIME_SIZE
#define MUD_PKT_MAX_SIZE  (1500U)
#define MUD_MTU_MIN       (576U  + MUD_TIME_OVERHEAD)
#define MUD_MTU_MAX       (1450U + MUD_TIME_OVERHEAD)

#if defined IP_PKTINFO
#define MUD_PKTINFO          IP_PKTINFO
#define MUD_PKTINFO_SRC(X)   &((struct in_pktinfo *)(X))->ipi_addr
#define MUD_PKTINFO_DST(X)   &((struct in_pktinfo *)(X))->ipi_spec_dst
#define MUD_PKTINFO_SIZE     sizeof(struct in_pktinfo)
#elif defined IP_RECVDSTADDR
#define MUD_PKTINFO          IP_RECVDSTADDR
#define MUD_PKTINFO_SRC(X)   (X)
#define MUD_PKTINFO_DST(X)   (X)
#define MUD_PKTINFO_SIZE     sizeof(struct in_addr)
#endif

#define MUD_CTRL_SIZE (CMSG_SPACE(MUD_PKTINFO_SIZE) + \
                       CMSG_SPACE(sizeof(struct in6_pktinfo)))

/* ─── 내부 구조체 ─────────────────────────────────────────────── */

struct mud_addr {
    union {
        unsigned char v6[16];
        struct {
            unsigned char zero[10];
            unsigned char ff[2];
            unsigned char v4[4];
        };
    };
    unsigned char port[2];
};

/* 경로 프로브 메시지 (암호화 없음, obfs 계층이 보호) */
struct mud_lite_msg {
    struct {
        unsigned char bytes[sizeof(uint64_t)];
        unsigned char total[sizeof(uint64_t)];
    } tx, rx;
    unsigned char max_rate[sizeof(uint64_t)];
    unsigned char beat[MUD_TIME_SIZE];
    unsigned char mtu[2];
    unsigned char pref;
    unsigned char loss;
    unsigned char fixed_rate;
    unsigned char loss_limit;
    struct mud_addr addr;
};

/* ─── sendmmsg / recvmmsg 배치 큐 ───────────────────────────── */

#define MUD_SEND_QUEUE_CAP  32
#define MUD_RECV_QUEUE_CAP  32
#define MUD_SEND_BUF_MAX    (MUD_PKT_MAX_SIZE + 512)
#define MUD_RECV_BUF_MAX    (MUD_PKT_MAX_SIZE + 512)

/*
 * 송신/수신 슬롯.
 * mmsghdr는 여기에 두지 않는다 — sendmmsg/recvmmsg는 연속 배열을 요구하므로
 * struct mmsghdr sq_msgs[] / rq_msgs[] 를 별도로 유지하고 여기 포인터를 가리킨다.
 */
struct mud_send_slot {
    unsigned char      buf[MUD_SEND_BUF_MAX]; /* obfs 인코딩된 패킷 */
    unsigned char      ctrl[MUD_CTRL_SIZE];   /* IP_PKTINFO 제어 메시지 */
    union mud_sockaddr remote;                 /* 목적지 주소 */
    struct iovec       iov;
};

struct mud_recv_slot {
    unsigned char      buf[MUD_RECV_BUF_MAX]; /* 수신 원본 패킷 */
    unsigned char      ctrl[MUD_CTRL_SIZE];   /* IP_PKTINFO 제어 메시지 */
    union mud_sockaddr remote;                 /* 송신자 주소 */
    struct iovec       iov;
};

struct mud {
    int fd;
    struct mud_conf    conf;
    struct mud_path   *paths;
    unsigned           pref;
    unsigned           capacity;
    uint64_t           last_recv_time;
    size_t             mtu;
    struct mud_errors  err;
    uint64_t           rate;
    uint64_t           window;
    uint64_t           window_time;
    uint64_t           base_time;

    /* obfs 훅 */
    mud_obfs_enc_t  obfs_enc;
    mud_obfs_dec_t  obfs_dec;
    mud_obfs_init_t obfs_init_fn;  /* QUIC Initial 생성 (NULL=비활성) */
    void           *obfs_ctx;

    /* sendmmsg 배치 송신 큐 */
    struct mud_send_slot *sq;
    struct mmsghdr       *sq_msgs;
    int                   sq_len;

    /* recvmmsg 배치 수신 큐 */
    struct mud_recv_slot *rq;
    struct mmsghdr       *rq_msgs;
    int                   rq_len;
    int                   rq_idx;

    /* duplicate 모드 중복 패킷 제거용 링버퍼 */
#define MUD_DEDUP_SIZE 128
#define MUD_DEDUP_TTL  (500 * MUD_ONE_MSEC)
    struct {
        uint64_t pkt_time;   /* 패킷의 sent_time 값 */
        uint64_t recv_time;  /* 수신 시각 (만료 판단용) */
    } dedup[MUD_DEDUP_SIZE];
    unsigned dedup_idx;
};

/* ─── 시간 유틸 ──────────────────────────────────────────────── */

static inline void
mud_store(unsigned char *dst, uint64_t src, size_t size)
{
    for (size_t i = 0; i < size; i++)
        dst[i] = (unsigned char)(src >> (8 * i));
}

static inline uint64_t
mud_load(const unsigned char *src, size_t size)
{
    uint64_t ret = 0;
    for (size_t i = 0; i < size; i++)
        ret |= ((uint64_t)src[i]) << (8 * i);
    return ret;
}

static inline uint64_t
mud_now(struct mud *mud)
{
    (void)mud;
    struct timespec tv;
    clock_gettime(CLOCK_MONOTONIC, &tv);
    return MUD_TIME_MASK(mud->base_time
            + (uint64_t)tv.tv_sec  * MUD_ONE_SEC
            + (uint64_t)tv.tv_nsec / MUD_ONE_MSEC);
}

static inline uint64_t
mud_time_now(void)
{
    struct timespec tv;
    clock_gettime(CLOCK_REALTIME, &tv);
    return MUD_TIME_MASK((uint64_t)tv.tv_sec  * MUD_ONE_SEC
                       + (uint64_t)tv.tv_nsec / MUD_ONE_MSEC);
}

static inline int
mud_timeout(uint64_t now, uint64_t last, uint64_t timeout)
{
    return (!last) || (MUD_TIME_MASK(now - last) >= timeout);
}

/* ─── 주소 유틸 ─────────────────────────────────────────────── */

static inline void
mud_unmapv4(union mud_sockaddr *addr)
{
    if (addr->sa.sa_family != AF_INET6) return;
    if (!IN6_IS_ADDR_V4MAPPED(&addr->sin6.sin6_addr)) return;

    struct sockaddr_in sin = {
        .sin_family = AF_INET,
        .sin_port   = addr->sin6.sin6_port,
    };
    memcpy(&sin.sin_addr.s_addr,
           &addr->sin6.sin6_addr.s6_addr[12],
           sizeof(sin.sin_addr.s_addr));
    addr->sin = sin;
}

static inline int
mud_cmp_addr(union mud_sockaddr *a, union mud_sockaddr *b)
{
    if (a->sa.sa_family != b->sa.sa_family) return 1;
    if (a->sa.sa_family == AF_INET)
        return memcmp(&a->sin.sin_addr, &b->sin.sin_addr,
                      sizeof(a->sin.sin_addr));
    if (a->sa.sa_family == AF_INET6)
        return memcmp(&a->sin6.sin6_addr, &b->sin6.sin6_addr,
                      sizeof(a->sin6.sin6_addr));
    return 1;
}

static inline int
mud_cmp_port(union mud_sockaddr *a, union mud_sockaddr *b)
{
    if (a->sa.sa_family != b->sa.sa_family) return 1;
    if (a->sa.sa_family == AF_INET)
        return memcmp(&a->sin.sin_port, &b->sin.sin_port,
                      sizeof(a->sin.sin_port));
    if (a->sa.sa_family == AF_INET6)
        return memcmp(&a->sin6.sin6_port, &b->sin6.sin6_port,
                      sizeof(a->sin6.sin6_port));
    return 1;
}

static int
mud_addr_is_v6(struct mud_addr *addr)
{
    static const unsigned char v4mapped[] = { [10]=255, [11]=255 };
    return memcmp(addr->v6, v4mapped, sizeof(v4mapped));
}

static void
mud_sock_from_addr(union mud_sockaddr *sock, struct mud_addr *addr)
{
    if (mud_addr_is_v6(addr)) {
        sock->sin6.sin6_family = AF_INET6;
        memcpy(&sock->sin6.sin6_addr, addr->v6, 16);
        memcpy(&sock->sin6.sin6_port, addr->port, 2);
    } else {
        sock->sin.sin_family = AF_INET;
        memcpy(&sock->sin.sin_addr, addr->v4,   4);
        memcpy(&sock->sin.sin_port, addr->port, 2);
    }
}

static int
mud_addr_from_sock(struct mud_addr *addr, union mud_sockaddr *sock)
{
    if (sock->sa.sa_family == AF_INET) {
        memset(addr->zero, 0,    sizeof(addr->zero));
        memset(addr->ff,   0xFF, sizeof(addr->ff));
        memcpy(addr->v4,   &sock->sin.sin_addr,  4);
        memcpy(addr->port, &sock->sin.sin_port,  2);
    } else if (sock->sa.sa_family == AF_INET6) {
        memcpy(addr->v6,   &sock->sin6.sin6_addr, 16);
        memcpy(addr->port, &sock->sin6.sin6_port,  2);
    } else {
        errno = EAFNOSUPPORT;
        return -1;
    }
    return 0;
}

/* ─── 경로 관리 ─────────────────────────────────────────────── */

static struct mud_path *
mud_get_path(struct mud *mud,
             union mud_sockaddr *local,
             union mud_sockaddr *remote,
             enum mud_state state)
{
    struct mud_path *empty = NULL;

    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];

        if (path->conf.state == MUD_EMPTY) {
            if (!empty) empty = path;
            continue;
        }
        if (mud_cmp_addr(&path->conf.remote, remote) ||
            mud_cmp_port(&path->conf.remote, remote))
            continue;
        if (local && local->sa.sa_family != AF_UNSPEC &&
            mud_cmp_addr(&path->conf.local, local)) {
            /* 0.0.0.0 / :: wildcard: match any local address */
            int wildcard =
                (path->conf.local.sa.sa_family == AF_INET  &&
                 path->conf.local.sin.sin_addr.s_addr == INADDR_ANY) ||
                (path->conf.local.sa.sa_family == AF_INET6 &&
                 IN6_IS_ADDR_UNSPECIFIED(&path->conf.local.sin6.sin6_addr));
            if (!wildcard)
                continue;
        }
        return path;
    }
    if (state == MUD_EMPTY || !empty)
        return empty;

    memset(empty, 0, sizeof(*empty));
    if (local) empty->conf.local  = *local;
    empty->conf.remote = *remote;
    empty->conf.state  = state;

    /* 초기 MTU 범위 설정 */
    empty->mtu.min = MUD_MTU_MIN;
    empty->mtu.max = MUD_MTU_MAX;

    return empty;
}

/* ─── sendmsg (IP_PKTINFO 포함) ──────────────────────────────── */

/* ─── sendmmsg 배치 플러시 ───────────────────────────────────── */

int mud_send_flush(struct mud *mud)
{
    if (!mud->sq_len) return 0;
    /* sq_msgs[]는 sq[]의 iov/ctrl/remote를 가리키는 연속 배열 */
    int sent = sendmmsg(mud->fd, mud->sq_msgs,
                        (unsigned int)mud->sq_len, 0);
    mud->sq_len = 0;
    return sent;
}

static int
mud_send_path(struct mud *mud, struct mud_path *path, uint64_t now,
              void *data, size_t size, int flags)
{
    if (!size || !path) return 0;

    /* 큐가 가득 찼으면 즉시 플러시 */
    if (mud->sq_len >= MUD_SEND_QUEUE_CAP)
        mud_send_flush(mud);

    int idx = mud->sq_len;
    struct mud_send_slot *slot = &mud->sq[idx];
    struct msghdr        *msg  = &mud->sq_msgs[idx].msg_hdr;

    /* obfs 인코딩 → 슬롯 버퍼에 직접 기록 */
    size_t enc_size = size;
    if (mud->obfs_enc) {
        int encoded = mud->obfs_enc(mud->obfs_ctx,
                                    (const unsigned char *)data, (int)size,
                                    slot->buf, (int)sizeof(slot->buf));
        if (encoded <= 0) return -1;
        enc_size = (size_t)encoded;
    } else {
        if (enc_size > sizeof(slot->buf)) return -1;
        memcpy(slot->buf, data, enc_size);
    }

    /* iov 설정 */
    slot->iov.iov_base = slot->buf;
    slot->iov.iov_len  = enc_size;

    /* msghdr 설정 (sq_msgs[idx].msg_hdr) */
    memset(msg,        0, sizeof(*msg));
    memset(slot->ctrl, 0, sizeof(slot->ctrl));

    msg->msg_iov     = &slot->iov;
    msg->msg_iovlen  = 1;
    msg->msg_control = slot->ctrl;

    if (path->conf.remote.sa.sa_family == AF_INET) {
        slot->remote.sin    = path->conf.remote.sin;
        msg->msg_name       = &slot->remote.sin;
        msg->msg_namelen    = sizeof(struct sockaddr_in);
        msg->msg_controllen = CMSG_SPACE(MUD_PKTINFO_SIZE);
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg);
        cmsg->cmsg_level = IPPROTO_IP;
        cmsg->cmsg_type  = MUD_PKTINFO;
        cmsg->cmsg_len   = CMSG_LEN(MUD_PKTINFO_SIZE);
        memcpy(MUD_PKTINFO_DST(CMSG_DATA(cmsg)),
               &path->conf.local.sin.sin_addr, sizeof(struct in_addr));
    } else if (path->conf.remote.sa.sa_family == AF_INET6) {
        slot->remote.sin6   = path->conf.remote.sin6;
        msg->msg_name       = &slot->remote.sin6;
        msg->msg_namelen    = sizeof(struct sockaddr_in6);
        msg->msg_controllen = CMSG_SPACE(sizeof(struct in6_pktinfo));
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg);
        cmsg->cmsg_level = IPPROTO_IPV6;
        cmsg->cmsg_type  = IPV6_PKTINFO;
        cmsg->cmsg_len   = CMSG_LEN(sizeof(struct in6_pktinfo));
        memcpy(&((struct in6_pktinfo *)CMSG_DATA(cmsg))->ipi6_addr,
               &path->conf.local.sin6.sin6_addr, sizeof(struct in6_addr));
    } else {
        errno = EAFNOSUPPORT;
        return -1;
    }

    /* flags가 있는 패킷(MSG_CONFIRM probe ack)은 즉시 전송 */
    if (flags) {
        mud_send_flush(mud);
        ssize_t ret = sendmsg(mud->fd, msg, flags);
        path->tx.total++;
        path->tx.bytes += enc_size;
        path->tx.time   = now;
        if (mud->window > enc_size) mud->window -= enc_size;
        else                        mud->window  = 0;
        return (int)ret;
    }

    /* 큐에 추가 — 통계는 미리 업데이트 (flush 시점과 ~수백 µs 오차 허용) */
    mud->sq_len++;
    path->tx.total++;
    path->tx.bytes += enc_size;
    path->tx.time   = now;
    if (mud->window > enc_size) mud->window -= enc_size;
    else                        mud->window  = 0;

    return (int)enc_size;
}

/* ─── recvmsg 로컬 주소 추출 ────────────────────────────────── */

static int
mud_localaddr(union mud_sockaddr *addr, struct msghdr *msg)
{
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg);
    for (; cmsg; cmsg = CMSG_NXTHDR(msg, cmsg)) {
        if (cmsg->cmsg_level == IPPROTO_IP &&
            cmsg->cmsg_type  == MUD_PKTINFO) {
            addr->sa.sa_family = AF_INET;
            memcpy(&addr->sin.sin_addr,
                   MUD_PKTINFO_SRC(CMSG_DATA(cmsg)),
                   sizeof(struct in_addr));
            return 0;
        }
        if (cmsg->cmsg_level == IPPROTO_IPV6 &&
            cmsg->cmsg_type  == IPV6_PKTINFO) {
            addr->sa.sa_family = AF_INET6;
            memcpy(&addr->sin6.sin6_addr,
                   &((struct in6_pktinfo *)CMSG_DATA(cmsg))->ipi6_addr,
                   sizeof(struct in6_addr));
            mud_unmapv4(addr);
            return 0;
        }
    }
    return 1;
}

/* ─── 통계/RTT ──────────────────────────────────────────────── */

static void
mud_update_stat(struct mud_stat *stat, uint64_t val)
{
    if (!stat->setup) {
        stat->val   = val;
        stat->var   = 0;
        stat->setup = 1;
        return;
    }
    uint64_t err = (val > stat->val) ? val - stat->val : stat->val - val;
    stat->var = (3 * stat->var + err) >> 2;
    stat->val = (7 * stat->val + val) >> 3;
}

static void
mud_update_mtu(struct mud_path *path, size_t size)
{
    if (!path->mtu.probe) {
        if (!path->mtu.last) {
            path->mtu.min   = MUD_MTU_MIN;
            path->mtu.max   = MUD_MTU_MAX;
            path->mtu.probe = MUD_MTU_MAX;
            return;
        }
        if (path->mtu.min > size || path->mtu.max < size) return;
        path->mtu.min = size + 1;
        if (path->mtu.min > path->mtu.max) {
            path->mtu.ok    = path->mtu.last;
            path->mtu.probe = 0;
            return;
        }
        path->mtu.probe = (path->mtu.min + path->mtu.max) / 2;
        return;
    }
    if (size < path->mtu.probe) return;
    path->mtu.last  = size;
    path->mtu.ok    = size - MUD_TIME_OVERHEAD;
    path->mtu.max   = size;
    path->mtu.probe = (path->mtu.min + path->mtu.max) / 2;
    if (path->mtu.probe == path->mtu.last)
        path->mtu.probe = 0;
}

static void
mud_update_rl(struct mud *mud, struct mud_path *path, uint64_t now,
              uint64_t rx_bytes, uint64_t rx_total,
              uint64_t tx_bytes, uint64_t tx_total)
{
    uint64_t rx_dt = MUD_TIME_MASK(now - path->msg.rx.time);
    if (rx_dt >= MUD_ONE_SEC) {
        if (!path->conf.fixed_rate) {
            /* 누적값이 아닌 이전 branch 1 이후 증분으로 실측 throughput 계산 */
            uint64_t rx_delta = rx_bytes - path->msg.rx.bytes;
            uint64_t measured = (7 * rx_delta * MUD_ONE_SEC) / (8 * rx_dt);
            path->tx.rate = measured > 1000000ULL ? measured : 1000000ULL;  /* min 1MB/s */
        }
        uint64_t tx_acc = tx_total - path->msg.tx.acc;
        uint64_t rx_acc = rx_total - path->msg.rx.acc;
        if (tx_acc && rx_acc <= tx_acc)
            path->tx.loss = (tx_acc - rx_acc) * 255U / tx_acc;
        path->msg.rx.acc      = rx_total;
        path->msg.tx.acc      = tx_total;
        path->msg.rx.acc_time = now;
        path->msg.rx.time     = now;  /* 1초마다 rate/tx.loss 재계산 */
        path->msg.rx.bytes    = rx_bytes;  /* delta 기준점 갱신 */
        path->msg.tx.bytes    = tx_bytes;
    } else {
        if (!path->conf.fixed_rate)
            path->tx.rate += path->tx.rate / 10;
    }
    /* tx_max_rate=0 means unlimited; treat 0 as no cap, not "cap to 0" */
    if (path->conf.tx_max_rate && path->tx.rate > path->conf.tx_max_rate)
        path->tx.rate = path->conf.tx_max_rate;
    else if (!path->conf.tx_max_rate && path->tx.rate > 125000000ULL)
        path->tx.rate = 125000000ULL;  /* 1 Gbps default ceiling */

    path->msg.rx.total = rx_total;
    path->msg.tx.total = tx_total;
}

/* ─── 경로 프로브 송수신 ─────────────────────────────────────── */

static int
mud_send_msg(struct mud *mud, struct mud_path *path, uint64_t now,
             uint64_t sent_time, size_t probe_size)
{
    unsigned char packet[MUD_PKT_MAX_SIZE];
    struct mud_lite_msg *msg;

    /* probe_size: MTU 탐지용 패딩 크기 */
    size_t msg_size = sizeof(struct mud_lite_msg);
    size_t total    = MUD_TIME_SIZE + msg_size;

    if (probe_size > total) total = probe_size;
    if (total > sizeof(packet)) return 0;

    uint64_t tx_time = MUD_MSG_MARK(now);
    mud_store(packet, tx_time, MUD_TIME_SIZE);

    msg = (struct mud_lite_msg *)(packet + MUD_TIME_SIZE);
    memset(msg, 0, msg_size);

    mud_store((unsigned char *)msg->tx.bytes, path->tx.bytes,  sizeof(uint64_t));
    mud_store((unsigned char *)msg->tx.total, path->tx.total,  sizeof(uint64_t));
    mud_store((unsigned char *)msg->rx.bytes, path->rx.bytes,  sizeof(uint64_t));
    mud_store((unsigned char *)msg->rx.total, path->rx.total,  sizeof(uint64_t));
    mud_store((unsigned char *)msg->max_rate, path->conf.rx_max_rate, sizeof(uint64_t));
    mud_store((unsigned char *)msg->beat,     path->conf.beat,  MUD_TIME_SIZE);
    mud_store((unsigned char *)msg->mtu,
              path->mtu.probe ? path->mtu.probe : path->mtu.last, 2);

    msg->pref        = path->conf.pref;
    msg->loss        = (unsigned char)path->tx.loss;
    msg->fixed_rate  = path->conf.fixed_rate;
    msg->loss_limit  = path->conf.loss_limit;

    mud_addr_from_sock(&msg->addr, &path->remote);

    /* MTU 프로브용 패딩 */
    if (total > MUD_TIME_SIZE + msg_size)
        memset(packet + MUD_TIME_SIZE + msg_size, 0,
               total - MUD_TIME_SIZE - msg_size);

    (void)sent_time;
    path->msg.sent++;
    path->msg.time = now;

    return mud_send_path(mud, path, now, packet, total, MSG_CONFIRM);
}

static void
mud_recv_msg(struct mud *mud, struct mud_path *path, uint64_t now,
             uint64_t sent_time, const unsigned char *data, size_t size)
{
    if (size < MUD_TIME_SIZE + sizeof(struct mud_lite_msg)) return;

    const struct mud_lite_msg *msg =
        (const struct mud_lite_msg *)(data + MUD_TIME_SIZE);

    uint64_t tx_time = MUD_TIME_MASK(sent_time);
    mud_update_stat(&path->rtt, MUD_TIME_MASK(now - tx_time));

    uint64_t rx_bytes = mud_load((const unsigned char *)msg->rx.bytes, sizeof(uint64_t));
    uint64_t rx_total = mud_load((const unsigned char *)msg->rx.total, sizeof(uint64_t));
    uint64_t tx_bytes = mud_load((const unsigned char *)msg->tx.bytes, sizeof(uint64_t));
    uint64_t tx_total = mud_load((const unsigned char *)msg->tx.total, sizeof(uint64_t));
    mud_update_rl(mud, path, now, rx_bytes, rx_total, tx_bytes, tx_total);

    size_t mtu = (size_t)mud_load((const unsigned char *)msg->mtu, 2);
    mud_update_mtu(path, mtu);

    uint64_t max_rate = mud_load((const unsigned char *)msg->max_rate, sizeof(uint64_t));
    if (path->conf.tx_max_rate != max_rate || msg->fixed_rate)
        path->tx.rate = max_rate;
    path->conf.tx_max_rate  = max_rate;
    path->conf.pref         = msg->pref;
    path->conf.fixed_rate   = msg->fixed_rate;
    path->conf.loss_limit   = msg->loss_limit;

    /* remote 주소 갱신 (NAT 통과 후 실제 주소) */
    mud_sock_from_addr(&path->remote, (struct mud_addr *)&msg->addr);

    path->msg.set++;
    path->msg.sent = 0;

    /* 응답 프로브 전송 */
    mud_send_msg(mud, path, now, tx_time, 0);
}

/* ─── 경로 상태 머신 ─────────────────────────────────────────── */

static int
mud_path_track(struct mud *mud, struct mud_path *path, uint64_t now)
{
    if (path->conf.state == MUD_EMPTY) return 0;

    if (!mud_timeout(now, path->msg.time, path->conf.beat)) return 0;

    if (path->conf.state == MUD_UP || path->conf.state == MUD_PASSIVE) {
        mud_send_msg(mud, path, now, 0,
                     path->mtu.probe ? path->mtu.probe : 0);
    }
    return 0;
}

static int
mud_path_update(struct mud *mud, struct mud_path *path, uint64_t now)
{
    switch (path->conf.state) {
        case MUD_DOWN:
            path->status = MUD_DELETING;
            /* fallthrough */
        case MUD_PASSIVE:
            if (mud_timeout(now, path->rx.time, 5 * MUD_ONE_MIN)) {
                memset(path, 0, sizeof(*path));
                return 0;
            }
            /* fallthrough */
        case MUD_UP: break;
        default:     return 0;
    }
    if (path->conf.state == MUD_DOWN) return 0;

    if (path->msg.sent >= MUD_MSG_SENT_MAX) {
        if (path->mtu.probe) {
            mud_update_mtu(path, 0);
            path->msg.sent = 0;
        } else {
            path->msg.sent = MUD_MSG_SENT_MAX;
            path->status   = MUD_DEGRADED;
            return 0;
        }
    }
    if (!path->mtu.ok) {
        /* MTU binary search can stall; once RTT is established, assume max MTU */
        if (path->rtt.setup)
            path->mtu.ok = MUD_MTU_MAX - MUD_TIME_OVERHEAD;
        else {
            path->status = MUD_PROBING;
            return 0;
        }
    }
    if (path->tx.loss > path->conf.loss_limit ||
        path->rx.loss > path->conf.loss_limit) {
        path->status = MUD_LOSSY;
        return 0;
    }
    if (path->conf.state == MUD_PASSIVE &&
        mud_timeout(mud->last_recv_time, path->rx.time, path->conf.beat * 3)) {
        path->status = MUD_WAITING;
        return 0;
    }
    if (path->conf.pref > mud->pref) {
        path->status = MUD_READY;
        return 0;
    }
    path->status = MUD_RUNNING;
    return 1;
}

/* ─── 경로 선택 (가중 라운드로빈) ──────────────────────────── */

static struct mud_path *
mud_select_path(struct mud *mud, uint16_t cursor)
{
    uint64_t k = ((uint64_t)cursor * mud->rate) >> 16;

    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];
        if (path->status != MUD_RUNNING) continue;
        if (k < path->tx.rate) return path;
        k -= path->tx.rate;
    }
    return NULL;
}

/* ─── 윈도우 갱신 ────────────────────────────────────────────── */

static void
mud_update_window(struct mud *mud, uint64_t now)
{
    if (!mud->window_time) {
        mud->window      = 0;
        mud->window_time = now;
        return;
    }
    uint64_t elapsed = MUD_TIME_MASK(now - mud->window_time);
    if (elapsed < MUD_ONE_MSEC) return;

    mud->window_time = now;
    mud->window += mud->rate * elapsed / MUD_ONE_SEC;

    uint64_t window_max = mud->rate * 100 * MUD_ONE_MSEC / MUD_ONE_SEC;
    if (window_max < 524288) window_max = 524288;  /* minimum 512KB floor */
    if (mud->window > window_max) mud->window = window_max;
}

/* ─── Public API ─────────────────────────────────────────────── */

static int
mud_sso_int(int fd, int level, int optname, int opt)
{
    return setsockopt(fd, level, optname, &opt, sizeof(opt));
}

struct mud *
mud_create(union mud_sockaddr *addr)
{
    struct mud *mud = (struct mud *)calloc(1, sizeof(struct mud));
    if (!mud) return NULL;

    mud->capacity = MUD_PATH_MAX;
    mud->paths    = (struct mud_path *)calloc(mud->capacity, sizeof(struct mud_path));
    if (!mud->paths) { free(mud); return NULL; }

    mud->sq = (struct mud_send_slot *)calloc(MUD_SEND_QUEUE_CAP, sizeof(struct mud_send_slot));
    if (!mud->sq) { free(mud->paths); free(mud); return NULL; }
    mud->sq_msgs = (struct mmsghdr *)calloc(MUD_SEND_QUEUE_CAP, sizeof(struct mmsghdr));
    if (!mud->sq_msgs) { free(mud->sq); free(mud->paths); free(mud); return NULL; }
    mud->sq_len = 0;

    mud->rq = (struct mud_recv_slot *)calloc(MUD_RECV_QUEUE_CAP, sizeof(struct mud_recv_slot));
    if (!mud->rq) { free(mud->sq_msgs); free(mud->sq); free(mud->paths); free(mud); return NULL; }
    mud->rq_msgs = (struct mmsghdr *)calloc(MUD_RECV_QUEUE_CAP, sizeof(struct mmsghdr));
    if (!mud->rq_msgs) { free(mud->rq); free(mud->sq_msgs); free(mud->sq); free(mud->paths); free(mud); return NULL; }
    /* rq_msgs[i]가 rq[i]의 버퍼를 가리키도록 초기화 */
    for (int i = 0; i < MUD_RECV_QUEUE_CAP; i++) {
        mud->rq[i].iov.iov_base                = mud->rq[i].buf;
        mud->rq[i].iov.iov_len                 = sizeof(mud->rq[i].buf);
        mud->rq_msgs[i].msg_hdr.msg_name       = &mud->rq[i].remote;
        mud->rq_msgs[i].msg_hdr.msg_namelen    = sizeof(mud->rq[i].remote);
        mud->rq_msgs[i].msg_hdr.msg_iov        = &mud->rq[i].iov;
        mud->rq_msgs[i].msg_hdr.msg_iovlen     = 1;
        mud->rq_msgs[i].msg_hdr.msg_control    = mud->rq[i].ctrl;
        mud->rq_msgs[i].msg_hdr.msg_controllen = sizeof(mud->rq[i].ctrl);
    }
    mud->rq_len = 0;
    mud->rq_idx = 0;

    mud->conf.keepalive    = 25 * MUD_ONE_SEC;
    mud->conf.timetolerance = 10 * MUD_ONE_SEC;

    /* base_time: monotonic 기준점 */
    struct timespec ts_mono, ts_real;
    clock_gettime(CLOCK_MONOTONIC,  &ts_mono);
    clock_gettime(CLOCK_REALTIME,   &ts_real);
    uint64_t real_us = (uint64_t)ts_real.tv_sec  * MUD_ONE_SEC
                     + (uint64_t)ts_real.tv_nsec  / MUD_ONE_MSEC;
    uint64_t mono_us = (uint64_t)ts_mono.tv_sec  * MUD_ONE_SEC
                     + (uint64_t)ts_mono.tv_nsec  / MUD_ONE_MSEC;
    mud->base_time = real_us - mono_us;

    int fd;
    socklen_t addrlen;

    if (addr->sa.sa_family == AF_INET) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        addrlen = sizeof(struct sockaddr_in);
    } else {
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
        addrlen = sizeof(struct sockaddr_in6);
    }
    if (fd < 0) goto err;

    mud_sso_int(fd, SOL_SOCKET, SO_REUSEADDR, 1);
    mud_sso_int(fd, SOL_SOCKET, SO_REUSEPORT, 1);
#if MUD_V4V6
    mud_sso_int(fd, IPPROTO_IPV6, IPV6_V6ONLY, 0);
#endif
    mud_sso_int(fd, IPPROTO_IP,   MUD_PKTINFO, 1);
    mud_sso_int(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, 1);

#ifdef MUD_DFRAG
    mud_sso_int(fd, IPPROTO_IP, MUD_DFRAG, IP_PMTUDISC_PROBE);
#endif

    {
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    if (bind(fd, &addr->sa, addrlen)) goto err_fd;

    mud->fd = fd;
    return mud;

err_fd:
    close(fd);
err:
    free(mud->paths);
    free(mud);
    return NULL;
}

void
mud_delete(struct mud *mud)
{
    if (!mud) return;
    if (mud->fd >= 0) close(mud->fd);
    free(mud->paths);
    free(mud);
}

void
mud_set_obfs(struct mud *mud,
             mud_obfs_enc_t  enc_fn,
             mud_obfs_dec_t  dec_fn,
             mud_obfs_init_t init_fn,
             void           *obfs_ctx)
{
    mud->obfs_enc     = enc_fn;
    mud->obfs_dec     = dec_fn;
    mud->obfs_init_fn = init_fn;
    mud->obfs_ctx     = obfs_ctx;
}

int
mud_send_initials(struct mud *mud)
{
    if (!mud->obfs_init_fn) return 0;

    int count = 0;
    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];
        if (path->conf.state < MUD_UP) continue;

        unsigned char init_buf[1300];
        int init_len = mud->obfs_init_fn(mud->obfs_ctx,
                                          init_buf, (int)sizeof(init_buf),
                                          0 /* is_server=0: Client Initial */);
        if (init_len <= 0) continue;

        socklen_t rlen = (path->conf.remote.sa.sa_family == AF_INET)
            ? (socklen_t)sizeof(struct sockaddr_in)
            : (socklen_t)sizeof(struct sockaddr_in6);
        ssize_t r = sendto(mud->fd, init_buf, (size_t)init_len, MSG_DONTWAIT,
                           (const struct sockaddr *)&path->conf.remote, rlen);
        if (r > 0) count++;
    }
    return count;
}

int
mud_set(struct mud *mud, struct mud_conf *conf)
{
    if (conf->keepalive)     mud->conf.keepalive     = conf->keepalive;
    if (conf->timetolerance) mud->conf.timetolerance = conf->timetolerance;
    return 0;
}

int
mud_set_path(struct mud *mud, struct mud_path_conf *conf)
{
    if (conf->state < MUD_EMPTY || conf->state >= MUD_LAST) {
        errno = EINVAL; return -1;
    }
    struct mud_path *path = mud_get_path(mud, &conf->local, &conf->remote,
                                         conf->state);
    if (!path) { errno = ENOBUFS; return -1; }

    path->conf      = *conf;
    path->remote    = conf->remote;

    if (!path->conf.beat)       path->conf.beat       = mud_random_beat(path);
    if (!path->conf.loss_limit) path->conf.loss_limit = 255;

    if (!path->tx.rate)
        path->tx.rate = path->conf.tx_max_rate ? path->conf.tx_max_rate : 10000000ULL;  /* 10MB/s initial */

    /* 새 경로 MTU 초기화 */
    if (!path->mtu.min) {
        path->mtu.min   = MUD_MTU_MIN;
        path->mtu.max   = MUD_MTU_MAX;
        path->mtu.probe = MUD_MTU_MAX;
    }
    return 0;
}

int
mud_update(struct mud *mud)
{
    unsigned pref      = 255;
    unsigned next_pref = 255;
    uint64_t rate      = 0;
    size_t   mtu       = 0;
    uint64_t now       = mud_now(mud);

    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];
        if (path->conf.state == MUD_EMPTY) continue;

        if (mud_path_update(mud, path, now)) {
            if (next_pref > path->conf.pref && path->conf.pref > mud->pref)
                next_pref = path->conf.pref;
            if (pref > path->conf.pref)
                pref = path->conf.pref;
            if (path->status == MUD_RUNNING)
                rate += path->tx.rate;
        }
        if (path->mtu.ok) {
            if (!mtu || mtu > path->mtu.ok)
                mtu = path->mtu.ok;
        }
        mud_path_track(mud, path, now);
    }

    if (!rate) {
        mud->pref = next_pref;
        for (unsigned i = 0; i < mud->capacity; i++) {
            struct mud_path *path = &mud->paths[i];
            if (mud_path_update(mud, path, now) &&
                path->status == MUD_RUNNING)
                rate += path->tx.rate;
        }
    } else {
        mud->pref = pref;
    }

    mud->rate = rate;
    mud->mtu  = mtu;
    mud_update_window(mud, now);

    /* probe 메시지 배치 플러시 */
    mud_send_flush(mud);

    return mud->window < 1500;
}

int
mud_send_wait(struct mud *mud)
{
    return mud->window < 1500;
}

int
mud_send(struct mud *mud, const void *data, size_t size)
{
    if (!size) return 0;
    if (mud->window < 1500) { errno = EAGAIN; return -1; }

    unsigned char packet[MUD_PKT_MAX_SIZE];
    uint64_t now = mud_now(mud);

    /* 시간 헤더 + 페이로드 */
    size_t pkt_size = MUD_TIME_SIZE + size;
    if (pkt_size > sizeof(packet)) { errno = EMSGSIZE; return -1; }

    mud_store(packet, now, MUD_TIME_SIZE);
    memcpy(packet + MUD_TIME_SIZE, data, size);

    /* 경로 선택: 마지막 2바이트를 커서로 사용 */
    uint16_t cursor;
    memcpy(&cursor, (const char *)data + (size > 2 ? size - 2 : 0),
           size >= 2 ? 2 : 1);

    struct mud_path *path = mud_select_path(mud, cursor);
    if (!path) { errno = EAGAIN; return -1; }

    path->idle = now;
    return mud_send_path(mud, path, now, packet, pkt_size, 0);
}

int
mud_send_all(struct mud *mud, const void *data, size_t size)
{
    if (!size) return 0;
    if (mud->window < 1500) { errno = EAGAIN; return -1; }

    unsigned char packet[MUD_PKT_MAX_SIZE];
    uint64_t now = mud_now(mud);

    size_t pkt_size = MUD_TIME_SIZE + size;
    if (pkt_size > sizeof(packet)) { errno = EMSGSIZE; return -1; }

    mud_store(packet, now, MUD_TIME_SIZE);
    memcpy(packet + MUD_TIME_SIZE, data, size);

    /* 모든 RUNNING 경로에 동일 패킷 전송.
     * mud_send_path()가 window를 감소시키므로 매 호출 전 저장 후 복원하고
     * 최종적으로 한 번만 차감. */
    uint64_t saved_window = mud->window;
    int sent = 0;

    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];
        if (path->status != MUD_RUNNING) continue;
        mud->window = saved_window;  /* 복원 후 개별 전송 */
        path->idle = now;
        if (mud_send_path(mud, path, now, packet, pkt_size, 0) >= 0)
            sent++;
    }

    if (!sent) {
        mud->window = saved_window;
        errno = EAGAIN;
        return -1;
    }

    /* window는 논리적 패킷 1개 크기만큼만 차감 */
    if (saved_window > pkt_size)
        mud->window = saved_window - pkt_size;
    else
        mud->window = 0;

    return (int)size;
}

int
mud_send_next(struct mud *mud, const void *data, size_t size, unsigned dup_count)
{
    if (!size) return 0;
    if (mud->window < 1500) { errno = EAGAIN; return -1; }

    unsigned char packet[MUD_PKT_MAX_SIZE];
    uint64_t now = mud_now(mud);

    size_t pkt_size = MUD_TIME_SIZE + size;
    if (pkt_size > sizeof(packet)) { errno = EMSGSIZE; return -1; }

    mud_store(packet, now, MUD_TIME_SIZE);
    memcpy(packet + MUD_TIME_SIZE, data, size);

    /* RUNNING 경로 수집 + 전체 rate 합산 + 크레딧 적립 */
    uint64_t total_rate = 0;
    unsigned n_running  = 0;

    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *path = &mud->paths[i];
        if (path->status != MUD_RUNNING) continue;
        uint64_t r = path->tx.rate ? path->tx.rate : 1000000ULL;
        path->agg_credit += (int64_t)r;
        total_rate += r;
        n_running++;
    }

    if (!n_running) { errno = EAGAIN; return -1; }

    /* dup_count를 사용 가능한 경로 수로 클램프 */
    if (dup_count < 1)           dup_count = 1;
    if (dup_count > n_running)   dup_count = n_running;

    uint64_t saved_window = mud->window;
    int sent = 0;

    /* dup_count개 경로에 순차 전송 (크레딧 최대 경로 우선) */
    for (unsigned d = 0; d < dup_count; d++) {
        struct mud_path *best       = NULL;
        int64_t          best_cred  = INT64_MIN;

        for (unsigned i = 0; i < mud->capacity; i++) {
            struct mud_path *path = &mud->paths[i];
            if (path->status != MUD_RUNNING) continue;
            if (path->agg_credit > best_cred) {
                best_cred = path->agg_credit;
                best      = path;
            }
        }

        if (!best) break;

        /* 이 경로의 크레딧을 total_rate만큼 차감 (가중 라운드로빈 핵심).
         * 다음 선택에서 이 경로가 재선택되지 않도록 크게 감소시킴. */
        best->agg_credit -= (int64_t)total_rate;

        mud->window = saved_window;
        best->idle  = now;
        if (mud_send_path(mud, best, now, packet, pkt_size, 0) >= 0)
            sent++;
    }

    if (!sent) {
        mud->window = saved_window;
        errno = EAGAIN;
        return -1;
    }

    /* window는 논리적 패킷 1개 크기만큼만 차감 */
    if (saved_window > pkt_size)
        mud->window = saved_window - pkt_size;
    else
        mud->window = 0;

    return (int)size;
}

/* ─── 수신 슬롯 1개를 처리하는 내부 헬퍼 ──────────────────────
 * 반환값: >0 payload 크기, 0 probe/keepalive/드롭
 * ──────────────────────────────────────────────────────────────── */
static int
mud_recv_one(struct mud *mud, void *data, size_t size,
             unsigned char *raw, ssize_t raw_size,
             union mud_sockaddr *remote, struct msghdr *msg)
{
    mud_unmapv4(remote);

    unsigned char decoded[MUD_PKT_MAX_SIZE];
    int decoded_size;

    if (mud->obfs_dec) {
        decoded_size = mud->obfs_dec(mud->obfs_ctx,
                                     raw, (int)raw_size,
                                     decoded, (int)sizeof(decoded));
        if (decoded_size == -2) {
            if (mud->obfs_init_fn) {
                unsigned char init_buf[1300];
                int init_len = mud->obfs_init_fn(mud->obfs_ctx,
                                                  init_buf, (int)sizeof(init_buf),
                                                  1);
                if (init_len > 0) {
                    socklen_t rlen = (remote->sa.sa_family == AF_INET)
                        ? (socklen_t)sizeof(struct sockaddr_in)
                        : (socklen_t)sizeof(struct sockaddr_in6);
                    sendto(mud->fd, init_buf, (size_t)init_len, MSG_DONTWAIT,
                           (const struct sockaddr *)remote, rlen);
                }
            }
            return 0;
        }
        if (decoded_size <= 0) {
            if (decoded_size == 0) {
                mud->err.auth.addr  = *remote;
                mud->err.auth.time  = mud_now(mud);
                mud->err.auth.count++;
            }
            return 0;
        }
    } else {
        decoded_size = (int)raw_size;
        if (decoded_size > (int)sizeof(decoded)) return 0;
        memcpy(decoded, raw, (size_t)decoded_size);
    }

    if (decoded_size <= (int)MUD_TIME_SIZE) return 0;

    uint64_t now       = mud_now(mud);
    uint64_t sent_time = mud_load(decoded, MUD_TIME_SIZE);

    uint64_t pure_time = MUD_TIME_MASK(sent_time);
    if (MUD_TIME_MASK(now - pure_time) > mud->conf.timetolerance &&
        MUD_TIME_MASK(pure_time - now) > mud->conf.timetolerance) {
        mud->err.clocksync.addr  = *remote;
        mud->err.clocksync.time  = now;
        mud->err.clocksync.count++;
        return 0;
    }

    union mud_sockaddr local;
    if (mud_localaddr(&local, msg)) return 0;

    struct mud_path *path = mud_get_path(mud, &local, remote, MUD_PASSIVE);
    if (!path || path->conf.state <= MUD_DOWN) return 0;

    if (!path->conf.beat)       path->conf.beat       = mud_random_beat(path);
    if (!path->conf.loss_limit) path->conf.loss_limit = 200;

    if (MUD_MSG(sent_time)) {
        mud_recv_msg(mud, path, now, sent_time, decoded, (size_t)decoded_size);
        path->rx.total++;
        path->rx.time  = now;
        path->rx.bytes += (size_t)decoded_size;
        mud->last_recv_time = now;
        return 0;
    }

    /* 데이터 패킷 — duplicate 중복 제거 */
    {
        unsigned idx = mud->dedup_idx;
        for (unsigned d = 0; d < MUD_DEDUP_SIZE; d++) {
            if (!mud->dedup[d].recv_time) continue;
            if (MUD_TIME_MASK(now - mud->dedup[d].recv_time) > MUD_DEDUP_TTL) {
                mud->dedup[d].recv_time = 0;
                continue;
            }
            if (mud->dedup[d].pkt_time == pure_time)
                return 0;
        }
        mud->dedup[idx].pkt_time  = pure_time;
        mud->dedup[idx].recv_time = now;
        mud->dedup_idx = (idx + 1) % MUD_DEDUP_SIZE;
    }

    size_t payload = (size_t)decoded_size - MUD_TIME_SIZE;
    if (payload > size) return 0;

    memcpy(data, decoded + MUD_TIME_SIZE, payload);

    path->idle      = now;
    path->rx.total++;
    path->rx.time   = now;
    path->rx.bytes += (size_t)decoded_size;
    mud->last_recv_time = now;

    return (int)payload;
}

/* ─── recvmmsg 배치 수신 ─────────────────────────────────────── */

int
mud_recv_pending(struct mud *mud)
{
    return mud->rq_idx < mud->rq_len;
}

int
mud_recv(struct mud *mud, void *data, size_t size)
{
    for (;;) {
        /* 큐에 남은 항목 처리 */
        while (mud->rq_idx < mud->rq_len) {
            int idx = mud->rq_idx++;
            if (mud->rq_msgs[idx].msg_hdr.msg_flags & (MSG_TRUNC | MSG_CTRUNC))
                continue;
            ssize_t raw_size = (ssize_t)mud->rq_msgs[idx].msg_len;
            int ret = mud_recv_one(mud, data, size,
                                   mud->rq[idx].buf, raw_size,
                                   &mud->rq[idx].remote,
                                   &mud->rq_msgs[idx].msg_hdr);
            if (ret > 0) return ret;   /* 데이터 패킷 */
            if (ret == 0) return 0;    /* probe/keepalive — 호출자에게 알림 */
        }

        /* 큐 소진 → recvmmsg로 재충전 */
        mud->rq_len = 0;
        mud->rq_idx = 0;
        for (int i = 0; i < MUD_RECV_QUEUE_CAP; i++) {
            mud->rq_msgs[i].msg_hdr.msg_namelen    = sizeof(mud->rq[i].remote);
            mud->rq_msgs[i].msg_hdr.msg_controllen = sizeof(mud->rq[i].ctrl);
            mud->rq[i].iov.iov_len                 = sizeof(mud->rq[i].buf);
        }
        int nrecv = recvmmsg(mud->fd, mud->rq_msgs,
                             MUD_RECV_QUEUE_CAP, MSG_DONTWAIT, NULL);
        if (nrecv <= 0) {
            errno = EAGAIN;
            return -1;
        }
        mud->rq_len = nrecv;
        /* 루프 선두로 돌아가 큐 처리 */
    }
}

int
mud_get_fd(struct mud *mud)
{
    return mud ? mud->fd : -1;
}

size_t
mud_get_mtu(struct mud *mud)
{
    return mud->mtu;
}

int
mud_get_errors(struct mud *mud, struct mud_errors *err)
{
    *err = mud->err;
    return 0;
}

int
mud_get_paths(struct mud *mud, struct mud_paths *paths,
              union mud_sockaddr *local, union mud_sockaddr *remote)
{
    paths->count = 0;
    for (unsigned i = 0; i < mud->capacity; i++) {
        struct mud_path *p = &mud->paths[i];
        if (p->conf.state == MUD_EMPTY) continue;
        if (local  && mud_cmp_addr(&p->conf.local,  local))  continue;
        if (remote && mud_cmp_addr(&p->conf.remote, remote))  continue;
        paths->path[paths->count++] = *p;
        if (paths->count >= MUD_PATH_MAX) break;
    }
    return 0;
}
