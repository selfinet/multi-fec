/*
 * rnlc.cpp — Random Linear Network Coding (RNLC) FEC 모드 (--mode 2) 구현
 *
 * 설계 개요는 rnlc.h 참고. 핵심:
 *   - 인코더: 세대당 원본 k개 그대로 + 코딩 r개(랜덤 선형결합) 전송
 *   - 디코더: 원본은 도착 즉시 전달, 손실분은 임의의 k개(1차 독립)로 가우스 소거 복구
 */

#include "rnlc.h"
#include "common.h"
#include "log.h"

/* ──────────────────────────────────────────────────────────────────
 * GF(256), primitive polynomial 0x11d
 * ────────────────────────────────────────────────────────────────── */
static int rnlc_gf_ready = 0;
static unsigned char gf_exp_tbl[512];
static unsigned char gf_log_tbl[256];
static unsigned char gf_inv_tbl[256];

void rnlc_gf_init() {
    if (rnlc_gf_ready) return;
    unsigned int x = 1;
    for (int i = 0; i < 255; i++) {
        gf_exp_tbl[i] = (unsigned char)x;
        gf_log_tbl[x] = (unsigned char)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11d;
    }
    for (int i = 255; i < 512; i++)
        gf_exp_tbl[i] = gf_exp_tbl[i - 255];
    gf_log_tbl[0] = 0;  /* 미정의지만 0으로; mul에서 0은 별도 처리 */
    gf_inv_tbl[0] = 0;
    for (int i = 1; i < 256; i++)
        gf_inv_tbl[i] = gf_exp_tbl[255 - gf_log_tbl[i]];
    rnlc_gf_ready = 1;
}

unsigned char rnlc_gf_mul(unsigned char a, unsigned char b) {
    if (a == 0 || b == 0) return 0;
    return gf_exp_tbl[gf_log_tbl[a] + gf_log_tbl[b]];
}

unsigned char rnlc_gf_inv(unsigned char a) {
    return gf_inv_tbl[a];
}

void rnlc_gf_muladd(unsigned char *dst, const unsigned char *src, unsigned char scalar, int len) {
    if (scalar == 0) return;
    const unsigned char *t = &gf_exp_tbl[gf_log_tbl[scalar]];
    for (int i = 0; i < len; i++) {
        unsigned char s = src[i];
        if (s) dst[i] ^= t[gf_log_tbl[s]];
    }
}

void rnlc_gf_scale(unsigned char *buf, unsigned char scalar, int len) {
    if (scalar == 1) return;
    if (scalar == 0) {
        memset(buf, 0, len);
        return;
    }
    const unsigned char *t = &gf_exp_tbl[gf_log_tbl[scalar]];
    for (int i = 0; i < len; i++) {
        unsigned char s = buf[i];
        buf[i] = s ? t[gf_log_tbl[s]] : 0;
    }
}

/* ──────────────────────────────────────────────────────────────────
 * 인코더
 * ────────────────────────────────────────────────────────────────── */
rnlc_encode_manager_t::rnlc_encode_manager_t() {
    rnlc_gf_init();
    sym = 0;
    out_store = 0;
    allocated = 0;
    fec_par.clone(g_fec_par);
    clear_data();
}

rnlc_encode_manager_t::~rnlc_encode_manager_t() {
    clear_all();
    if (sym) {
        delete[] sym;
        sym = 0;
    }
    if (out_store) {
        delete[] out_store;
        out_store = 0;
    }
}

void rnlc_encode_manager_t::ensure_alloc() {
    if (allocated) return;
    sym = new char[(size_t)(max_fec_packet_num + 5) * buf_len];
    out_store = new char[(size_t)(max_fec_packet_num + 10) * rnlc_pkt_max];
    assert(sym != 0 && out_store != 0);
    allocated = 1;
}

int rnlc_encode_manager_t::clear_data() {
    counter = 0;
    ready_for_output = 0;
    output_n = 0;
    seq = (u32_t)get_fake_random_number();
    first_packet_time = 0;
    first_packet_time_for_output = 0;
    if (loop) ev_timer_stop(loop, &timer);
    return 0;
}

int rnlc_encode_manager_t::clear_all() {
    if (loop) {
        ev_timer_stop(loop, &timer);
        loop = 0;
        cb = 0;
    }
    clear_data();
    return 0;
}

