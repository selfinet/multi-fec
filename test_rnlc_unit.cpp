/*
 * test_rnlc_unit.cpp — RNLC 인코더/디코더 결정적 유닛 테스트
 *
 * 네트워크/mud 없이 매니저를 직접 구동:
 *   인코드(k개) → 일부 패킷 임의 드롭 → 디코드 → 원본 내용 일치 검증
 * k>1 가우스 소거 솔버를 결정적으로 검증한다.
 *
 * 빌드: test_rnlc_unit 타겟 (Makefile) 또는
 *   g++ -std=c++11 -I. -isystem libev -o t test_rnlc_unit.cpp \
 *       rnlc.o common.o fec_manager.o log.o lib/fec.o lib/rs.o crc32/Crc32.o -lrt -lpthread
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <vector>
#include <set>
#include <string>
#include "rnlc.h"
#include "common.h"
#include "fec_manager.h"

static int g_pass = 0, g_fail = 0;
static void check(const char *name, int cond, const char *extra = "") {
    if (cond) { g_pass++; printf("  ✓ %s %s\n", name, extra); }
    else      { g_fail++; printf("  ✗ %s %s\n", name, extra); }
}

struct enc_pkt { std::string bytes; int inner_index; };

/* 한 세대를 인코딩해 (systematic+coded) 패킷들을 수집 */
static std::vector<enc_pkt> encode_generation(rnlc_encode_manager_t &enc,
                                              const std::vector<std::string> &src) {
    std::vector<enc_pkt> out;
    for (size_t i = 0; i < src.size(); i++) {
        int n; char **arr; int *len;
        enc.input((char *)src[i].data(), (int)src[i].size());
        enc.output(n, arr, len);
        if (n > 0) {
            for (int j = 0; j < n; j++) {
                enc_pkt p;
                p.bytes.assign(arr[j], len[j]);
                p.inner_index = (unsigned char)arr[j][7];  /* 헤더 offset 7 = inner_index */
                out.push_back(p);
            }
        }
    }
    return out;
}

/* 패킷 집합을 디코더에 주입하고 복구된 원본 내용을 수집 */
static std::multiset<std::string> decode_packets(rnlc_decode_manager_t &dec,
                                                 const std::vector<enc_pkt> &pkts) {
    std::multiset<std::string> recovered;
    for (size_t i = 0; i < pkts.size(); i++) {
        std::string b = pkts[i].bytes;  /* 디코더가 in-place 수정하므로 복사본 사용 */
        int n; char **arr; int *len;
        dec.input((char *)b.data(), (int)b.size());
        dec.output(n, arr, len);
        if (n > 0)
            for (int j = 0; j < n; j++)
                recovered.insert(std::string(arr[j], len[j]));
    }
    return recovered;
}

static std::vector<std::string> make_src(int k, int seed, int minlen, int maxlen) {
    std::vector<std::string> v;
    for (int i = 0; i < k; i++) {
        int len = minlen + (seed * 131 + i * 17) % (maxlen - minlen + 1);
        std::string s;
        char head[32];
        snprintf(head, sizeof(head), "S%d_%03d|", seed, i);
        s = head;
        while ((int)s.size() < len)
            s.push_back((char)((seed * 7 + i * 3 + (int)s.size() * 5) & 0xFF));
        s.resize(len);
        v.push_back(s);
    }
    return v;
}

/* 원본 전부가 복구 집합에 존재하는지 */
static int all_present(const std::vector<std::string> &src,
                       const std::multiset<std::string> &rec) {
    for (size_t i = 0; i < src.size(); i++)
        if (rec.find(src[i]) == rec.end()) return 0;
    return 1;
}

