/*
 * test_select_path_unit.c — failover/단일 경로 선택이 묵은 rate 스냅샷으로 EAGAIN 을 내지 않는지 (1.4.3, 2026-11-11)
 *
 * mud_select_path() 는 k = cursor × (경로 rate 합) >> 16 으로 경로를 고른다. peer 0(client) 은 그 합을
 * mud_update() 가 100 ms 마다 찍는 mud->rate 스냅샷에서 가져왔는데, 그 사이 경로 tx.rate 가 내려가면
 * k 가 현재 합을 넘어 NULL → mud_send() EAGAIN 이 됐다(RUNNING 경로가 있는데도).
 *
 *   1. 스냅샷 > 현재 합(1.5배·2.6배)에서 모든 cursor 가 경로를 받는다
 *   2. 경로 2개일 때 비율대로 나뉜다(가중 선택 유지)
 *   3. RUNNING 경로가 없으면 NULL
 *   4. peer 태그 경로는 그 peer 에만
 *   5. mud_send() 가 EAGAIN 을 내지 않는다(창 충분, 스냅샷 2.6배)
 *
 * static 함수를 부르기 위해 mud_lite.c 를 통째로 include 한다.
 */
#include "mud_lite.c"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int g_pass = 0, g_fail = 0;

static void check(const char *name, int cond, const char *fmt, ...)
{
    va_list ap;
    printf("  %s %-58s ", cond ? "✓" : "✗", name);
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
    if (cond) g_pass++; else g_fail++;
}

static struct mud      g_mud;
static struct mud_path g_paths[4];

static void reset(unsigned n, const uint64_t *rates)
{
    memset(&g_mud, 0, sizeof(g_mud));
    memset(g_paths, 0, sizeof(g_paths));
    g_mud.paths    = g_paths;
    g_mud.capacity = 4;
    g_mud.fd       = -1;
    for (unsigned i = 0; i < n; i++) {
        g_paths[i].status  = MUD_RUNNING;
        g_paths[i].tx.rate = rates[i];
    }
}

static unsigned count_null(uint64_t peer)
{
    unsigned nulls = 0;
    for (unsigned c = 0; c < 65536; c++)
        if (!mud_select_path(&g_mud, (uint16_t)c, peer)) nulls++;
    return nulls;
}

int main(void)
{
    printf("==============================================================\n");
    printf("mud_select_path — 묵은 rate 스냅샷\n");
    printf("==============================================================\n");

    uint64_t one[1] = {1000000};
    reset(1, one);
    g_mud.rate = 1500000;                 /* 스냅샷이 현재 합의 1.5배 */
    unsigned n = count_null(0);
    check("1a. 스냅샷 1.5배 — NULL 0 / 65536", n == 0, "NULL=%u (수정 전 ~33%%)", n);

    g_mud.rate = 2600000;
    n = count_null(0);
    check("1b. 스냅샷 2.6배 — NULL 0 / 65536", n == 0, "NULL=%u (수정 전 ~61.5%%)", n);

    uint64_t two[2] = {3000000, 1000000};
    reset(2, two);
    g_mud.rate = 9000000;
    unsigned a = 0, b = 0;
    for (unsigned c = 0; c < 65536; c++) {
        struct mud_path *p = mud_select_path(&g_mud, (uint16_t)c, 0);
        if (p == &g_paths[0]) a++; else if (p == &g_paths[1]) b++;
    }
    check("2. 3:1 경로 → 선택 비율 3:1", a + b == 65536 && a > 2.9 * b && a < 3.1 * b,
          "path0=%u path1=%u", a, b);

    reset(2, two);
    g_paths[0].status = MUD_DEGRADED;
    g_paths[1].status = MUD_LOSSY;
    g_mud.rate = 4000000;
    n = count_null(0);
    check("3. RUNNING 경로 없음 → 항상 NULL", n == 65536, "NULL=%u", n);

    reset(2, two);
    g_paths[0].peer_id = 7;
    g_paths[1].peer_id = 9;
    unsigned wrong = 0;
    for (unsigned c = 0; c < 65536; c++) {
        struct mud_path *p = mud_select_path(&g_mud, (uint16_t)c, 9);
        if (p != &g_paths[1]) wrong++;
    }
    check("4. peer 9 → 그 peer 경로만", wrong == 0, "다른 경로/NULL=%u", wrong);

    reset(2, two);
    g_paths[0].peer_id = 7;
    g_paths[1].peer_id = 7;
    g_paths[1].tx.rate = 0;               /* 합이 0 이 아닌 한 NULL 없음, rate 0 경로는 안 고름 */
    unsigned zero_pick = 0;
    for (unsigned c = 0; c < 65536; c++)
        if (mud_select_path(&g_mud, (uint16_t)c, 7) == &g_paths[1]) zero_pick++;
    check("4b. rate 0 경로는 고르지 않음", zero_pick == 0, "rate0 선택=%u", zero_pick);

    /* 5. mud_send() 경로 — 창은 충분, 스냅샷만 크다 */
    reset(1, one);
    g_mud.rate   = 2600000;
    g_mud.window = 1 << 20;
    g_mud.sq      = (struct mud_send_slot *)calloc(MUD_SEND_QUEUE_CAP, sizeof(struct mud_send_slot));
    g_mud.sq_msgs = (struct mmsghdr *)calloc(MUD_SEND_QUEUE_CAP, sizeof(struct mmsghdr));
    int eagain = 0;
    for (unsigned i = 0; i < 2000; i++) {
        g_mud.sq_len = 0;                 /* 실제 송신은 하지 않는다(fd -1) — 선택만 본다 */
        g_mud.window = 1 << 20;
        unsigned char data[64];
        memset(data, 0, sizeof data);
        data[62] = (unsigned char)(i * 131);
        data[63] = (unsigned char)(i * 197 + 0x80);
        errno = 0;
        int r = mud_send(&g_mud, data, sizeof data);
        if (r < 0 && errno == EAGAIN) eagain++;
    }
    check("5. mud_send() EAGAIN 0 / 2000 (스냅샷 2.6배)", eagain == 0, "EAGAIN=%d", eagain);

    printf("==============================================================\n");
    printf("%d/%d 통과\n", g_pass, g_pass + g_fail);
    return g_fail ? 1 : 0;
}
