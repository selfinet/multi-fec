/*
 * test_fec_decode_bounds.cpp — S-1 회귀 방지 (v1.0.5)
 *
 * 무검증 inner_index / type 로 FEC(RS) 디코더가 abort 하던 문제(fec_manager.cpp)를
 * 재현·검증한다. 디코더에 악성 8바이트 헤더 패킷을 직접 먹여, 수정 후에는 abort 없이
 * 조용히 드롭(-1/0 반환, ready_for_output 미설정)되는지 본다.
 *
 * Build:
 *   g++ -std=c++11 -I. -isystem libev -o t test_fec_decode_bounds.cpp \
 *       fec_manager.o rnlc.o common.o log.o my_ev.o lib/fec.o lib/rs.o crc32/Crc32.o \
 *       packet.o -lrt -lpthread
 */
#include <stdio.h>
#include <string.h>
#include "common.h"
#include "fec_manager.h"

static int g_pass = 0, g_fail = 0;
static void check(const char *name, int cond) {
    if (cond) { g_pass++; printf("  ok   %s\n", name); }
    else      { g_fail++; printf("  FAIL %s\n", name); }
}

/* build one FEC wire packet: [4B seq][1B type][1B data_num][1B redundant_num][1B inner_index][payload] */
static int make_pkt(char *buf, u32_t seq, int type, int data_num,
                    int redundant_num, int inner_index, const char *payload, int plen) {
    int i = 0;
    write_u32(buf + i, seq); i += 4;
    buf[i++] = (char)(unsigned char)type;
    buf[i++] = (char)(unsigned char)data_num;
    buf[i++] = (char)(unsigned char)redundant_num;
    buf[i++] = (char)(unsigned char)inner_index;
    if (plen > 0) { memcpy(buf + i, payload, plen); i += plen; }
    return i;
}

int main() {
    /* mode 0 (RS, type==0) 디코더 */
    g_fec_par.mode = 0;

    char pl[64];
    memset(pl, 0xAB, sizeof(pl));

    /* 케이스 1 — S-1 PoC: type=0 data_num=1 redundant_num=0 inner_index=200.
     * 수정 전에는 about_to_fec 성립 → rs_decode2(1,1,...) == -1 → assert abort.
     * 수정 후에는 상한 검사에서 -1 로 드롭되어야 한다(프로세스 생존이 곧 통과). */
    {
        fec_decode_manager_t dec;
        char buf[128];
        int n = make_pkt(buf, 0x1000, /*type*/0, /*data*/1, /*red*/0, /*inner*/200, pl, 4);
        int r = dec.input(buf, n);
        check("S-1 PoC (inner_index=200, x=1) dropped, no abort", r < 0);
        int out_n = 99; char **a; int *l;
        dec.output(out_n, a, l);
        check("S-1 PoC produced no output", out_n <= 0);
    }

    /* 케이스 2 — type 바이트가 3 (0/1 외): 거부되어야 함 */
    {
        fec_decode_manager_t dec;
        char buf[128];
        int n = make_pkt(buf, 0x2000, /*type*/3, /*data*/2, /*red*/1, /*inner*/0, pl, 4);
        int r = dec.input(buf, n);
        check("invalid type=3 rejected", r < 0);
    }

    /* 케이스 3 — inner_index == data_num+redundant_num (경계 바로 밖): 거부 */
    {
        fec_decode_manager_t dec;
        char buf[128];
        int n = make_pkt(buf, 0x3000, /*type*/0, /*data*/2, /*red*/1, /*inner*/3, pl, 4);
        int r = dec.input(buf, n);
        check("inner_index==x+y rejected", r < 0);
    }

    /* 케이스 4 — 정상 inner_index(=0) 가 바운드 검사에서 거부되지 않아야 한다.
     * input() 은 바운드/포맷 거부 시에만 -1 을 반환하므로 r==0 이면 "거부 안 됨 =
     * 복호 단계 진입"을 뜻한다(합성 페이로드라 blob 파싱까지 성공하진 않는다). */
    {
        fec_decode_manager_t dec;
        char buf[128];
        int n = make_pkt(buf, 0x4000, /*type*/0, /*data*/1, /*red*/0, /*inner*/0, pl, 4);
        int r = dec.input(buf, n);
        check("valid inner_index=0 not rejected by bounds", r == 0);
    }

    /* 케이스 5 — mode 1 (type==1) systematic 패킷은 data_num=0 으로 온다.
     * 상한 검사가 이 정상 케이스를 거부하면 안 된다(배열 한계 미만이면 통과). */
    {
        g_fec_par.mode = 1;
        fec_decode_manager_t dec;
        char buf[128];
        /* type=1, data_num=0, inner=5, payload=[2B len][data] */
        char body[8]; write_u16(body, 4); memcpy(body + 2, pl, 4);
        int n = make_pkt(buf, 0x5000, /*type*/1, /*data*/0, /*red*/0, /*inner*/5, body, 6);
        int r = dec.input(buf, n);
        check("mode1 systematic (data_num=0, inner=5) accepted", r >= 0);
        g_fec_par.mode = 0;
    }

    /* 케이스 6 — mode 1 systematic 이지만 inner_index 가 배열 한계(255) 이상: 거부.
     * inner_index 는 1바이트라 255 가 유일하게 걸리는 값이다(254 는 < max 로 정상). */
    {
        g_fec_par.mode = 1;
        fec_decode_manager_t dec;
        char buf[128];
        char body[8]; write_u16(body, 4); memcpy(body + 2, pl, 4);
        int n = make_pkt(buf, 0x6000, /*type*/1, /*data*/0, /*red*/0, /*inner*/255, body, 6);
        int r = dec.input(buf, n);
        check("mode1 systematic inner_index=255 rejected", r < 0);
        g_fec_par.mode = 0;
    }

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
