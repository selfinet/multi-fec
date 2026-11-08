/*
 * test_send_flush_unit.c — mud_send_flush() 부분 송신 보존 유닛 테스트 (1.4.3, CLAUDE.md §33)
 *
 *   1. sendmmsg 가 일부만 보내고 EAGAIN → 나머지는 순서대로 남고, 다음 flush 에 원래 내용 그대로 나간다
 *   2. 첫 데이터그램이 자체 오류(EMSGSIZE) → 그것만 버리고 나머지를 보낸다
 *   3. EINTR → 재시도해 전부 보낸다
 *   4. 큐가 꽉 찼는데 커널이 계속 EAGAIN → mud_send_path() 가 EAGAIN 을 돌려주고 큐를 덮어쓰지 않는다
 *   5. 정상 → 전부 보내고 큐가 빈다
 *
 * sendmmsg 를 가짜로 바꾸려고 mud_lite.c 를 통째로 include 한다 (test_agg_unit.c 와 같은 방식).
 */
#define sendmmsg mock_sendmmsg
#include "mud_lite.c"
#undef sendmmsg

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int g_pass = 0, g_fail = 0;
static void check(const char *name, int cond, const char *fmt, ...)
{
    va_list ap;
    printf("  %s %-62s ", cond ? "✓" : "✗", name);
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
    if (cond) g_pass++; else g_fail++;
}

/* script: each call consumes one action. >=0: accept that many (capped), -1: fail with err */
static int  g_act[16], g_err[16], g_nact, g_iact;
static char g_sent[256]; static int g_nsent;
static int  g_bad_ptr;

int mock_sendmmsg(int fd, struct mmsghdr *v, unsigned int n, int flags)
{
    (void)fd; (void)flags;
    int a = g_iact < g_nact ? g_act[g_iact] : (int)n;
    int e = g_iact < g_nact ? g_err[g_iact] : 0;
    g_iact++;
    if (a < 0) { errno = e; return -1; }
    if (a > (int)n) a = (int)n;
    for (int i = 0; i < a; i++) {
        struct msghdr *m = &v[i].msg_hdr;
        const unsigned char *b = (const unsigned char *)m->msg_iov->iov_base;
        struct sockaddr_in *sin = (struct sockaddr_in *)m->msg_name;
        if (m->msg_iov->iov_len < 2 || b[0] != b[1] || ntohs(sin->sin_port) != 4433) g_bad_ptr++;
        g_sent[g_nsent++] = (char)b[0];
    }
    return a;
}

static struct mud      g_mud;
static struct mud_path g_path;

static void reset(void)
{
    static struct mud_send_slot sq[MUD_SEND_QUEUE_CAP];
    static struct mmsghdr       sqm[MUD_SEND_QUEUE_CAP];
    memset(&g_mud, 0, sizeof(g_mud)); memset(&g_path, 0, sizeof(g_path));
    memset(sq, 0, sizeof(sq)); memset(sqm, 0, sizeof(sqm));
    g_mud.sq = sq; g_mud.sq_msgs = sqm; g_mud.fd = -1;
    g_mud.window = 1ULL << 40;
    g_path.conf.remote.sin.sin_family = AF_INET;
    g_path.conf.remote.sin.sin_port   = htons(4433);
    g_path.conf.remote.sin.sin_addr.s_addr = htonl(0x7f000001);
    g_path.conf.local.sin.sin_family  = AF_INET;
    g_nact = g_iact = g_nsent = g_bad_ptr = 0;
}
static int enqueue(char id)
{
    unsigned char pkt[64]; memset(pkt, id, sizeof(pkt));
    return mud_send_path(&g_mud, &g_path, 1, pkt, sizeof(pkt), 0);
}
static void script(int n, const int *a, const int *e)
{
    g_nact = n; g_iact = 0;
    for (int i = 0; i < n; i++) { g_act[i] = a[i]; g_err[i] = e ? e[i] : 0; }
}

int main(void)
{
    printf("mud_send_flush 부분 송신 보존 유닛 테스트\n");
    printf("==============================================================\n");

    reset(); enqueue('A'); enqueue('B'); enqueue('C');
    { int a[] = {1, -1}, e[] = {0, EAGAIN}; script(2, a, e); }
    int r = mud_send_flush(&g_mud);
    check("1. 3개 중 1개 송신 후 EAGAIN → 반환 1, 큐 2", r == 1 && g_mud.sq_len == 2, "r=%d sq_len=%d", r, g_mud.sq_len);
    g_nact = 0; g_iact = 0;
    mud_send_flush(&g_mud);
    g_sent[g_nsent] = 0;
    check("1. 다음 flush 에 B,C 가 순서·내용 그대로", strcmp(g_sent, "ABC") == 0 && g_bad_ptr == 0 && g_mud.sq_len == 0,
          "sent=%s bad=%d", g_sent, g_bad_ptr);

    reset(); enqueue('A'); enqueue('B'); enqueue('C');
    { int a[] = {-1}, e[] = {EMSGSIZE}; script(1, a, e); }
    r = mud_send_flush(&g_mud); g_sent[g_nsent] = 0;
    check("2. 첫 데이터그램 EMSGSIZE → 그것만 버리고 B,C 송신", strcmp(g_sent, "BC") == 0 && g_mud.sq_len == 0 && r == 2,
          "sent=%s r=%d", g_sent, r);

    reset(); enqueue('A'); enqueue('B');
    { int a[] = {-1}, e[] = {EINTR}; script(1, a, e); }
    mud_send_flush(&g_mud); g_sent[g_nsent] = 0;
    check("3. EINTR → 재시도해 전부 송신", strcmp(g_sent, "AB") == 0 && g_mud.sq_len == 0, "sent=%s", g_sent);

    reset();
    for (int i = 0; i < MUD_SEND_QUEUE_CAP; i++) enqueue((char)('a' + (i % 26)));
    { int a[] = {-1, -1, -1, -1}, e[] = {EAGAIN, EAGAIN, EAGAIN, EAGAIN}; script(4, a, e); }
    errno = 0;
    r = enqueue('Z');
    check("4. 큐 꽉 참 + 커널 EAGAIN → mud_send_path -1/EAGAIN", r == -1 && errno == EAGAIN, "r=%d errno=%d", r, errno);
    check("4. 큐 내용 보존 (덮어쓰기 없음)", g_mud.sq_len == MUD_SEND_QUEUE_CAP && g_mud.sq[0].buf[0] == 'a',
          "sq_len=%d first=%c", g_mud.sq_len, g_mud.sq[0].buf[0]);

    reset(); enqueue('A'); enqueue('B'); enqueue('C');
    r = mud_send_flush(&g_mud); g_sent[g_nsent] = 0;
    check("5. 정상 → 전부 송신, 큐 비움", r == 3 && g_mud.sq_len == 0 && strcmp(g_sent, "ABC") == 0, "r=%d sent=%s", r, g_sent);

    printf("==============================================================\n");
    printf("%d/%d 통과\n", g_pass, g_pass + g_fail);
    return g_fail ? 1 : 0;
}
