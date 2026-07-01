/*
 * rnlc.h — Random Linear Network Coding (RNLC) FEC mode (--mode 2)
 *
 * A separate FEC algorithm selectable alongside the existing Reed-Solomon (mode 0/1).
 * Block(generation)-based systematic RLNC:
 *   - One generation = k original packets (= x in -f x:y) + r coded packets (= y)
 *   - Original (systematic) packets are sent as-is → zero decode cost/latency when lossless
 *   - Coded packets are random linear combinations of the originals over GF(256)
 *   - The decoder recovers via Gaussian elimination from any k arrivals (original+coded, linearly independent)
 *
 * Wire format (same 8B header as RS, type=2):
 *   [4B seq(generation id)][1B type=2][1B k][1B r][1B inner_index]
 *   - inner_index <  k : systematic packet, payload = [2B len][data]        (natural length)
 *   - inner_index >= k : coded packet,       payload = [k coeffs][coded symbol]   (symbol_len)
 *
 * GF(256) is implemented internally in this module (principle: do not modify upstream lib/fec).
 */

#ifndef RNLC_H_
#define RNLC_H_

#include "common.h"
#include "log.h"
#include "fec_manager.h"  // fec_parameter_t, g_fec_par, max_fec_packet_num

/* Max size of one RNLC packet: header + max coefficient vector + symbol */
const int rnlc_header_len = sizeof(u32_t) + 4 * sizeof(char);  // 8
const int rnlc_pkt_max = rnlc_header_len + max_fec_packet_num + buf_len;

/* ──────────────────────────────────────────────────────────────────
 * GF(256) arithmetic (primitive polynomial 0x11d) — this module only.
 * Table initialized once on first use.
 * ────────────────────────────────────────────────────────────────── */
void rnlc_gf_init();
unsigned char rnlc_gf_mul(unsigned char a, unsigned char b);
unsigned char rnlc_gf_inv(unsigned char a);
/* dst[0..len) ^= scalar * src[0..len)  (GF(256)) */
void rnlc_gf_muladd(unsigned char *dst, const unsigned char *src, unsigned char scalar, int len);
/* buf[0..len) *= scalar */
void rnlc_gf_scale(unsigned char *buf, unsigned char scalar, int len);

/* ──────────────────────────────────────────────────────────────────
 * Encoder
 * ────────────────────────────────────────────────────────────────── */
class rnlc_encode_manager_t : not_copy_able_t {
   private:
    u32_t seq;
    fec_parameter_t fec_par;

    int counter;                              /* number of original packets gathered in the current generation */
    char *sym;                                /* [max_fec_packet_num][buf_len] original symbols (lazy) */
    int sym_len[max_fec_packet_num + 5];      /* natural length of each original symbol (2 + data_len) */

    char *out_store;                          /* output packet buffer (lazy) */
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
 * Decoder
 * Same ring-buffer + map structure as the RS decoder (fec_decode_manager_t).
 * ────────────────────────────────────────────────────────────────── */
struct rnlc_data_t {
    int used;
    u32_t seq;
    int k;
    int r;
    int idx;          /* inner_index */
    char buf[buf_len];/* payload (header excluded) */
    int len;
};

struct rnlc_gen_t {
    int k = -1;
    int r = -1;
    int fec_done = 0;
    map<int, int> group_mp;            /* inner_index -> ring-buffer index */
    char out_done[max_fec_packet_num + 10] = {0};  /* whether systematic original i has been output */
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
    char *recovered_store;   /* stores recovered symbols (lazy): max_fec_packet_num * buf_len */

    /* work buffers for Gaussian elimination (lazy) */
    unsigned char *piv_coeff;  /* [max_fec_packet_num][max_fec_packet_num] */
    char *piv_data;            /* [max_fec_packet_num][buf_len] */
    char has_piv[max_fec_packet_num + 10];

    int allocated;
    void ensure_alloc();
    char *recovered_ptr(int i) { return recovered_store + (size_t)i * buf_len; }
    unsigned char *piv_coeff_ptr(int row) { return piv_coeff + (size_t)row * max_fec_packet_num; }
    char *piv_data_ptr(int row) { return piv_data + (size_t)row * buf_len; }

    int try_decode(u32_t seq);  /* attempt Gaussian elimination; sets ready_for_output on success */

   public:
    rnlc_decode_manager_t();
    ~rnlc_decode_manager_t();

    int clear();
    int input(char *s, int len);
    int output(int &n, char **&s_arr, int *&len_arr);
};

#endif /* RNLC_H_ */
