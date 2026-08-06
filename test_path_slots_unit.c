/* mud 경로 슬롯 재사용 유닛 검증 — mud_lite.c 를 통째로 include 해 static 함수를 직접 구동.
 * (test_path_loss_unit.c 와 같은 방식) */
#include "mud_lite.c"
#include <stdio.h>

static union mud_sockaddr mk(const char *ip, int port)
{
    union mud_sockaddr a; memset(&a, 0, sizeof(a));
    a.sin.sin_family = AF_INET;
    a.sin.sin_port   = htons((uint16_t)port);
    inet_pton(AF_INET, ip, &a.sin.sin_addr);
    return a;
}

static unsigned used(struct mud *m)
{
    unsigned n = 0;
    for (unsigned i = 0; i < m->capacity; i++)
        if (m->paths[i].conf.state != MUD_EMPTY) n++;
    return n;
}

int main(void)
{
    union mud_sockaddr bind_addr = mk("127.0.0.1", 0);
    struct mud *m = mud_create(&bind_addr);
    if (!m) { printf("mud_create 실패\n"); return 1; }

    printf("MUD_PATH_MAX = %u,  capacity = %u\n\n", MUD_PATH_MAX, m->capacity);

    union mud_sockaddr local = mk("127.0.0.1", 0);
    unsigned created = 0, null_at = 0;

    printf("%-6s %-10s %-10s %s\n", "포트", "결과", "사용슬롯", "비고");
    for (int i = 0; i < 40; i++) {
        union mud_sockaddr rem = mk("127.0.0.1", 40000 + i);
        struct mud_path *p = mud_get_path(m, &local, &rem, MUD_PASSIVE);
        if (p) {
            created++;
            p->rx.time = mud_now(m);           /* 수신한 것처럼 표시 */
        } else if (!null_at) {
            null_at = i + 1;
        }
        if (i < 3 || i == 30 || i >= 31)
            printf("%-6d %-10s %-10u %s\n", 40000 + i, p ? "슬롯확보" : "NULL",
                   used(m), p ? "" : "← 소진");
    }
    printf("\n생성 %u 개, 첫 NULL 은 %u 번째 시도\n", created,
           null_at ? null_at : 0);

    /* 5분 무수신 → 회수되는가 */
    printf("\n=== 5분 무수신 후 회수 확인 ===\n");
    uint64_t future = mud_now(m) + 6 * MUD_ONE_MIN;
    for (unsigned i = 0; i < m->capacity; i++)
        mud_path_update(m, &m->paths[i], future);
    printf("5분 경과 시뮬 후 사용슬롯 = %u\n", used(m));

    union mud_sockaddr rem2 = mk("127.0.0.1", 50000);
    struct mud_path *p2 = mud_get_path(m, &local, &rem2, MUD_PASSIVE);
    printf("회수 후 신규 경로 확보: %s\n", p2 ? "성공" : "실패");

    mud_delete(m);
    return 0;
}