int rnlc_encode_manager_t::input(char *s, int len) {
    if (counter == 0 && fec_par.version != g_fec_par.version)
        fec_par.clone(g_fec_par);

    ready_for_output = 0;
    output_n = 0;

    if (s == 0 && counter == 0) {
        /* 타임아웃인데 모인 패킷 없음 */
        return -1;
    }

    int tail_x = fec_par.get_tail().x;

    if (s != 0) {
        if (len < 0 || len > max_data_len) {
            mylog(log_warn, "rnlc enc: invalid len=%d\n", len);
            return -1;
        }
        if (len + (int)sizeof(u16_t) > fec_par.mtu) {
            mylog(log_warn, "rnlc enc: len=%d > mtu=%d, may not be delivered\n", len, fec_par.mtu);
        }
        ensure_alloc();

        if (counter == 0) {
            first_packet_time = get_current_time_us();
            const double m = 1000 * 1000;
            if (loop) {
                ev_timer_stop(loop, &timer);
                ev_timer_set(&timer, fec_par.timeout / m, 0);
                ev_timer_start(loop, &timer);
            }
        }

        assert(counter < tail_x);
        char *p = sym_ptr(counter);
        write_u16(p, (u16_t)len);
        memcpy(p + sizeof(u16_t), s, len);
        sym_len[counter] = (int)sizeof(u16_t) + len;
        counter++;
    }

    int flush = 0;
    if (s == 0) flush = 1;             /* 타임아웃 → 부분 세대 전송 */
    if (counter == tail_x) flush = 1;  /* 세대 가득 */
    if (!flush) return 0;

    /* ── flush: 세대 빌드 ── */
    int k = counter;
    int r = fec_par.rs_par[k - 1].y;
    if (k + r > max_fec_packet_num) r = max_fec_packet_num - k;
    if (r < 0) r = 0;

    int symbol_len = 0;
    for (int i = 0; i < k; i++)
        if (sym_len[i] > symbol_len) symbol_len = sym_len[i];
    /* 코딩용으로 각 원본 심볼을 symbol_len까지 0패딩 */
    for (int i = 0; i < k; i++)
        memset(sym_ptr(i) + sym_len[i], 0, symbol_len - sym_len[i]);

    int out_i = 0;

    /* systematic 패킷 (자연 길이) */
    for (int i = 0; i < k; i++) {
        char *o = out_store + (size_t)out_i * rnlc_pkt_max;
        int idx = 0;
        write_u32(o, seq);
        idx += sizeof(u32_t);
        o[idx++] = (unsigned char)2;  /* type=RNLC */
        o[idx++] = (unsigned char)k;
        o[idx++] = (unsigned char)r;
        o[idx++] = (unsigned char)i;  /* inner_index = i < k */
        memcpy(o + idx, sym_ptr(i), sym_len[i]);
        output_buf[out_i] = o;
        output_len[out_i] = idx + sym_len[i];
        out_i++;
    }

    /* 코딩 패킷 (symbol_len 고정, 앞에 k 계수) */
    for (int j = 0; j < r; j++) {
        char *o = out_store + (size_t)out_i * rnlc_pkt_max;
        int idx = 0;
        write_u32(o, seq);
        idx += sizeof(u32_t);
        o[idx++] = (unsigned char)2;
        o[idx++] = (unsigned char)k;
        o[idx++] = (unsigned char)r;
        o[idx++] = (unsigned char)(k + j);  /* inner_index >= k */

        unsigned char *coeff = (unsigned char *)(o + idx);
        /* Cauchy 계수: P[j][c] = 1/((k+j) XOR c).
         * x_j=k+j (코딩 r행), y_c=c (k열) — 범위 분리로 x_j^y_c != 0 보장(gf_inv 정의).
         * systematic [I|P]가 Cauchy면 MDS → 임의의 k개 수신 시 항상 복구(RS와 동등).
         * 기존 랜덤 계수의 rank 결핍(여유분==손실수일 때 ~0.4% 복구 실패) 제거.
         * 전제 k+r<=255는 위 r 클램프(max_fec_packet_num)로 이미 보장됨. */
        unsigned char xj = (unsigned char)(k + j);
        for (int c = 0; c < k; c++)
            coeff[c] = rnlc_gf_inv((unsigned char)(xj ^ (unsigned char)c));
        idx += k;

        char *coded = o + idx;
        memset(coded, 0, symbol_len);
        for (int i = 0; i < k; i++)
            rnlc_gf_muladd((unsigned char *)coded, (unsigned char *)sym_ptr(i), coeff[i], symbol_len);

        output_buf[out_i] = o;
        output_len[out_i] = idx + symbol_len;
        out_i++;
    }

    if (debug_fec_enc)
        mylog(log_debug, "[rnlc enc]seq=%08x k=%d r=%d symlen=%d n=%d\n", seq, k, r, symbol_len, out_i);
    else
        mylog(log_trace, "[rnlc enc]seq=%08x k=%d r=%d symlen=%d n=%d\n", seq, k, r, symbol_len, out_i);

    ready_for_output = 1;
    output_n = out_i;
    first_packet_time_for_output = first_packet_time;
    first_packet_time = 0;
    seq++;
    counter = 0;
    if (loop) ev_timer_stop(loop, &timer);
    return 0;
}

