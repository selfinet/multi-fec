/*
 * test_rnlc_unit.cpp — deterministic unit test for the RNLC encoder/decoder
 *
 * Drives the managers directly without network/mud:
 *   encode (k packets) → arbitrarily drop some packets → decode → verify original content matches
 * Deterministically validates the k>1 Gaussian elimination solver.
 *
 * Build: test_rnlc_unit target (Makefile), or
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

/* encode one generation and collect the (systematic+coded) packets */
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
                p.inner_index = (unsigned char)arr[j][7];  /* header offset 7 = inner_index */
                out.push_back(p);
            }
        }
    }
    return out;
}

/* inject a set of packets into the decoder and collect the recovered original content */
static std::multiset<std::string> decode_packets(rnlc_decode_manager_t &dec,
                                                 const std::vector<enc_pkt> &pkts) {
    std::multiset<std::string> recovered;
    for (size_t i = 0; i < pkts.size(); i++) {
        std::string b = pkts[i].bytes;  /* use a copy since the decoder modifies in place */
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

/* whether every original is present in the recovered set */
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
    g_fec_par.version++;  /* so the manager clones the new parameters */
}

/* case: drop the drop_indices packets among the k originals, then verify recovery */
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
    printf("RNLC unit test (encode -> drop -> decode)\n");
    printf("============================================================\n");

    /* basic GF(256) arithmetic properties */
    rnlc_gf_init();
    int gf_ok = 1;
    for (int a = 1; a < 256; a++) {
        unsigned char inv = rnlc_gf_inv((unsigned char)a);
        if (rnlc_gf_mul((unsigned char)a, inv) != 1) { gf_ok = 0; break; }
    }
    check("GF(256): a * a^-1 == 1 (1..255)", gf_ok);

    int dist_ok = 1;  /* distributive law a*(b^c)=a*b ^ a*c */
    for (int a = 0; a < 256 && dist_ok; a += 7)
        for (int b = 0; b < 256 && dist_ok; b += 11)
            for (int c = 0; c < 256 && dist_ok; c += 13) {
                unsigned char l = rnlc_gf_mul(a, b ^ c);
                unsigned char r = rnlc_gf_mul(a, b) ^ rnlc_gf_mul(a, c);
                if (l != r) dist_ok = 0;
            }
    check("GF(256): distributive law", dist_ok);

    printf("\n[recoverable cases]\n");
    /* 10:5 → recoverable if loss <= r */
    run_drop_case("10:5, lossless", "10:5", 10, 1, {}, 1);
    run_drop_case("10:5, 3 systematic lost", "10:5", 10, 2, {0, 3, 7}, 1);
    run_drop_case("10:5, 5 systematic lost (max)", "10:5", 10, 3, {0, 1, 2, 3, 4}, 1);
    run_drop_case("10:5, 5 mixed lost (sys3+coded2)", "10:5", 10, 4, {1, 4, 9, 10, 12}, 1);
    run_drop_case("20:10, 10 systematic lost (max)", "20:10", 20, 5,
                  {0, 2, 4, 6, 8, 10, 12, 14, 16, 18}, 1);
    run_drop_case("8:4, only coded lost (originals intact)", "8:4", 8, 6, {8, 9, 10, 11}, 1);
    run_drop_case("4:2, 2 systematic lost", "4:2", 4, 7, {0, 3}, 1);

    printf("\n[unrecoverable cases (loss > r)]\n");
    /* 6 lost in 10:5 → unrecoverable (some originals permanently lost) */
    run_drop_case("10:5, 6 lost -> unrecoverable", "10:5", 10, 8,
                  {0, 1, 2, 3, 4, 5}, 0);
    run_drop_case("8:2, 3 lost -> unrecoverable", "8:2", 8, 9, {0, 1, 2}, 0);

    printf("\n============================================================\n");
    printf("result: %d/%d passed %s\n", g_pass, g_pass + g_fail,
           g_fail == 0 ? "✓ all passed" : "✗ some failed");
    printf("============================================================\n");
    return g_fail == 0 ? 0 : 1;
}
