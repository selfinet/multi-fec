/*
 * test_agg_unit.c — aggregate 배분 추정 · 송신 창 유닛 테스트 (1.4.1 검토 수정, 2026-10-23)
 *
 *   1. tx.est 는 상대가 받았다고 알린 양(7/8)을 따르고 자기 송신 하한(5/4 × 보낸 양)을 따르지 않는다
 *   2. tx.rate 는 그 하한을 따른다(송신 창용)
 *   3. mud_agg_weight() 는 tx.est 를 쓴다 — 회선이 포화된 경로는 몫이 줄어든다
 *   4. 창 상한은 rate × 200 ms (최소 512 KB)
 *   5. aggregate 창 하한은 논리 패킷 크기(win_spent) 기준 5/4
 *
 * static 함수를 부르기 위해 mud_lite.c 를 통째로 include 한다 (test_path_loss_unit.c 와 같은 방식).
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
static struct mud_path g_path;

static void reset(void)
{
    memset(&g_mud,  0, sizeof(g_mud));
    memset(&g_path, 0, sizeof(g_path));
    g_path.conf.loss_limit = 200;
    g_path.tx.rate = 10000000ULL;
    g_path.tx.est  = 10000000ULL;
}

int main(void)
{
    printf("aggregate 배분 추정 · 송신 창 유닛 테스트\n");
    printf("==============================================================\n");

    /* ── 1·2. 포화 경로: 보낸 양 4 MB/s, 상대 수신 2 MB/s ─────────────── */
    reset();
    uint64_t now = 10 * MUD_ONE_SEC;
    mud_update_rl(&g_mud, &g_path, now, 0, 0, 0, 0);              /* 기준점 */
    now += MUD_ONE_SEC;
    g_path.tx.bytes += 4000000ULL;                                 /* 1초에 4 MB 보냄 */
    mud_update_rl(&g_mud, &g_path, now, 2000000ULL, 2000, 4000000ULL, 4000);
    check("tx.rate >= 5/4 x 보낸 양 (5 MB/s)", g_path.tx.rate >= 5000000ULL,
          "rate=%llu", (unsigned long long)g_path.tx.rate);
    check("tx.est = 7/8 x 상대 수신 (1.75 MB/s)",
          g_path.tx.est >= 1700000ULL && g_path.tx.est <= 1800000ULL,
          "est=%llu", (unsigned long long)g_path.tx.est);
    check("tx.est <= tx.rate", g_path.tx.est <= g_path.tx.rate, "");

    /* probe 응답(branch 2)에서 둘 다 +10% */
    uint64_t r0 = g_path.tx.rate, e0 = g_path.tx.est;
    mud_update_rl(&g_mud, &g_path, now + 100 * MUD_ONE_MSEC, 2000000ULL, 2000, 4000000ULL, 4000);
    check("branch 2: rate·est 모두 +10%",
          g_path.tx.rate == r0 + r0 / 10 && g_path.tx.est == e0 + e0 / 10,
          "rate %llu→%llu est %llu→%llu", (unsigned long long)r0,
          (unsigned long long)g_path.tx.rate, (unsigned long long)e0,
          (unsigned long long)g_path.tx.est);

    /* fixed_rate 이면 est = rate */
    reset();
    g_path.conf.fixed_rate = 1;
    g_path.tx.est = 1;
    mud_update_rl(&g_mud, &g_path, 10 * MUD_ONE_SEC, 0, 0, 0, 0);
    check("fixed_rate: est = rate", g_path.tx.est == g_path.tx.rate, "est=%llu rate=%llu",
          (unsigned long long)g_path.tx.est, (unsigned long long)g_path.tx.rate);

    /* ── 3. 가중치: est 기준, 손실 q^2 ──────────────────────────────── */
    struct mud_path a, b;
    memset(&a, 0, sizeof(a)); memset(&b, 0, sizeof(b));
    a.tx.rate = 8000000ULL; a.tx.est = 2000000ULL;   /* 포화: 많이 보냈지만 덜 전달 */
    b.tx.rate = 4000000ULL; b.tx.est = 4000000ULL;   /* 여유 */
    check("포화 경로 가중치 < 여유 경로 (est 기준)",
          mud_agg_weight(&a) < mud_agg_weight(&b),
          "a=%llu b=%llu", (unsigned long long)mud_agg_weight(&a),
          (unsigned long long)mud_agg_weight(&b));
    a.tx.est = 4000000ULL; a.tx.loss = 102;           /* 40% 손실 → q^2 = 0.36 */
    uint64_t wa = mud_agg_weight(&a);
    check("손실 40% → 가중치 ~36%", wa > 1400000ULL && wa < 1500000ULL,
          "w=%llu", (unsigned long long)wa);
    a.tx.est = 0; a.tx.rate = 3000000ULL; a.tx.loss = 0;
    check("est 0 이면 tx.rate 로 대체", mud_agg_weight(&a) == 3000000ULL,
          "w=%llu", (unsigned long long)mud_agg_weight(&a));

    /* ── 4. 창 상한 rate × 200 ms ───────────────────────────────────── */
    memset(&g_mud, 0, sizeof(g_mud));
    g_mud.rate = 10000000ULL;                         /* 10 MB/s → 상한 2 MB */
    mud_update_window(&g_mud, 1 * MUD_ONE_SEC);       /* 초기화 */
    mud_update_window(&g_mud, 3 * MUD_ONE_SEC);       /* 2초 경과 → 상한까지만 */
    check("창 상한 = rate x 200 ms", g_mud.window == 2000000ULL,
          "window=%llu", (unsigned long long)g_mud.window);
    g_mud.rate = 1000000ULL;                          /* 1 MB/s → 200 KB < 512 KB 하한 */
    g_mud.window = 0; g_mud.window_time = 1 * MUD_ONE_SEC;
    mud_update_window(&g_mud, 3 * MUD_ONE_SEC);
    check("창 상한 최소 512 KB", g_mud.window == 524288ULL,
          "window=%llu", (unsigned long long)g_mud.window);

    /* ── 5. win_spent: aggregate-duplicate(2경로) 1회 송신 = 논리 패킷 1개분 ─ */
    {
        union mud_sockaddr la; memset(&la, 0, sizeof(la));
        la.sin.sin_family = AF_INET; la.sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        struct mud *m = mud_create(&la);
        check("mud_create (loopback)", m != NULL, "");
        if (m) {
            for (int k = 0; k < 2; k++) {
                struct mud_path *p = &m->paths[k];
                p->conf.state = MUD_UP;
                p->status     = MUD_RUNNING;
                p->conf.remote.sin.sin_family = AF_INET;
                p->conf.remote.sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                p->conf.remote.sin.sin_port = htons(9);       /* discard */
                p->conf.local.sin.sin_family = AF_INET;
                p->tx.rate = p->tx.est = 1000000ULL;
            }
            m->window = 1000000ULL;
            char payload[100]; memset(payload, 7, sizeof(payload));
            int r = mud_send_next_peer(m, 0, payload, sizeof(payload), 2);
            check("aggregate-duplicate 송신 성공", r == (int)sizeof(payload), "ret=%d", r);
            check("win_spent = 논리 1개분 (6+100 B), 경로 수와 무관",
                  m->win_spent == MUD_TIME_SIZE + sizeof(payload),
                  "win_spent=%llu", (unsigned long long)m->win_spent);
            check("창 차감도 논리 1개분",
                  m->window == 1000000ULL - (MUD_TIME_SIZE + sizeof(payload)),
                  "window=%llu", (unsigned long long)m->window);
            check("agg_time 설정됨 (하한 활성)", m->agg_time != 0, "");
            m->sq_len = 0;                                     /* 실제 송신하지 않음 */
            mud_delete(m);
        }
    }

    printf("==============================================================\n");
    printf("%d/%d 통과\n", g_pass, g_pass + g_fail);
    return g_fail ? 1 : 0;
}