int rnlc_encode_manager_t::output(int &n, char **&s_arr, int *&len) {
    if (!ready_for_output) {
        n = -1;
        len = 0;
        s_arr = 0;
    } else {
        n = output_n;
        len = output_len;
        s_arr = output_buf;
        ready_for_output = 0;
    }
    return 0;
}

/* ──────────────────────────────────────────────────────────────────
 * 디코더
 * ────────────────────────────────────────────────────────────────── */
rnlc_decode_manager_t::rnlc_decode_manager_t() {
    rnlc_gf_init();
    fec_data = 0;
    recovered_store = 0;
    piv_coeff = 0;
    piv_data = 0;
    allocated = 0;
    index = 0;
    output_n = 0;
    output_s_arr = 0;
    output_len_arr = 0;
    ready_for_output = 0;
}

rnlc_decode_manager_t::~rnlc_decode_manager_t() {
    if (fec_data) delete[] fec_data;
    if (recovered_store) delete[] recovered_store;
    if (piv_coeff) delete[] piv_coeff;
    if (piv_data) delete[] piv_data;
}

void rnlc_decode_manager_t::ensure_alloc() {
    if (allocated) return;
    fec_data = new rnlc_data_t[fec_buff_num + 5];
    recovered_store = new char[(size_t)(max_fec_packet_num + 5) * buf_len];
    piv_coeff = new unsigned char[(size_t)(max_fec_packet_num + 5) * max_fec_packet_num];
    piv_data = new char[(size_t)(max_fec_packet_num + 5) * buf_len];
    assert(fec_data && recovered_store && piv_coeff && piv_data);
    for (int i = 0; i < (int)fec_buff_num; i++)
        fec_data[i].used = 0;
    anti_replay.clear();
    mp.clear();
    mp.rehash(fec_buff_num * 3);
    allocated = 1;
}

int rnlc_decode_manager_t::clear() {
    anti_replay.clear();
    mp.clear();
    if (allocated) {
        mp.rehash(fec_buff_num * 3);
        for (int i = 0; i < (int)fec_buff_num; i++)
            fec_data[i].used = 0;
    }
    ready_for_output = 0;
    index = 0;
    return 0;
}

