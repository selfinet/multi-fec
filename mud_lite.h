#pragma once
/*
 * mud_lite.h — glorytun mud에서 libsodium 암호화 제거 버전
 *
 * 원본: glorytun (https://github.com/angt/glorytun), BSD 2-Clause License,
 *       Copyright (c) Adrien Gallouet <adrien@gallouet.fr>.
 *       전체 라이선스 고지는 mud_lite.c 및 THIRD_PARTY_NOTICES.md 참조.
 *
 * 제거: 키 교환, AEAD 암호화, libsodium 의존성
 * 유지: 멀티패스 경로 선택, RTT 측정, 손실률, 속도 제어, MTU 탐지
 *
 * 패킷 포맷 (wire, obfs 계층 적용 전):
 *   Data : [6B time (bit0=0)] [payload]
 *   Probe: [6B time (bit0=1)] [mud_lite_msg]
 */
#include <stddef.h>
#include <inttypes.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* obfs 계층 함수 포인터 (순환 의존 방지) */
typedef int (*mud_obfs_enc_t)(void *ctx,
                              const unsigned char *in,  int in_len,
                              unsigned char       *out, int out_max);
typedef int (*mud_obfs_dec_t)(void *ctx,
                              const unsigned char *in,  int in_len,
                              unsigned char       *out, int out_max);
/* QUIC Initial 패킷 생성 함수 포인터
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
    union mud_sockaddr   remote;   /* observed remote (NAT 반영) */
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
        uint64_t time;
        uint64_t sent;
        uint64_t set;
    } msg;
    struct {
        size_t min, max, probe, last, ok;
    } mtu;
    uint64_t idle;
    int64_t  agg_credit;  /* 가중 라운드로빈 크레딧 (aggregate 모드) */
};

struct mud_error {
    union mud_sockaddr addr;
    uint64_t time;
    uint64_t count;
};
struct mud_errors {
    struct mud_error clocksync;
    struct mud_error auth;      /* 원래 decrypt → auth 실패로 변경 */
};

struct mud_paths {
    struct mud_path path[MUD_PATH_MAX];
    unsigned        count;
};

struct mud;

struct mud *mud_create  (union mud_sockaddr *addr);
void        mud_delete  (struct mud *);

/* obfs 훅 등록 (선택적)
 * init_fn: QUIC Initial 패킷 생성 함수. NULL이면 Initial 기능 비활성화. */
void mud_set_obfs(struct mud *mud,
                  mud_obfs_enc_t  enc_fn,
                  mud_obfs_dec_t  dec_fn,
                  mud_obfs_init_t init_fn,
                  void           *obfs_ctx);

/* QUIC Client Initial 패킷을 모든 UP 경로로 전송.
 * 이벤트 루프 시작 전 호출 → DPI에게 첫 패킷을 Long Header로 제시. */
int mud_send_initials(struct mud *mud);

int mud_set      (struct mud *, struct mud_conf *);
int mud_set_path (struct mud *, struct mud_path_conf *);

int mud_update     (struct mud *);
int mud_send_wait  (struct mud *);
int mud_send_flush (struct mud *);  /* sendmmsg 큐 즉시 전송 */

int mud_recv         (struct mud *, void *, size_t);
int mud_recv_pending (struct mud *);  /* recvmmsg 큐에 미처리 항목 여부 */
int mud_send      (struct mud *, const void *, size_t);
int mud_send_all  (struct mud *, const void *, size_t);
/* 가중 라운드로빈으로 dup_count개 경로에 전송.
 * dup_count=1: 순수 집계(aggregate), dup_count>1: 집계+중복(aggregate-duplicate).
 * 경로별 tx.rate 비례로 패킷 분배 → 빠른 경로가 더 많은 패킷 처리. */
int mud_send_next (struct mud *, const void *, size_t, unsigned dup_count);

int    mud_get_errors (struct mud *, struct mud_errors *);
int    mud_get_fd     (struct mud *);
size_t mud_get_mtu    (struct mud *);
int    mud_get_paths  (struct mud *, struct mud_paths *,
                       union mud_sockaddr *, union mud_sockaddr *);
