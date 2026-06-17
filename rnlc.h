/*
 * rnlc.h — Random Linear Network Coding (RNLC) FEC 모드 (--mode 2)
 *
 * 기존 Reed-Solomon(mode 0/1)과 선택 가능한 별도 FEC 알고리즘.
 * 블록(generation) 기반 systematic RLNC:
 *   - 한 세대 = 원본 패킷 k개(= -f x:y 의 x) + 코딩 패킷 r개(= y)
 *   - 원본(systematic) 패킷은 그대로 전송 → 무손실 시 디코드 비용/지연 0
 *   - 코딩 패킷은 GF(256) 위에서 원본들의 랜덤 선형결합
 *   - 디코더는 도착한 임의의 k개(원본+코딩, 1차 독립)로 가우스 소거 복구
 *
 * 와이어 포맷 (RS와 동일한 8B 헤더, type=2):
 *   [4B seq(generation id)][1B type=2][1B k][1B r][1B inner_index]
 *   - inner_index <  k : systematic 패킷, payload = [2B len][data]        (자연 길이)
 *   - inner_index >= k : 코딩 패킷,       payload = [k 계수][코딩 심볼]   (symbol_len)
 *
 * GF(256)은 본 모듈 내부에 자체 구현한다 (upstream lib/fec 미수정 원칙).
 */

#ifndef RNLC_H_
#define RNLC_H_

#include "common.h"
#include "log.h"
#include "fec_manager.h"  // fec_parameter_t, g_fec_par, max_fec_packet_num

/* RNLC 패킷 1개 최대 크기: 헤더 + 최대 계수벡터 + 심볼 */
const int rnlc_header_len = sizeof(u32_t) + 4 * sizeof(char);  // 8
const int rnlc_pkt_max = rnlc_header_len + max_fec_packet_num + buf_len;

/* ──────────────────────────────────────────────────────────────────
 * GF(256) 산술 (primitive polynomial 0x11d) — 본 모듈 한정.
 * 첫 사용 시 1회 테이블 초기화.
 * ────────────────────────────────────────────────────────────────── */
void rnlc_gf_init();
unsigned char rnlc_gf_mul(unsigned char a, unsigned char b);
unsigned char rnlc_gf_inv(unsigned char a);
/* dst[0..len) ^= scalar * src[0..len)  (GF(256)) */
void rnlc_gf_muladd(unsigned char *dst, const unsigned char *src, unsigned char scalar, int len);
/* buf[0..len) *= scalar */
void rnlc_gf_scale(unsigned char *buf, unsigned char scalar, int len);

/* ──────────────────────────────────────────────────────────────────
 * 인코더
 * ────────────────────────────────────────────────────────────────── */
class rnlc_encode_manager_t : not_copy_able_t {
   private:
    u32_t seq;
    fec_parameter_t fec_par;

    int counter;                              /* 현재 세대에 모인 원본 패킷 수 */
    char *sym;                                /* [max_fec_packet_num][buf_len] 원본 심볼 (lazy) */
    int sym_len[max_fec_packet_num + 5];      /* 각 원본 심볼 자연 길이 (2 + data_len) */

    char *out_store;                          /* 출력 패킷 버퍼 (lazy) */
    char *output_buf[max_fec_packet_num + 100];
    int output_len[max_fec_packet_num + 100];

    int ready_for_output;
    u32_t output_n;

    my_time_t first_packet_time;
    my_time_t first_packet_time_for_output;

    ev_timer timer;
    struct ev_loop *loop = 0;
    void (*cb)(struct ev_loop *loop, struct ev_timer *watcher, int revents) = 0;

    int allocated;
    void ensure_alloc();
    char *sym_ptr(int i) { return sym + (size_t)i * buf_len; }

   public:
    rnlc_encode_manager_t();
    ~rnlc_encode_manager_t();

    void set_data(void *data) { timer.data = data; }
    void set_loop_and_cb(struct ev_loop *loop, void (*cb)(struct ev_loop *loop, struct ev_timer *watcher, int revents)) {
        this->loop = loop;
        this->cb = cb;
        ev_init(&timer, cb);
    }

    my_time_t get_first_packet_time() { return first_packet_time_for_output; }
    int get_pending_time() { return fec_par.timeout; }
    int get_type() { return 2; }

    int clear_data();
    int clear_all();

    int input(char *s, int len);
    int output(int &n, char **&s_arr, int *&len);
};

/* ──────────────────────────────────────────────────────────────────
 * 디코더
 * RS 디코더(fec_decode_manager_t)와 동일한 링버퍼 + map 구조.
 * ────────────────────────────────────────────────────────────────── */
struct rnlc_data_t {
    int used;
    u32_t seq;
    int k;
    int r;
    int idx;          /* inner_index */
    char buf[buf_len];/* payload (헤더 제외) */
    int len;
};

struct rnlc_gen_t {
    int k = -1;
    int r = -1;
    int fec_done = 0;
    map<int, int> group_mp;            /* inner_index -> 링버퍼 index */
    char out_done[max_fec_packet_num + 10] = {0};  /* systematic 원본 i 출력 완료 여부 */
};

class rnlc_decode_manager_t : not_copy_able_t {
    anti_replay_t anti_replay;
    rnlc_data_t *fec_data = 0;
    unordered_map<u32_t, rnlc_gen_t> mp;
    int index;

    int output_n;
    char **output_s_arr;
    int *output_len_arr;
    int ready_for_output;

    char *output_s_arr_buf[max_fec_packet_num + 100];
    int output_len_arr_buf[max_fec_packet_num + 100];
    char *recovered_store;   /* 복구 심볼 저장 (lazy): max_fec_packet_num * buf_len */

    /* 가우스 소거용 작업 버퍼 (lazy) */
    unsigned char *piv_coeff;  /* [max_fec_packet_num][max_fec_packet_num] */
    char *piv_data;            /* [max_fec_packet_num][buf_len] */
    char has_piv[max_fec_packet_num + 10];

    int allocated;
    void ensure_alloc();
    char *recovered_ptr(int i) { return recovered_store + (size_t)i * buf_len; }
    unsigned char *piv_coeff_ptr(int row) { return piv_coeff + (size_t)row * max_fec_packet_num; }
    char *piv_data_ptr(int row) { return piv_data + (size_t)row * buf_len; }

    int try_decode(u32_t seq);  /* 가우스 소거 시도. 성공 시 ready_for_output 설정 */

   public:
    rnlc_decode_manager_t();
    ~rnlc_decode_manager_t();

    int clear();
    int input(char *s, int len);
    int output(int &n, char **&s_arr, int *&len_arr);
};

#endif /* RNLC_H_ */