int rnlc_decode_manager_t::input(char *s, int len) {
    assert(s != 0);

    ready_for_output = 0;
    output_n = 0;

    if (len < rnlc_header_len) {
        mylog(log_warn, "rnlc dec: len=%d too short\n", len);
        return -1;
    }

    int idx = 0;
    u32_t seq = read_u32(s + idx);
    idx += sizeof(u32_t);
    int type = (unsigned char)s[idx++];
    int k = (unsigned char)s[idx++];
    int r = (unsigned char)s[idx++];
    int inner_index = (unsigned char)s[idx++];
    int plen = len - idx;

    if (type != 2) {
        mylog(log_warn, "rnlc dec: type=%d!=2\n", type);
        return -1;
    }
    if (k < 1 || k > max_fec_packet_num) {
        mylog(log_warn, "rnlc dec: bad k=%d\n", k);
        return -1;
    }
    if (plen < 0 || plen + 100 >= buf_len) {
        mylog(log_warn, "rnlc dec: bad plen=%d\n", plen);
        return -1;
    }
    if (inner_index < 0 || inner_index >= k + r) {
        mylog(log_warn, "rnlc dec: bad inner_index=%d (k=%d r=%d)\n", inner_index, k, r);
        return -1;
    }
    if (inner_index >= k && plen < k) {
        mylog(log_warn, "rnlc dec: coded plen=%d < k=%d\n", plen, k);
        return -1;
    }

    if (!anti_replay.is_vaild(seq)) {
        mylog(log_trace, "rnlc dec: replay seq=%u\n", seq);
        return 0;
    }

    ensure_alloc();

    {
        rnlc_gen_t &gen = mp[seq];
        if (gen.fec_done != 0) {
            mylog(log_debug, "rnlc dec: gen already done seq=%u\n", seq);
            return -1;
        }
        if (gen.k == -1) {
            gen.k = k;
            gen.r = r;
        } else if (gen.k != k) {
            mylog(log_warn, "rnlc dec: k mismatch seq=%u\n", seq);
            return -1;
        }
        if (gen.group_mp.find(inner_index) != gen.group_mp.end()) {
            mylog(log_debug, "rnlc dec: dup inner_index=%d\n", inner_index);
            return -1;
        }
    }

    /* 링버퍼 슬롯 회수 */
    if (fec_data[index].used != 0) {
        u32_t old = fec_data[index].seq;
        anti_replay.set_invaild(old);
        auto it = mp.find(old);
        if (it != mp.end()) mp.erase(it);
        if (old == seq) {
            mylog(log_warn, "rnlc dec: ring wrap hit own seq=%u\n", seq);
            return -1;
        }
    }

    fec_data[index].used = 1;
    fec_data[index].seq = seq;
    fec_data[index].k = k;
    fec_data[index].r = r;
    fec_data[index].idx = inner_index;
    memcpy(fec_data[index].buf, s + idx, plen);
    fec_data[index].len = plen;

    rnlc_gen_t &gen = mp[seq];
    gen.group_mp[inner_index] = index;

    /* fast path: systematic 패킷은 도착 즉시 전달 */
    if (inner_index < k && !gen.out_done[inner_index]) {
        if (plen >= (int)sizeof(u16_t)) {
            int dlen = read_u16(fec_data[index].buf);
            if (dlen >= 0 && dlen <= max_data_len && dlen + (int)sizeof(u16_t) <= plen) {
                output_s_arr_buf[output_n] = fec_data[index].buf + sizeof(u16_t);
                output_len_arr_buf[output_n] = dlen;
                output_n++;
                gen.out_done[inner_index] = 1;
            } else {
                mylog(log_warn, "rnlc dec: bad systematic dlen=%d plen=%d\n", dlen, plen);
            }
        }
    }

    /* 원본 모두 도착 → 복구 불필요 */
    int sys_cnt = 0;
    for (auto &kv : gen.group_mp)
        if (kv.first < k) sys_cnt++;

    if (sys_cnt == k) {
        gen.fec_done = 1;
        anti_replay.set_invaild(seq);
    } else if ((int)gen.group_mp.size() >= k) {
        try_decode(seq);  /* 복구분을 output_n에 추가 */
    }

    if (output_n > 0) {
        output_s_arr = output_s_arr_buf;
        output_len_arr = output_len_arr_buf;
        ready_for_output = 1;
    }

    index++;
    if (index == (int)fec_buff_num) index = 0;
    return 0;
}

