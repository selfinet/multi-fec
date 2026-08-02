/*
 * test_path_loss_unit.c — 경로 손실률 계산 회귀 방지 (v1.0.7, CLAUDE.md §24)
 *
 * mud_update_rl() 은 probe 가 실어온 peer 카운터와 우리 자신의 카운터를 짝지어
 * 방향별 손실률을 낸다. 수정 전에는 peer 의 송신 수와 peer 의 수신 수를 뺐다 —
 * 같은 쪽의 서로 반대 방향 카운터라 손실률이 아니라 "방향 불균형"이 나왔다.
 * probe 만 오가는 유휴에서는 양방향이 균형을 이뤄 우연히 맞았고, 트래픽이
 * 비대칭이 되는 순간 실손실 13% 인 경로를 93% 로 보고해 MUD_LOSSY 로 떨어뜨렸다.
 *
 * mud_update_rl() 은 static 이므로 mud_lite.c 를 통째로 include 해서 부른다.
 *
 * Build:
 *   gcc -std=c11 -I. -isystem libev -o t test_path_loss_unit.c -lrt -lpthread
 */
/* mud_lite.c sets its own feature-test macros; include it before anything else
 * so glibc sees them first (struct in_pktinfo is gated on _GNU_SOURCE). */
#include "mud_lite.c"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int g_pass = 0, g_fail = 0;

static void check(const char *name, int cond, const char *fmt, ...)
{
    char detail[256] = "";
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(detail, sizeof(detail), fmt, ap);
        va_end(ap);
    }
    if (cond) { g_pass++; printf("  ok   %-46s %s\n", name, detail); }
    else      { g_fail++; printf("  FAIL %-46s %s\n", name, detail); }
}

/* One probe arrival.
 *
 * own_tx/own_rx  — our own per-path counters at that moment
 * peer_tx/peer_rx— what the peer's probe reports about itself
 *
 * A window is only evaluated when >= 1s elapsed, so `now` is advanced by 2s.
 */
static void feed(struct mud *mud, struct mud_path *path,
                 uint64_t own_tx, uint64_t own_rx,
                 uint64_t peer_tx, uint64_t peer_rx)
{
    static uint64_t now = 10 * MUD_ONE_SEC;
    now += 2 * MUD_ONE_SEC;

    path->tx.total = own_tx;
    path->rx.total = own_rx;

    /* bytes arguments only drive the rate estimate; keep them proportional */
    mud_update_rl(mud, path, now,
                  peer_rx * 1000, peer_rx,     /* rx_bytes, rx_total */
                  peer_tx * 1000, peer_tx);    /* tx_bytes, tx_total */
}

static struct mud  g_mud;
static struct mud_path g_path;

static void reset(void)
{
    memset(&g_mud,  0, sizeof(g_mud));
    memset(&g_path, 0, sizeof(g_path));
    g_path.conf.loss_limit = 200;              /* 78.4% */
    g_path.conf.fixed_rate = 1;                /* keep the rate estimator quiet */
}

