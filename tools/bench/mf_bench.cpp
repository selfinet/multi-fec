// mf_bench — multi-fec 핫패스 단일 스레드 벤치마크 (2026-10-22). 네트워크 미사용(루프백 UDP 만), 약 12초.
// 장비 간 코어 속도 비율을 multi-fec 기준으로 재려고 만들었다: 같은 바이너리를 두 장비에서 돌려 수치를 나눈다.
//   항목: RS FEC 인코드(20+4, 1350B) · RS 복구(4개 손실) · obfs 인코드/디코드(QUIC, 1350B) · memcpy · 루프백 UDP 송수신
//   빌드: make -C tools/bench   (정적 바이너리 mf_bench)
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "lib/rs.h"
#include "obfs.h"

static double now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static const double DUR = 2.0;
static const int K = 20, N = 24, SZ = 1350;

int main() {
    char host[256] = "?"; gethostname(host, sizeof host);
    printf("mf_bench host=%s  (각 항목 %.0f초, 단일 스레드)\n", host, DUR);
    static char buf[N][SZ]; char *p[N];
    for (int i = 0; i < N; i++) { p[i] = buf[i]; for (int j = 0; j < SZ; j++) buf[i][j] = (char)(rand() & 0xff); }

    // 1) RS 인코드: 20 데이터 → 4 패리티
    double t0 = now(), t; long n = 0;
    do { rs_encode2(K, N, p, SZ); n++; } while ((t = now()) - t0 < DUR);
    double enc = n * (double)K * SZ / (t - t0) / 1e6;
    printf("rs_encode 20+4 x1350B   %8.1f MB/s 데이터  (%7.0f 그룹/s)\n", enc, n / (t - t0));
    { unsigned long long h = 1469598103934665603ULL;   // 패리티 해시 — 구현이 달라도 같아야 한다(호환 확인)
      for (int i = K; i < N; i++) for (int j = 0; j < SZ; j++) { h ^= (unsigned char)buf[i][j]; h *= 1099511628211ULL; }
      printf("parity hash              %016llx\n", h); }

    // 2) RS 복구: 데이터 4개 손실 → 패리티로 복원
    static char save[4][SZ];
    for (int i = 0; i < 4; i++) memcpy(save[i], buf[i], SZ);
    t0 = now(); n = 0;
    do {
        char *q[N]; for (int i = 0; i < N; i++) q[i] = p[i];
        for (int i = 0; i < 4; i++) q[i] = NULL;
        if (rs_decode2(K, N, q, SZ) != 0) { printf("rs_decode 실패\n"); return 1; }
        for (int i = 0; i < 4; i++) memcpy(buf[i], save[i], SZ);
        n++;
    } while ((t = now()) - t0 < DUR);
    printf("rs_decode 4 손실 복구    %8.1f MB/s 데이터  (%7.0f 그룹/s)\n", n * (double)K * SZ / (t - t0) / 1e6, n / (t - t0));

    // 3) obfs 인코드/디코드 (QUIC, 1350B)
    obfs_ctx ctx; obfs_init(&ctx, "bench-key-not-secret", OBFS_MODE_QUIC);
    static char w[2048], d[2048]; uint8_t ty;
    t0 = now(); n = 0;
    do { int m = obfs_encode(&ctx, buf[0], SZ, w, sizeof w, 0); if (m <= 0) return 2; n++; } while ((t = now()) - t0 < DUR);
    printf("obfs_encode 1350B        %8.0f pkt/s  (%6.1f MB/s)\n", n / (t - t0), n * (double)SZ / (t - t0) / 1e6);
    int wl = obfs_encode(&ctx, buf[0], SZ, w, sizeof w, 0);
    t0 = now(); n = 0;
    do { int m = obfs_decode(&ctx, w, wl, d, sizeof d, &ty); if (m != SZ) { printf("obfs_decode=%d\n", m); return 3; } n++; } while ((t = now()) - t0 < DUR);
    printf("obfs_decode 1350B        %8.0f pkt/s  (%6.1f MB/s)\n", n / (t - t0), n * (double)SZ / (t - t0) / 1e6);

    // 4) memcpy 1350B
    t0 = now(); n = 0;
    do { for (int i = 0; i < 1000; i++) memcpy(d, buf[i % N], SZ); n += 1000; } while ((t = now()) - t0 < DUR);
    printf("memcpy 1350B             %8.0f MB/s\n", n * (double)SZ / (t - t0) / 1e6);

    // 5) 루프백 UDP 송수신 1350B (커널 UDP 경로 — multi-fec 프로세스 CPU 에 함께 잡히는 몫)
    int a = socket(AF_INET, SOCK_DGRAM, 0), b = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in sa{}; sa.sin_family = AF_INET; sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK); sa.sin_port = 0;
    bind(b, (sockaddr *)&sa, sizeof sa); socklen_t sl = sizeof sa; getsockname(b, (sockaddr *)&sa, &sl);
    t0 = now(); n = 0;
    do {
        if (sendto(a, buf[0], SZ, 0, (sockaddr *)&sa, sizeof sa) != SZ) return 4;
        if (recv(b, d, sizeof d, 0) != SZ) return 5;
        n++;
    } while ((t = now()) - t0 < DUR);
    printf("udp send+recv 1350B      %8.0f pkt/s  (%6.1f MB/s)\n", n / (t - t0), n * (double)SZ / (t - t0) / 1e6);
    return 0;
}