/* 가우스 소거(full pivoting)로 세대 복구 시도. 성공 시 누락 원본을 output에 추가. */
int rnlc_decode_manager_t::try_decode(u32_t seq) {
    rnlc_gen_t &gen = mp[seq];
    int k = gen.k;

    /* symbol_len = 수신 행들로부터 추정 (코딩 패킷이 곧 인코더의 symbol_len) */
    int symbol_len = 0;
    for (auto &kv : gen.group_mp) {
        int ri = kv.second;
        int slen = (kv.first < k) ? fec_data[ri].len : (fec_data[ri].len - k);
        if (slen > symbol_len) symbol_len = slen;
    }
    if (symbol_len <= 0 || symbol_len + 10 > buf_len) {
        mylog(log_warn, "rnlc dec: bad symbol_len=%d\n", symbol_len);
        return -1;
    }

    /* 작업 행렬 구성: 각 수신 패킷 → (계수[k] | 데이터[symbol_len]) */
    int nrows = 0;
    for (auto &kv : gen.group_mp) {
        if (nrows >= max_fec_packet_num) break;
        int inner = kv.first;
        int ri = kv.second;
        unsigned char *crow = piv_coeff_ptr(nrows);
        char *drow = piv_data_ptr(nrows);
        memset(crow, 0, k);
        memset(drow, 0, symbol_len);
        if (inner < k) {
            crow[inner] = 1;
            memcpy(drow, fec_data[ri].buf, fec_data[ri].len);  /* 자연 길이, 나머지 0패딩 */
        } else {
            memcpy(crow, fec_data[ri].buf, k);
            int slen = fec_data[ri].len - k;
            memcpy(drow, fec_data[ri].buf + k, slen);
        }
        nrows++;
    }

    /* order[] 인덱스로 행 스왑 (대용량 데이터 행 이동 회피) */
    int order[max_fec_packet_num + 5];
    for (int i = 0; i < nrows; i++) order[i] = i;
    int pivot_of_col[max_fec_packet_num + 5];
    for (int i = 0; i < k; i++) pivot_of_col[i] = -1;

    int prow = 0;
    for (int col = 0; col < k && prow < nrows; col++) {
        int sel = -1;
        for (int rr = prow; rr < nrows; rr++) {
            if (piv_coeff_ptr(order[rr])[col] != 0) {
                sel = rr;
                break;
            }
        }
        if (sel < 0) continue;  /* 이 열 피벗 없음 → rank 부족 */

        int tmp = order[prow];
        order[prow] = order[sel];
        order[sel] = tmp;

        int pr = order[prow];
        unsigned char *pc = piv_coeff_ptr(pr);
        char *pd = piv_data_ptr(pr);

        unsigned char inv = rnlc_gf_inv(pc[col]);
        rnlc_gf_scale(pc, inv, k);
        rnlc_gf_scale((unsigned char *)pd, inv, symbol_len);

        for (int rr = 0; rr < nrows; rr++) {
            if (rr == prow) continue;
            int xr = order[rr];
            unsigned char f = piv_coeff_ptr(xr)[col];
            if (f) {
                rnlc_gf_muladd(piv_coeff_ptr(xr), pc, f, k);
                rnlc_gf_muladd((unsigned char *)piv_data_ptr(xr), (unsigned char *)pd, f, symbol_len);
            }
        }
        pivot_of_col[col] = pr;
        prow++;
    }

    if (prow < k) {
        mylog(log_trace, "rnlc dec: rank=%d < k=%d, wait more\n", prow, k);
        return -1;
    }

    /* 완전 복구됨: pivot_of_col[i] 행의 데이터 = 원본 i */
    gen.fec_done = 1;
    anti_replay.set_invaild(seq);

    int recovered_cnt = 0;
    for (int i = 0; i < k; i++) {
        if (gen.out_done[i]) continue;  /* 이미 fast path로 전달됨 */
        char *src = piv_data_ptr(pivot_of_col[i]);
        char *rec = recovered_ptr(recovered_cnt);
        memcpy(rec, src, symbol_len);
        int dlen = read_u16(rec);
        if (dlen < 0 || dlen > max_data_len || dlen + (int)sizeof(u16_t) > symbol_len) {
            mylog(log_warn, "rnlc dec: recovered bad len=%d i=%d seq=%u\n", dlen, i, seq);
            continue;
        }
        output_s_arr_buf[output_n] = rec + sizeof(u16_t);
        output_len_arr_buf[output_n] = dlen;
        output_n++;
        gen.out_done[i] = 1;
        recovered_cnt++;
    }

    if (debug_fec_dec)
        mylog(log_debug, "[rnlc dec]seq=%08x k=%d recovered=%d symlen=%d\n", seq, k, recovered_cnt, symbol_len);
    else
        mylog(log_trace, "[rnlc dec]seq=%08x k=%d recovered=%d symlen=%d\n", seq, k, recovered_cnt, symbol_len);
    return 0;
}

int rnlc_decode_manager_t::output(int &n, char **&s_arr, int *&len_arr) {
    if (!ready_for_output) {
        n = -1;
        s_arr = 0;
        len_arr = 0;
    } else {
        ready_for_output = 0;
        n = output_n;
        s_arr = output_s_arr;
        len_arr = output_len_arr;
    }
    return 0;
}
