/* mfgen — 가벼운 고정 레이트 UDP 부하 생성기 + 시퀀스 기반 수신 계측 (2026-10-05)
 *
 * 왜 만들었나: iperf3 3.16 의 UDP 송신은 레이트와 무관하게 1코어를 100% 바쁘게 돈다
 * (-b 5M 에서도 98%, --pacing-timer 무효). 2 vCPU VM 에서는 측정 대상의 절반을
 * 부하 생성기가 먹어 가드 임계를 잴 수 없다. 이것은 1ms 절대시각 틱마다 몫만큼 보내고 잔다.
 *
 *   mfgen tx <dst_ip> <port> <Mbps> <seconds> [pkt_bytes=1200]
 *   mfgen rx <bind_ip> <port> <seconds>
 * rx 출력: 초마다 "sec <n> rx <pkts> lost <gap> dup <d> ooo <o> mbps <x>", 끝에 "total ..."
 *   lost 는 시퀀스 공백(재정렬로 늦게 온 것은 나중에 메워져 total 에서 정정된다)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>

#define RING (1u << 22)   /* 4M 시퀀스 비트맵 = 512KB. 1200B·40Mbps 에서 약 17분 창 */
static uint8_t seen[RING / 8];

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static int tx(const char *ip, int port, double mbps, double secs, int len)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    inet_pton(AF_INET, ip, &a.sin_addr);
    if (connect(fd, (void *)&a, sizeof a)) { perror("connect"); return 1; }
    char buf[2048] = {0};
    double pps = mbps * 1e6 / 8 / len, credit = 0;
    uint64_t seq = 0, err = 0;
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    double t0 = now();
    while (now() - t0 < secs) {
        credit += pps / 1000.0;
        while (credit >= 1) {
            memcpy(buf, &seq, 8);
            if (send(fd, buf, len, 0) < 0) err++;
            seq++; credit -= 1;
        }
        t.tv_nsec += 1000000; if (t.tv_nsec >= 1000000000) { t.tv_sec++; t.tv_nsec -= 1000000000; }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL);
    }
    printf("tx total sent %lu send_err %lu\n", (unsigned long)seq, (unsigned long)err);
    return 0;
}

static int rx(const char *ip, int port, double secs)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int rb = 8 << 20; setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, sizeof rb);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    inet_pton(AF_INET, ip, &a.sin_addr);
    if (bind(fd, (void *)&a, sizeof a)) { perror("bind"); return 1; }
    char buf[2048];
    uint64_t hi = 0, uniq = 0, dup = 0, ooo = 0, s_rx = 0, s_bytes = 0, s_dup = 0, s_ooo = 0, hi_prev = 0;
    int started = 0; double t0 = now(), next = t0 + 1; int sec = 0;
    struct pollfd p = { fd, POLLIN, 0 };
    setvbuf(stdout, NULL, _IOLBF, 0);
    while (now() - t0 < secs) {
        int to = (int)((next - now()) * 1000); if (to < 0) to = 0;
        if (poll(&p, 1, to) > 0) {
            ssize_t n = recv(fd, buf, sizeof buf, 0);
            if (n >= 8) {
                uint64_t s; memcpy(&s, buf, 8);
                uint32_t k = s & (RING - 1);
                if (seen[k / 8] & (1 << (k % 8))) { dup++; s_dup++; }
                else {
                    seen[k / 8] |= 1 << (k % 8); uniq++; s_rx++; s_bytes += n;
                    if (!started || s > hi) { hi = s; started = 1; } else { ooo++; s_ooo++; }
                    /* 링 재사용 전에 RING/2 앞 슬롯을 비운다 */
                    uint32_t c = (s + RING / 2) & (RING - 1); seen[c / 8] &= ~(1 << (c % 8));
                }
            }
        }
        if (now() >= next) {
            long gap = started ? (long)(hi - hi_prev) - (long)s_rx + (sec == 0 ? 1 : 0) : 0;
            printf("sec %d rx %lu lost %ld dup %lu ooo %lu mbps %.2f\n", sec, (unsigned long)s_rx, gap,
                   (unsigned long)s_dup, (unsigned long)s_ooo, s_bytes * 8 / 1e6);
            hi_prev = hi; s_rx = s_bytes = s_dup = s_ooo = 0; sec++; next += 1;
        }
    }
    uint64_t exp = started ? hi + 1 : 0;
    printf("total expected %lu rx %lu lost %ld loss_pct %.5f dup %lu ooo %lu\n", (unsigned long)exp,
           (unsigned long)uniq, (long)(exp - uniq), exp ? (double)(exp - uniq) * 100 / exp : 0,
           (unsigned long)dup, (unsigned long)ooo);
    return 0;
}

int main(int c, char **v)
{
    if (c >= 6 && !strcmp(v[1], "tx")) return tx(v[2], atoi(v[3]), atof(v[4]), atof(v[5]), c > 6 ? atoi(v[6]) : 1200);
    if (c >= 5 && !strcmp(v[1], "rx")) return rx(v[2], atoi(v[3]), atof(v[4]));
    fprintf(stderr, "mfgen tx <ip> <port> <Mbps> <sec> [len] | mfgen rx <ip> <port> <sec>\n"); return 2;
}