static void set_fec(const char *ratio) {
    g_fec_par.mode = 2;
    g_fec_par.mtu = 1450;
    g_fec_par.timeout = 8 * 1000;
    g_fec_par.queue_len = 200;
    char buf[256];
    strncpy(buf, ratio, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    g_fec_par.rs_from_str(buf);
    g_fec_par.version++;  /* 매니저가 새 파라미터 clone 하도록 */
}

/* case: k개 원본 중 drop_indices 패킷을 버린 뒤 복구 여부 검증 */
static void run_drop_case(const char *title, const char *ratio, int k, int seed,
                          std::vector<int> drop_pos, int expect_recover) {
    set_fec(ratio);
    rnlc_encode_manager_t enc;
    rnlc_decode_manager_t dec;

    std::vector<std::string> src = make_src(k, seed, 20, 1200);
    std::vector<enc_pkt> all = encode_generation(enc, src);

    std::set<int> drop(drop_pos.begin(), drop_pos.end());
    std::vector<enc_pkt> survivors;
    for (size_t i = 0; i < all.size(); i++)
        if (drop.find((int)i) == drop.end())
            survivors.push_back(all[i]);

    std::multiset<std::string> rec = decode_packets(dec, survivors);
    int ok = all_present(src, rec);

    char extra[128];
    snprintf(extra, sizeof(extra), "[k=%d total=%d dropped=%d survivors=%d recovered_all=%d]",
             k, (int)all.size(), (int)drop.size(), (int)survivors.size(), ok);
    check(title, ok == expect_recover, extra);
}

int main() {
    printf("============================================================\n");
    printf("RNLC 유닛 테스트 (인코드 → 드롭 → 디코드)\n");
    printf("============================================================\n");

    /* GF(256) 산술 기본 성질 */
    rnlc_gf_init();
    int gf_ok = 1;
    for (int a = 1; a < 256; a++) {
        unsigned char inv = rnlc_gf_inv((unsigned char)a);
        if (rnlc_gf_mul((unsigned char)a, inv) != 1) { gf_ok = 0; break; }
    }
    check("GF(256): a * a^-1 == 1 (1..255)", gf_ok);

    int dist_ok = 1;  /* 분배법칙 a*(b^c)=a*b ^ a*c */
    for (int a = 0; a < 256 && dist_ok; a += 7)
        for (int b = 0; b < 256 && dist_ok; b += 11)
            for (int c = 0; c < 256 && dist_ok; c += 13) {
                unsigned char l = rnlc_gf_mul(a, b ^ c);
                unsigned char r = rnlc_gf_mul(a, b) ^ rnlc_gf_mul(a, c);
                if (l != r) dist_ok = 0;
            }
    check("GF(256): 분배법칙", dist_ok);

    printf("\n[복구 가능 케이스]\n");
    /* 10:5 → 손실 r 이하면 복구 가능 */
    run_drop_case("10:5, 무손실", "10:5", 10, 1, {}, 1);
    run_drop_case("10:5, systematic 3개 손실", "10:5", 10, 2, {0, 3, 7}, 1);
    run_drop_case("10:5, systematic 5개 손실(최대)", "10:5", 10, 3, {0, 1, 2, 3, 4}, 1);
    run_drop_case("10:5, 혼합 5개 손실(sys3+coded2)", "10:5", 10, 4, {1, 4, 9, 10, 12}, 1);
    run_drop_case("20:10, systematic 10개 손실(최대)", "20:10", 20, 5,
                  {0, 2, 4, 6, 8, 10, 12, 14, 16, 18}, 1);
    run_drop_case("8:4, coded만 손실(원본 온전)", "8:4", 8, 6, {8, 9, 10, 11}, 1);
    run_drop_case("4:2, systematic 2개 손실", "4:2", 4, 7, {0, 3}, 1);

    printf("\n[복구 불가 케이스 (손실 > r)]\n");
    /* 10:5 에서 6개 손실 → 복구 불가 (원본 일부 영구 손실) */
    run_drop_case("10:5, 6개 손실 → 복구 불가", "10:5", 10, 8,
                  {0, 1, 2, 3, 4, 5}, 0);
    run_drop_case("8:2, 3개 손실 → 복구 불가", "8:2", 8, 9, {0, 1, 2}, 0);

    printf("\n============================================================\n");
    printf("결과: %d/%d 통과 %s\n", g_pass, g_pass + g_fail,
           g_fail == 0 ? "✓ 전체 통과" : "✗ 일부 실패");
    printf("============================================================\n");
    return g_fail == 0 ? 0 : 1;
}
