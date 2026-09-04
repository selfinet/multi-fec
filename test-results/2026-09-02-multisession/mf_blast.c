/* mf_blast.c — 다중 세션 부하 생성기 (rt_multi.py 의 C 대체) · 테스트망 전용
 *
 * 왜 만들었나 (2026-09-02)
 * -----------------------
 * rt_multi.py 는 한 프로세스에서 N 세션을 `time.sleep(0.0005)` 루프로 보내고
 * N 개 수신 스레드가 GIL 을 나눠 쓴다. 검증된 범위는 **0.25 Mbps × 8 = 104 pps**
 * 뿐인데 다중 세션 지속 한계 시험은 각 4 Mbps × 4 = **1,667 pps 송신 + 1,667 수신**
 * 이 필요하다. 두 가지가 깨진다:
 *   ① 루프가 못 따라가면 캐치업 클램프가 **조용히 레이트를 깎는다**
 *      → 실효 미달을 제품 한계로 오독한다
 *   ② 생성기 CPU 가 `c` 전체 CPU 에 그대로 잡힌다. 가드 임계가 62% 인데
 *      16 Mbps 단일 세션에서 이미 45% 였다 → **하네스 비용으로 트립**한다
 * 이건 이 프로젝트가 반복해서 겪은 "하네스 손실을 피검체 결함으로 읽는" 형태다.
 *
 * 유지한 것: 토폴로지(클라 N개 → 릴레이 2개 → 서버 1개 → echo), 태그 규약
 * `S%02d#%07d`, 자기/남 태그 카운트(= 오배송 검출, §19-가 결함의 직접 신호),
 * CSV 출력 형식. 바뀐 것은 **생성기 언어뿐**이라 비교가 성립한다.
 *
 * 페이싱: CLOCK_MONOTONIC 절대 데드라인 + ppoll 타임아웃. 밀린 만큼 따라잡되
 * 0.5초 이상 밀리면 데드라인을 현재로 리셋한다(rt_multi.py 와 동일 정책 —
 * 무한 캐치업 버스트 방지). **리셋 횟수를 세어 출력한다** — 이 값이 0 이 아니면
 * 생성기가 레이트를 못 냈다는 뜻이므로 결과를 그대로 믿으면 안 된다.
 *
 * --no-clients: multi-fec 을 띄우지 않는다(하네스가 따로 띄운다).
 *
 * WG 모드 (2026-09-02 추가) — 실서비스는 **지사마다 독립 WireGuard 터널**을 쓴다.
 *   `--src-fmt`/`--dst-fmt`/`--net-base` 를 주면 세션 i 가
 *   src=`10.9.(net_base+i).2` 로 **바인딩**해서 dst=`10.9.(net_base+i).1:port` 로 쏜다.
 *   즉 트래픽이 세션별 WG 터널 안으로 들어간다. 이걸 안 주면 예전처럼 127.0.0.1 이고
 *   그러면 **WG 를 전혀 타지 않아 암복호 비용이 측정에서 빠진다**(2026-09-02 첫 다중
 *   세션 런이 그 상태였다 — 결과가 낙관적으로 치우친다).
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_SESS 64
#define BIN "/usr/sbin/multi-fec-dist"

static long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main(int argc, char **argv) {
    int      sessions = 4, size = 1200, base_port = 51861, no_clients = 0, echo_port = 0;
    double   secs = 300, mbps = 1.0;
    const char *src = NULL, *relay_a = NULL, *relay_b = NULL, *key = NULL;
    const char *mode = "duplicate", *fec = "5:1,20:4", *logdir = "/tmp/rtmulti";
    const char *src_fmt = NULL, *dst_fmt = NULL;
    int net_base = 0, dst_port = 0;

    for (int i = 1; i < argc; i++) {
        const char *o = argv[i];
        const char *v = NULL;
        /* 값이 필요한 옵션인데 인자가 없으면 조용히 기본값을 쓰지 않고 죽는다 —
         * 측정 하네스에서 "옵션이 먹은 줄 알았는데 안 먹은" 것이 가장 위험하다 */
        int needs_val = strcmp(o, "--no-clients") != 0;
        if (needs_val) {
            if (i + 1 >= argc) { fprintf(stderr, "%s 에 값이 없다\n", o); return 2; }
            v = argv[++i];
        }
        if      (!strcmp(o, "--sessions"))   sessions   = atoi(v);
        else if (!strcmp(o, "--secs"))       secs       = atof(v);
        else if (!strcmp(o, "--mbps"))       mbps       = atof(v);
        else if (!strcmp(o, "--size"))       size       = atoi(v);
        else if (!strcmp(o, "--src"))        src        = v;
        else if (!strcmp(o, "--relay-a"))    relay_a    = v;
        else if (!strcmp(o, "--relay-b"))    relay_b    = v;
        else if (!strcmp(o, "--key"))        key        = v;
        else if (!strcmp(o, "--base-port"))  base_port  = atoi(v);
        else if (!strcmp(o, "--mode"))       mode       = v;
        else if (!strcmp(o, "--fec"))        fec        = v;
        else if (!strcmp(o, "--logdir"))     logdir     = v;
        else if (!strcmp(o, "--echo-port"))  echo_port  = atoi(v);
        else if (!strcmp(o, "--src-fmt"))    src_fmt    = v;
        else if (!strcmp(o, "--dst-fmt"))    dst_fmt    = v;
        else if (!strcmp(o, "--net-base"))   net_base   = atoi(v);
        else if (!strcmp(o, "--dst-port"))   dst_port   = atoi(v);
        else if (!strcmp(o, "--no-clients")) no_clients = 1;
        else { fprintf(stderr, "unknown option: %s\n", o); return 2; }
    }
    if (sessions < 1 || sessions > MAX_SESS) { fprintf(stderr, "sessions 1..%d\n", MAX_SESS); return 2; }
    if (size < 32 || size > 60000)           { fprintf(stderr, "size 32..60000\n"); return 2; }
    if (!no_clients && (!src || !relay_a || !relay_b || !key)) {
        fprintf(stderr, "--src/--relay-a/--relay-b/--key 필요 (또는 --no-clients)\n"); return 2;
    }
    int wg_mode = (src_fmt && dst_fmt);
    if ((src_fmt || dst_fmt) && !wg_mode) {
        fprintf(stderr, "--src-fmt 와 --dst-fmt 는 함께 줘야 한다\n"); return 2;
    }
    if (wg_mode && dst_port <= 0) { fprintf(stderr, "WG 모드에는 --dst-port 가 필요하다\n"); return 2; }

    int  lport[MAX_SESS];
    pid_t kid[MAX_SESS];
    for (int i = 0; i < sessions; i++) lport[i] = no_clients ? echo_port : base_port + i;

    /* --- multi-fec 클라이언트 N개 기동 (rt_multi.py 와 동일 argv) --- */
    if (!no_clients) {
        char cmd[512];
        snprintf(cmd, sizeof cmd, "mkdir -p %s", logdir);
        if (system(cmd) != 0) fprintf(stderr, "warn: mkdir %s\n", logdir);
        for (int i = 0; i < sessions; i++) {
            char lb[64], pa[128], pb[128], lf[256];
            snprintf(lb, sizeof lb, "127.0.0.1:%d", lport[i]);
            snprintf(pa, sizeof pa, "%s:%s", src, relay_a);
            snprintf(pb, sizeof pb, "%s:%s", src, relay_b);
            snprintf(lf, sizeof lf, "%s/client%d.log", logdir, i);
            pid_t p = fork();
            if (p < 0) { perror("fork"); return 1; }
            if (p == 0) {
                if (!freopen(lf, "w", stdout)) _exit(126);
                dup2(1, 2);
                execl(BIN, BIN, "-c", "-l", lb, "--path", pa, "--path", pb,
                      "-k", key, "--obfs-mode", "quic", "--auth-interval", "60",
                      "--multipath-mode", mode, "-f", fec, "--fec-timeout", "10",
                      "--mode", "1", "--mtu", "1350", "--decode-buf", "2000",
                      "--queue-len", "500", "--sock-buf", "4096",
                      "--report", "10", "--log-level", "4", (char *)NULL);
                _exit(127);
            }
            kid[i] = p;
        }
        sleep(6);                       /* 경로 PROBING → RUNNING */
    }

    /* --- 소켓 --- */
    int fd[MAX_SESS];
    struct sockaddr_in dst[MAX_SESS];
    for (int i = 0; i < sessions; i++) {
        fd[i] = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
        if (fd[i] < 0) { perror("socket"); return 1; }
        int rb = 4 << 20;
        setsockopt(fd[i], SOL_SOCKET, SO_RCVBUF, &rb, sizeof rb);
        struct sockaddr_in la = {0};
        la.sin_family = AF_INET;
        la.sin_port = 0;
        memset(&dst[i], 0, sizeof dst[i]);
        dst[i].sin_family = AF_INET;
        if (wg_mode) {
            /* 세션 i 의 WG 터널 안에서만 통신한다. 소스 바인딩이 핵심 —
             * 바인딩하지 않으면 커널이 라우팅으로 소스를 고르고 트래픽이
             * 엉뚱한 인터페이스로 나가 측정이 조용히 무의미해진다. */
            char sa[64], da[64];
            snprintf(sa, sizeof sa, src_fmt, net_base + i);
            snprintf(da, sizeof da, dst_fmt, net_base + i);
            if (inet_pton(AF_INET, sa, &la.sin_addr) != 1)      { fprintf(stderr, "src 주소 오류: %s\n", sa); return 2; }
            if (inet_pton(AF_INET, da, &dst[i].sin_addr) != 1)  { fprintf(stderr, "dst 주소 오류: %s\n", da); return 2; }
            dst[i].sin_port = htons(dst_port);
            if (bind(fd[i], (struct sockaddr *)&la, sizeof la) < 0) {
                fprintf(stderr, "bind %s 실패: %s — WG 인터페이스가 올라와 있나?\n", sa, strerror(errno));
                return 1;
            }
        } else {
            la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(fd[i], (struct sockaddr *)&la, sizeof la) < 0) { perror("bind"); return 1; }
            dst[i].sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            dst[i].sin_port = htons(lport[i]);
        }
    }

    char *buf = malloc(size), *rx = malloc(65536);
    if (!buf || !rx) { perror("malloc"); return 1; }
    memset(buf, 'x', size);

    long long sent[MAX_SESS] = {0}, own[MAX_SESS] = {0};
    long long foreign_[MAX_SESS] = {0}, bad[MAX_SESS] = {0}, seq[MAX_SESS] = {0};
    long long resets = 0, sendfail = 0;

    double pps = mbps * 1e6 / 8.0 / (double)size;
    long long gap = (long long)(1e9 / pps);
    if (gap < 1) gap = 1;

    long long t0 = now_ns(), end = t0 + (long long)(secs * 1e9);
    long long nxt[MAX_SESS];
    for (int i = 0; i < sessions; i++) nxt[i] = t0;

    struct pollfd pf[MAX_SESS];
    for (int i = 0; i < sessions; i++) { pf[i].fd = fd[i]; pf[i].events = POLLIN; }

    long long drain_until = 0;
    for (;;) {
        long long t = now_ns();
        if (t >= end && !drain_until) drain_until = t + 4LL * 1000000000LL;  /* 인플라이트 회수 */
        if (drain_until && t >= drain_until) break;

        /* 보낼 것 */
        long long soonest = -1;
        if (!drain_until) {
            for (int i = 0; i < sessions; i++) {
                while (nxt[i] <= t) {
                    int n = snprintf(buf, 12, "S%02d#%07d", i, (int)(seq[i] % 10000000));
                    if (n > 0 && n < size) buf[n] = 'x';       /* NUL 자리 되돌림 */
                    if (sendto(fd[i], buf, size, 0, (struct sockaddr *)&dst[i], sizeof dst[i]) < 0)
                        sendfail++;
                    else sent[i]++;
                    seq[i]++;
                    nxt[i] += gap;
                    if (nxt[i] < t - 500000000LL) { nxt[i] = t; resets++; break; }
                }
                if (soonest < 0 || nxt[i] < soonest) soonest = nxt[i];
            }
        }

        /* 받을 것 */
        int timeout_ms = 0;
        if (drain_until)      timeout_ms = 50;
        else if (soonest > 0) {
            long long d = soonest - now_ns();
            timeout_ms = d <= 0 ? 0 : (int)(d / 1000000);
            if (timeout_ms > 20) timeout_ms = 20;
        }
        int nr = poll(pf, sessions, timeout_ms);
        if (nr > 0) {
            for (int i = 0; i < sessions; i++) {
                if (!(pf[i].revents & POLLIN)) continue;
                for (;;) {
                    ssize_t r = recv(fd[i], rx, 65536, 0);
                    if (r < 0) break;
                    if (r < 11 || rx[0] != 'S') { bad[i]++; continue; }
                    if (rx[1] < '0' || rx[1] > '9' || rx[2] < '0' || rx[2] > '9') { bad[i]++; continue; }
                    int sid = (rx[1] - '0') * 10 + (rx[2] - '0');
                    if (sid == i) own[i]++; else foreign_[i]++;
                }
            }
        }
    }

    if (!no_clients) {
        for (int i = 0; i < sessions; i++) kill(kid[i], SIGTERM);
        for (int i = 0; i < sessions; i++) {
            int st; 
            for (int w = 0; w < 50; w++) { if (waitpid(kid[i], &st, WNOHANG) > 0) goto reaped; usleep(100000); }
            kill(kid[i], SIGKILL); waitpid(kid[i], &st, 0);
        reaped: ;
        }
    }

    printf("session,sent,own_back,own_pct,foreign,bad\n");
    long long ts = 0, to = 0, tf = 0, tb = 0;
    for (int i = 0; i < sessions; i++) {
        double pct = sent[i] ? 100.0 * (double)own[i] / (double)sent[i] : 0.0;
        printf("%d,%lld,%lld,%.4f,%lld,%lld\n", i, sent[i], own[i], pct, foreign_[i], bad[i]);
        ts += sent[i]; to += own[i]; tf += foreign_[i]; tb += bad[i];
    }
    printf("TOTAL,%lld,%lld,%.4f,%lld,%lld\n", ts, to, ts ? 100.0 * (double)to / (double)ts : 0.0, tf, tb);
    /* 하네스 건전성 — 0 이 아니면 결과를 믿지 말 것 */
    fprintf(stderr, "pacing_resets=%lld sendfail=%lld target_pps_per_session=%.1f gap_ns=%lld\n",
            resets, sendfail, pps, gap);
    return 0;
}