int main(void)
{
    printf("경로 손실률 계산 유닛 테스트 (CLAUDE.md §24)\n");
    printf("==============================================================\n");

    /* ── 1. 대칭 트래픽, 무손실 ──────────────────────────────────────── */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);                 /* prime the snapshots */
    feed(&g_mud, &g_path, 1000, 1000, 1000, 1000);
    check("대칭 무손실 → tx.loss 0", g_path.tx.loss == 0,
          "tx.loss=%llu", (unsigned long long)g_path.tx.loss);
    check("대칭 무손실 → rx.loss 0", g_path.rx.loss == 0,
          "rx.loss=%llu", (unsigned long long)g_path.rx.loss);

    /* ── 2. 상향 10% 손실: 우리가 1000 보내고 peer 가 900 받음 ────────── */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 1000, 1000, 1000, 900);
    /* 10% of 255 = 25.5 */
    check("상향 10% 손실 → tx.loss ≈ 25/255",
          g_path.tx.loss >= 22 && g_path.tx.loss <= 29,
          "tx.loss=%llu (기대 25)", (unsigned long long)g_path.tx.loss);

    /* ── 3. 하향 10% 손실: peer 가 1000 보내고 우리가 900 받음 ─────────
     *     수정 전에는 rx.loss 가 아예 대입되지 않아 항상 0 이었다.        */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 1000, 900, 1000, 1000);
    check("하향 10% 손실 → rx.loss ≈ 25/255  (수정 전 상시 0)",
          g_path.rx.loss >= 22 && g_path.rx.loss <= 29,
          "rx.loss=%llu (기대 25)", (unsigned long long)g_path.rx.loss);

    /* ── 4. 핵심 회귀: 비대칭 트래픽 ─────────────────────────────────
     *
     * 실측에서 관측된 상황. 경로는 하향 데이터만 나르고 상향은 probe 뿐:
     *   peer 가 이 창에서 1480 보냄 (하향 데이터), 90 받음 (우리 probe)
     *   우리는 100 보냈고 peer 가 그중 90 을 받음  → 실제 상향 손실 10%
     *
     * 수정 전: (peer_tx - peer_rx)/peer_tx = (1480-90)/1480 = 93.9% → 239/255
     *          → loss_limit 200 초과 → MUD_LOSSY
     * 수정 후: (our_tx - peer_rx)/our_tx   = (100-90)/100   = 10%   → 25/255
     */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 100, 1400, 1480, 90);
    check("비대칭 트래픽 → tx.loss 가 실제 상향 손실(10%)",
          g_path.tx.loss >= 22 && g_path.tx.loss <= 29,
          "tx.loss=%llu (수정 전 239)", (unsigned long long)g_path.tx.loss);
    check("비대칭 트래픽 → LOSSY 임계 미초과",
          g_path.tx.loss <= g_path.conf.loss_limit,
          "tx.loss=%llu limit=%u",
          (unsigned long long)g_path.tx.loss, g_path.conf.loss_limit);

    /* ── 5. 래치 해제: 높은 값이 찍힌 뒤 손실이 사라지면 0 으로 복귀 ──
     *
     * 수정 전에는 rx_acc > tx_acc 인 창에서 갱신을 통째로 건너뛰어 직전 값이
     * 남았다. LOSSY 경로는 송신에서 제외되므로 그 상태가 풀리지 않았다.
     */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 1000, 1000, 1000, 100);      /* 상향 90% 손실 */
    check("래치 전제: 높은 손실이 실제로 기록됨",
          g_path.tx.loss > g_path.conf.loss_limit,
          "tx.loss=%llu", (unsigned long long)g_path.tx.loss);
    /* 이후 창: 우리는 probe 만 보내고(100) peer 가 전부 받음 */
    feed(&g_mud, &g_path, 1100, 2500, 2400, 200);
    check("손실 소멸 후 tx.loss 0 복귀 (래치 해제)",
          g_path.tx.loss == 0,
          "tx.loss=%llu", (unsigned long long)g_path.tx.loss);

    /* ── 6. peer 가 우리보다 많이 받았다고 보고 → 0, 스톨 금지 ───────── */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 100, 100, 100, 500);         /* rx_acc > tx_acc */
    check("peer rx > our tx → tx.loss 0 (직전 값 유지 아님)",
          g_path.tx.loss == 0,
          "tx.loss=%llu", (unsigned long long)g_path.tx.loss);

    /* ── 7. 우리가 아무것도 안 보낸 창 → 측정 불가, 직전 값 유지 ─────── */
    reset();
    feed(&g_mud, &g_path, 0, 0, 0, 0);
    feed(&g_mud, &g_path, 1000, 1000, 1000, 900);      /* tx.loss = 25 */
    uint64_t before = g_path.tx.loss;
    feed(&g_mud, &g_path, 1000, 2000, 2000, 900);      /* our tx 증가 없음 */
    check("송신 0 인 창 → 측정 불가로 직전 값 유지",
          g_path.tx.loss == before,
          "tx.loss=%llu (직전 %llu)",
          (unsigned long long)g_path.tx.loss, (unsigned long long)before);

    printf("==============================================================\n");
    printf("%d/%d 통과\n", g_pass, g_pass + g_fail);
    return g_fail ? 1 : 0;
}
