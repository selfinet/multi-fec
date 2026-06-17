/*
 * main.cpp — multi-fec: UDP proxy combining UDPspeeder FEC +
 *            glorytun multipath (mud_lite) + GFW obfuscation
 */

#include "common.h"
#include "misc.h"
#include "log.h"
#include "mf_common.h"
#include "connection.h"
#include "packet.h"
#include "fec_manager.h"

extern "C" {
#include "mud_lite.h"
}
#include "obfs.h"
#include "port_hopper.h"
#include "git_version.h"

#include <getopt.h>
#include <signal.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>

/* ─── 이벤트 루프 진입점 ──────────────────────────────────────── */

extern "C" void mf_client_event_loop(struct mud *mud, const struct obfs_ctx *obfs);
extern "C" void mf_server_event_loop(struct mud *mud, const struct obfs_ctx *obfs,
                                     int decoy_fd, address_t decoy_addr);
extern "C" void mf_relay_event_loop(address_t &listen_addr, address_t &upstream_addr,
                                    const struct obfs_ctx *obfs, address_t decoy_addr);

/* ─── 전역 변수 정의 ─────────────────────────────────────────── */

std::vector<PathSpec>      g_paths;
address_t                  g_wg_addr;
multipath_mode_t           g_multipath_mode = MULTIPATH_FAILOVER;
unsigned                   g_dup_factor     = 2;  /* aggregate-duplicate 경로 중복 수 */
std::vector<route_entry_t> g_routes;
uint8_t               g_session_id[SESSION_ID_LEN] = {0};

/* speeder common.cpp의 init_random_number_fd는 no-op으로 처리 */
void init_random_number_fd() {}

extern int  disable_anti_replay;
extern char rs_par_str[];

/* ─── 옵션 변수 ──────────────────────────────────────────────── */

static char        g_key_string[1000] = "default-key";
static bool        g_key_set          = false;   /* -k 명시적 지정 여부 */
static int         g_disable_obfs     = 0;
static obfs_mode_t g_obfs_mode        = OBFS_MODE_QUIC;  /* --obfs-mode */
static uint32_t    g_hop_interval     = 0;               /* --port-hop-interval (0=비활성화) */
static uint32_t    g_auth_interval    = 0;               /* --auth-interval (0=기본값 30초) */
static address_t   g_decoy_addr;                          /* --decoy */
static char        g_fec_str[256]     = "20:10";
static int         g_fec_timeout_ms   = 8;
static int         g_fec_mode         = 0;
static int         g_mtu              = default_mtu;
static int         g_queue_len        = 200;
static int         g_sock_buf         = 0;
static address_t   g_upstream_addr;                       /* relay: --upstream */

/* ─── obfs 훅 래퍼 ───────────────────────────────────────────── */

static int obfs_enc_cb(void *ctx,
                       const unsigned char *in,  int in_len,
                       unsigned char       *out, int out_max)
{
    return obfs_encode((const struct obfs_ctx *)ctx,
                       in, in_len, out, out_max, OBFS_TYPE_DATA);
}

static int obfs_dec_cb(void *ctx,
                       const unsigned char *in,  int in_len,
                       unsigned char       *out, int out_max)
{
    uint8_t pkt_type = OBFS_TYPE_DATA;
    return obfs_decode((const struct obfs_ctx *)ctx,
                       in, in_len, out, out_max, &pkt_type);
}

static int obfs_init_cb(void *ctx, void *out, int out_max, int is_server)
{
    return obfs_encode_initial((const struct obfs_ctx *)ctx, out, out_max, is_server);
}

/* ─── 시그널 핸들러 ──────────────────────────────────────────── */

/* libev ev_signal 워처 콜백 — 이벤트 루프 내부에서 안전하게 호출됨 */
static void ev_sig_cb(struct ev_loop *loop, ev_signal *w, int /*revents*/)
{
    mylog(log_info, "signal %d received, exiting\n", w->signum);
    about_to_exit = 1;
    ev_break(loop, EVBREAK_ALL);
}

static ev_signal g_ev_sigterm;
static ev_signal g_ev_sigint;

/* ─── FIFO 런타임 커맨드 콜백 ────────────────────────────────── */

static void fifo_read_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int /*revents*/)
{
    char buf[4096];
    int n = read(watcher->fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';

    /* 개행 단위로 분리해 여러 커맨드 처리 */
    char *line = buf;
    char *nl;
    while ((nl = strchr(line, '\n')) != NULL) {
        *nl = '\0';
        if (*line != '\0')
            handle_command(line);
        line = nl + 1;
    }
    if (*line != '\0')
        handle_command(line);
}

/* ─── 도움말 ─────────────────────────────────────────────────── */

static void print_help(const char *prog)
{
    fprintf(stderr,
        "multi-fec: UDP FEC proxy with multipath and GFW obfuscation\n"
        "Build:   %s (%s)\n"
        "\n"
        "Usage:\n",
        build_date, gitversion);
    fprintf(stderr,
        "  Client: %s -c -l <local> --path <spec> [--path ...] -k <key> [options]\n"
        "  Server: %s -s -l <listen> --wg <wg_addr> -k <key> [options]\n"
        "  Relay:  %s -r -l <listen> --upstream <server_addr> [options]\n"
        "\n"
        "Required:\n"
        "  -c                    Client mode\n"
        "  -s                    Server mode\n"
        "  -r                    Relay mode (POP — transparent UDP forwarder)\n"
        "  -l ip:port            Local listen address\n"
        "                          Client: WireGuard proxy port  (e.g. 127.0.0.1:51820)\n"
        "                          Server: listen port           (e.g. 0.0.0.0:443)\n"
        "  --path local:remote:port\n"
        "                        [Client] Add a multipath entry. Repeatable.\n"
        "                          local  = source interface IP  (0.0.0.0 = OS auto)\n"
        "                          remote = server IP\n"
        "                          port   = server port\n"
        "                        Example:\n"
        "                          --path 0.0.0.0:1.2.3.4:443          (any interface)\n"
        "                          --path 192.168.1.10:1.2.3.4:443     (eth0)\n"
        "                          --path 10.0.0.2:1.2.3.4:443         (wlan0)\n"
        "  --multipath-mode M    [Client] Multipath behavior  [default: failover]\n"
        "                          failover            : Active-Standby. --path 순서대로 우선순위.\n"
        "                          duplicate           : 모든 경로에 동일 패킷. 최고 가용성.\n"
        "                          aggregate           : 경로별 다른 패킷 분배 (가중 라운드로빈).\n"
        "                                                전체 대역폭 집계. tx.rate 비례 가중치.\n"
        "                          aggregate-duplicate : 집계 + 중복. --dup-factor 경로에 전송.\n"
        "                                                대역폭 집계 + 이중화 혼합.\n"
        "  --dup-factor N        [Client] aggregate-duplicate 모드에서 패킷당 경로 수 [default: 2]\n"
        "                          범위: 1–8. 경로 수보다 크면 자동으로 클램프.\n"
        "  --wg ip:port          [Server] WireGuard server upstream address\n"
        "                          (e.g. 127.0.0.1:51820)\n"
        "  --upstream ip:port    [Relay]  Server address to forward packets to\n"
        "                          (e.g. 1.2.3.4:443)\n"
        "  --route \"key ip:port\" [Relay]  Key-based upstream routing. Repeatable.\n"
        "                          HMAC of each key tried in order; first match routes\n"
        "                          the session to that upstream. Mutually exclusive with\n"
        "                          --upstream/-k single-key mode.\n"
        "                          (e.g. --route \"keyA 1.2.3.4:443\" --route \"keyB 5.6.7.8:443\")\n"
        "  -k keystring          Pre-shared key for obfuscation + TOTP\n"
        "                          [Relay] optional — if set, HMAC is verified before\n"
        "                          forwarding; invalid packets get TLS close_notify.\n"
        "                          If omitted, relay forwards all packets transparently.\n"
        "\n"
        "FEC options:\n"
        "  -f x:y                FEC ratio  [default: 20:10]\n"
        "  --fec-timeout N       FEC group flush timeout ms  [default: 8]\n"
        "  --mode 0|1|2          FEC mode: 0=bandwidth-saving, 1=low-latency, 2=RNLC  [default: 0]\n"
        "  --mtu N               FEC packet MTU bytes  [default: 1250]\n"
        "  -q N / --queue-len N  FEC encode queue length (mode 0)  [default: 200]\n"
        "  --decode-buf N        FEC decoder ring buffer size (300-20000)  [default: 2000]\n"
        "  --disable-fec         Disable FEC entirely (passthrough mode)\n"
        "\n"
        "Network options:\n"
        "  --sock-buf N          UDP socket send/recv buffer size kB (10-10240)  [default: OS]\n"
        "\n"
        "Obfuscation:\n"
        "  --obfs-mode M         Protocol mimicry mode  [default: quic]\n"
        "                          quic : QUIC Short Header (0x40-0x7F) — UDP/443 최적\n"
        "                          tls  : TLS 1.3 Application Data record (0x17 0x03 0x03)\n"
        "                                 양 끝단 모드가 달라도 자동 판별\n"
        "  --decoy ip:port       [Server/Relay] HMAC 인증 실패 패킷을 실제 QUIC/HTTPS 서버로\n"
        "                          포워딩. GFW 액티브 프로빙에게 정상 서버처럼 보임.\n"
        "                          ip:port = 로컬 nginx/caddy HTTP/3(QUIC) 리슨 주소.\n"
        "                          예: --decoy 127.0.0.1:8443\n"
        "  --disable-obfs        Disable obfuscation entirely (for testing)\n"
        "  --port-hop-interval N [Client/Server] TOTP 포트 호핑 슬롯 길이 (초).\n"
        "                          0=비활성화(기본값). 최소 30.\n"
        "                          PSK + 슬롯 번호로 포트 계산, 클라이언트와 서버가\n"
        "                          동일 시퀀스를 공유. 매 N초마다 자동 전환.\n"
        "                          예: --port-hop-interval 60\n"
        "  --auth-interval N     [All] HMAC 토큰 슬롯 길이 (초). 0=기본값(30초).\n"
        "                          클라이언트/서버 양쪽에 동일하게 설정해야 함.\n"
        "                          길수록 슬롯 경계 탐지 어려움, 시계 허용 오차 증가.\n"
        "                          최소 30초. 예: --auth-interval 60\n"
        "\n"
        "Simulation / debug:\n"
        "  -j N / --jitter N     Add artificial jitter 0-N ms (or min:max)  [default: 0]\n"
        "  --random-drop N       Simulate packet loss N/10000 (0-10000)  [default: 0]\n"
        "  --disable-checksum    Disable packet checksum\n"
        "\n"
        "Runtime control:\n"
        "  --fifo PATH           FIFO file for runtime commands (mtu/fec/mode/timeout)\n"
        "  --report N            Statistics report interval in seconds  [default: 0=off]\n"
        "\n"
        "Logging:\n"
        "  --log-level N         Log level 0-6  [default: 4]\n"
        "  --log-position        Include file/function/line in log output\n"
        "  --disable-color       Disable log color output\n"
        "  --enable-color        Enable log color output (default)\n"
        "  -h / --help           Show this help\n"
        "  --version             Show version and build date\n"
        "\n",
        prog, prog, prog);
}

/* ─── --path 파싱: "local_ip:remote_ip:port" ──────────────────── */

static int parse_path_spec(const char *spec, PathSpec &ps)
{
    char local_str[64]  = "0.0.0.0";
    char remote_str[64] = {0};
    int  port           = 0;

    /* "local_ip:remote_ip:port" 형식: 정확히 콜론 2개 */
    if (sscanf(spec, "%63[^:]:%63[^:]:%d", local_str, remote_str, &port) != 3) {
        fprintf(stderr, "error: --path 형식은 local_ip:remote_ip:port 입니다: '%s'\n", spec);
        return -1;
    }
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "error: --path port 범위 오류 (1-65535): %d\n", port);
        return -1;
    }

    /* 로컬 IP (포트 없음, 0으로 설정) */
    char local_with_port[72];
    snprintf(local_with_port, sizeof(local_with_port), "%s:0", local_str);
    ps.local.clear();
    if (ps.local.from_str(local_with_port) != 0) {
        fprintf(stderr, "error: --path local IP 파싱 실패: '%s'\n", local_str);
        return -1;
    }

    /* 원격 IP:port */
    char remote_with_port[72];
    snprintf(remote_with_port, sizeof(remote_with_port), "%s:%d", remote_str, port);
    ps.remote.clear();
    if (ps.remote.from_str(remote_with_port) != 0) {
        fprintf(stderr, "error: --path remote 파싱 실패: '%s:%d'\n", remote_str, port);
        return -1;
    }

    return 0;
}

/* ─── 인자 파싱 ──────────────────────────────────────────────── */

enum {
    OPT_PATH           = 1000,
    OPT_WG,
    OPT_UPSTREAM,
    OPT_MULTIPATH_MODE,
    OPT_DUP_FACTOR,
    OPT_FEC_TIMEOUT,
    OPT_FEC_MODE,
    OPT_MTU,
    OPT_QUEUE_LEN,
    OPT_DECODE_BUF,
    OPT_DISABLE_FEC,
    OPT_SOCK_BUF,
    OPT_JITTER,
    OPT_RANDOM_DROP,
    OPT_DISABLE_CHECKSUM,
    OPT_FIFO,
    OPT_REPORT,
    OPT_LOG_LEVEL,
    OPT_LOG_POSITION,
    OPT_DISABLE_COLOR,
    OPT_ENABLE_COLOR,
    OPT_OBFS_MODE,
    OPT_DECOY,
    OPT_DISABLE_OBFS,
    OPT_PORT_HOP_INTERVAL,
    OPT_AUTH_INTERVAL,
    OPT_VERSION,
    OPT_ROUTE,
};

static const struct option long_opts[] = {
    { "path",             required_argument, NULL, OPT_PATH            },
    { "wg",               required_argument, NULL, OPT_WG              },
    { "upstream",         required_argument, NULL, OPT_UPSTREAM        },
    { "multipath-mode",   required_argument, NULL, OPT_MULTIPATH_MODE  },
    { "dup-factor",       required_argument, NULL, OPT_DUP_FACTOR      },
    { "fec-timeout",      required_argument, NULL, OPT_FEC_TIMEOUT     },
    { "mode",             required_argument, NULL, OPT_FEC_MODE        },
    { "mtu",              required_argument, NULL, OPT_MTU             },
    { "queue-len",        required_argument, NULL, OPT_QUEUE_LEN       },
    { "decode-buf",       required_argument, NULL, OPT_DECODE_BUF      },
    { "disable-fec",      no_argument,       NULL, OPT_DISABLE_FEC     },
    { "sock-buf",         required_argument, NULL, OPT_SOCK_BUF        },
    { "jitter",           required_argument, NULL, OPT_JITTER          },
    { "random-drop",      required_argument, NULL, OPT_RANDOM_DROP     },
    { "disable-checksum", no_argument,       NULL, OPT_DISABLE_CHECKSUM},
    { "fifo",             required_argument, NULL, OPT_FIFO            },
    { "report",           required_argument, NULL, OPT_REPORT          },
    { "log-level",        required_argument, NULL, OPT_LOG_LEVEL       },
    { "log-position",     no_argument,       NULL, OPT_LOG_POSITION    },
    { "disable-color",    no_argument,       NULL, OPT_DISABLE_COLOR   },
    { "enable-color",     no_argument,       NULL, OPT_ENABLE_COLOR    },
    { "obfs-mode",        required_argument, NULL, OPT_OBFS_MODE       },
    { "decoy",            required_argument, NULL, OPT_DECOY           },
    { "disable-obfs",       no_argument,       NULL, OPT_DISABLE_OBFS        },
    { "port-hop-interval",  required_argument, NULL, OPT_PORT_HOP_INTERVAL   },
    { "auth-interval",      required_argument, NULL, OPT_AUTH_INTERVAL       },
    { "version",            no_argument,       NULL, OPT_VERSION             },
    { "route",              required_argument, NULL, OPT_ROUTE               },
    { "help",               no_argument,       NULL, 'h'                     },
    { NULL,               0,                 NULL, 0                   },
};

static void parse_args(int argc, char *argv[])
{
    int opt, opt_idx = 0;

    while ((opt = getopt_long(argc, argv, "csrl:f:k:q:j:h", long_opts, &opt_idx)) != -1) {
        switch (opt) {
        case 'c':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: -c/-s/-r 중 하나만 지정하세요\n");
                exit(1);
            }
            program_mode = client_mode;
            break;

        case 's':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: -c/-s/-r 중 하나만 지정하세요\n");
                exit(1);
            }
            program_mode = server_mode;
            break;

        case 'r':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: -c/-s/-r 중 하나만 지정하세요\n");
                exit(1);
            }
            program_mode = relay_mode;
            break;

        case 'l':
            if (local_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: -l 주소 파싱 실패: '%s'\n", optarg);
                exit(1);
            }
            break;

        case 'f':
            strncpy(g_fec_str, optarg, sizeof(g_fec_str) - 1);
            break;

        case 'k':
            strncpy(g_key_string, optarg, sizeof(g_key_string) - 1);
            g_key_set = true;
            break;

        case OPT_PATH: {
            PathSpec ps;
            if (parse_path_spec(optarg, ps) != 0) exit(1);
            g_paths.push_back(ps);
            mylog(log_info, "path 추가: local=%s remote=%s\n",
                  ps.local.get_str(), ps.remote.get_str());
            break;
        }

        case OPT_WG:
            if (g_wg_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --wg 주소 파싱 실패: '%s'\n", optarg);
                exit(1);
            }
            mylog(log_info, "WireGuard upstream: %s\n", g_wg_addr.get_str());
            break;

        case OPT_UPSTREAM:
            if (g_upstream_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --upstream 주소 파싱 실패: '%s'\n", optarg);
                exit(1);
            }
            mylog(log_info, "relay upstream: %s\n", g_upstream_addr.get_str());
            break;

        case OPT_ROUTE: {
            /* --route "keystring ip:port" */
            route_entry_t entry;
            char addr_str[256] = {0};
            if (sscanf(optarg, "%999s %255s", entry.key_str, addr_str) != 2) {
                fprintf(stderr, "error: --route 형식은 \"키문자열 ip:port\" 입니다: '%s'\n", optarg);
                exit(1);
            }
            if (entry.upstream_addr.from_str(addr_str) != 0) {
                fprintf(stderr, "error: --route upstream 주소 파싱 실패: '%s'\n", addr_str);
                exit(1);
            }
            obfs_init(&entry.obfs, entry.key_str, g_obfs_mode);
            g_routes.push_back(entry);
            mylog(log_info, "route 추가: key=%s upstream=%s\n",
                  entry.key_str, addr_str);
            break;
        }

        case OPT_MULTIPATH_MODE:
            if (strcmp(optarg, "duplicate") == 0) {
                g_multipath_mode = MULTIPATH_DUPLICATE;
            } else if (strcmp(optarg, "failover") == 0) {
                g_multipath_mode = MULTIPATH_FAILOVER;
            } else if (strcmp(optarg, "aggregate") == 0) {
                g_multipath_mode = MULTIPATH_AGGREGATE;
            } else if (strcmp(optarg, "aggregate-duplicate") == 0) {
                g_multipath_mode = MULTIPATH_AGGREGATE_DUPLICATE;
            } else {
                fprintf(stderr, "error: --multipath-mode 값은 failover, duplicate, "
                                "aggregate, aggregate-duplicate 중 하나입니다\n");
                exit(1);
            }
            break;

        case OPT_DUP_FACTOR:
            g_dup_factor = (unsigned)atoi(optarg);
            if (g_dup_factor < 1 || g_dup_factor > 8) {
                fprintf(stderr, "error: --dup-factor 범위는 1–8\n");
                exit(1);
            }
            break;

        case OPT_FEC_TIMEOUT:
            g_fec_timeout_ms = atoi(optarg);
            if (g_fec_timeout_ms < 0) g_fec_timeout_ms = 0;
            break;

        case OPT_FEC_MODE:
            g_fec_mode = atoi(optarg);
            if (g_fec_mode != 0 && g_fec_mode != 1 && g_fec_mode != 2) {
                fprintf(stderr, "error: --mode must be 0, 1, or 2\n");
                exit(1);
            }
            break;

        case OPT_MTU:
            g_mtu = atoi(optarg);
            if (g_mtu < 100 || g_mtu > 1500) {
                fprintf(stderr, "error: --mtu must be between 100 and 1500\n");
                exit(1);
            }
            break;

        case 'q':
        case OPT_QUEUE_LEN:
            g_queue_len = atoi(optarg);
            if (g_queue_len < 1 || g_queue_len > 10000) {
                fprintf(stderr, "error: --queue-len must be between 1 and 10000\n");
                exit(1);
            }
            break;

        case OPT_DECODE_BUF:
            fec_buff_num = (u32_t)atoi(optarg);
            if (fec_buff_num < 300 || fec_buff_num > 20000) {
                fprintf(stderr, "error: --decode-buf must be between 300 and 20000\n");
                exit(1);
            }
            break;

        case OPT_DISABLE_FEC:
            disable_fec = 1;
            break;

        case OPT_SOCK_BUF:
            g_sock_buf = atoi(optarg);
            if (g_sock_buf < 10 || g_sock_buf > 10240) {
                fprintf(stderr, "error: --sock-buf must be between 10 and 10240 (kB)\n");
                exit(1);
            }
            break;

        case 'j':
        case OPT_JITTER: {
            int jmin = 0, jmax = 0;
            if (strchr(optarg, ':')) {
                if (sscanf(optarg, "%d:%d", &jmin, &jmax) != 2 ||
                    jmin < 0 || jmax < 0 || jmin > jmax) {
                    fprintf(stderr, "error: --jitter min:max is invalid\n");
                    exit(1);
                }
            } else {
                jmax = atoi(optarg);
                if (jmax < 0 || jmax > 10000) {
                    fprintf(stderr, "error: --jitter must be 0-10000 ms\n");
                    exit(1);
                }
            }
            jitter_min = jmin * 1000;
            jitter_max = jmax * 1000;
            break;
        }

        case OPT_RANDOM_DROP:
            random_drop = atoi(optarg);
            if (random_drop < 0 || random_drop > 10000) {
                fprintf(stderr, "error: --random-drop must be 0-10000\n");
                exit(1);
            }
            break;

        case OPT_DISABLE_CHECKSUM:
            disable_checksum = 1;
            break;

        case OPT_FIFO:
            strncpy(fifo_file, optarg, sizeof(fifo_file) - 1);
            break;

        case OPT_REPORT:
            report_interval = atoi(optarg);
            if (report_interval <= 0) {
                fprintf(stderr, "error: --report must be > 0\n");
                exit(1);
            }
            break;

        case OPT_LOG_LEVEL:
            log_level = atoi(optarg);
            if (log_level < 0)          log_level = 0;
            if (log_level >= log_end)   log_level = log_end - 1;
            break;

        case OPT_LOG_POSITION:
            enable_log_position = 1;
            break;

        case OPT_DISABLE_COLOR:
            enable_log_color = 0;
            break;

        case OPT_ENABLE_COLOR:
            enable_log_color = 1;
            break;

        case OPT_OBFS_MODE:
            if (strcmp(optarg, "tls") == 0) {
                g_obfs_mode = OBFS_MODE_TLS;
            } else if (strcmp(optarg, "quic") == 0) {
                g_obfs_mode = OBFS_MODE_QUIC;
            } else {
                fprintf(stderr, "error: --obfs-mode 값은 quic 또는 tls 입니다\n");
                exit(1);
            }
            break;

        case OPT_DECOY:
            if (g_decoy_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --decoy 주소 파싱 실패: '%s'\n", optarg);
                exit(1);
            }
            break;

        case OPT_DISABLE_OBFS:
            g_disable_obfs = 1;
            break;

        case OPT_PORT_HOP_INTERVAL:
            g_hop_interval = (uint32_t)atoi(optarg);
            if (g_hop_interval != 0 && g_hop_interval < 30) {
                fprintf(stderr, "error: --port-hop-interval 최소 30초 또는 0(비활성화)\n");
                exit(1);
            }
            break;

        case OPT_AUTH_INTERVAL:
            g_auth_interval = (uint32_t)atoi(optarg);
            if (g_auth_interval != 0 && g_auth_interval < 30) {
                fprintf(stderr, "error: --auth-interval 최소 30초 또는 0(기본값 30초)\n");
                exit(1);
            }
            break;

        case OPT_VERSION:
            printf("multi-fec %s\nbuild: %s\n", gitversion, build_date);
            exit(0);

        case 'h':
            print_help(argv[0]);
            exit(0);

        default:
            fprintf(stderr, "알 수 없는 옵션\n");
            print_help(argv[0]);
            exit(1);
        }
    }
}

/* ─── mud_set_path 래퍼 ──────────────────────────────────────── */

static void setup_static_paths(struct mud *mud)
{
    for (size_t i = 0; i < g_paths.size(); i++) {
        PathSpec &ps = g_paths[i];   /* non-const: address_t methods not const-qualified */

        struct mud_path_conf pc;
        memset(&pc, 0, sizeof(pc));

        pc.state      = MUD_UP;
        pc.loss_limit = 200;
        pc.fixed_rate = 0;
        pc.beat       = (uint64_t)(80 + rand() % 41) * 1000ULL;  /* 80–120ms 랜덤 */

        /*
         * Failover             : pref 0,1,2,... — 최상위 경로만 RUNNING, 장애 시 승격.
         * Duplicate            : pref=0 — 모든 경로 동시 RUNNING.
         * Aggregate            : pref=0 — 모든 경로 동시 RUNNING, 가중 라운드로빈 분배.
         * Aggregate-Duplicate  : pref=0 — 모든 경로 RUNNING, 패킷당 dup_factor개 전송.
         */
        if (g_multipath_mode == MULTIPATH_FAILOVER)
            pc.pref = (unsigned char)i;
        else
            pc.pref = 0;

        if (ps.local.get_type() == AF_INET)
            pc.local.sin  = ps.local.inner.ipv4;
        else
            pc.local.sin6 = ps.local.inner.ipv6;

        if (ps.remote.get_type() == AF_INET)
            pc.remote.sin  = ps.remote.inner.ipv4;
        else
            pc.remote.sin6 = ps.remote.inner.ipv6;

        int ret = mud_set_path(mud, &pc);
        if (ret != 0)
            mylog(log_warn, "mud_set_path 실패 [%zu] remote=%s : %s\n",
                  i, ps.remote.get_str(), strerror(errno));
        else
            mylog(log_info, "정적 경로 등록 [%zu] local=%s remote=%s\n",
                  i, ps.local.get_str(), ps.remote.get_str());
    }
}

/* ─── main ───────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    working_mode = tunnel_mode;

    if (argc == 1) {
        print_help(argv[0]);
        return 1;
    }

    parse_args(argc, argv);

    mylog(log_info, "multi-fec %s build %s\n", gitversion, build_date);

    /* 모드 검증 */
    if (program_mode == unset_mode) {
        fprintf(stderr, "error: -c (클라이언트), -s (서버), -r (릴레이) 중 하나를 지정하세요\n");
        print_help(argv[0]);
        return 1;
    }
    if (!local_addr.is_vaild()) {
        fprintf(stderr, "error: -l 로컬 주소를 지정하세요\n");
        return 1;
    }

    /* 클라이언트: --path 필수 */
    if (program_mode == client_mode && g_paths.empty()) {
        fprintf(stderr, "error: 클라이언트 모드에서 --path 를 하나 이상 지정하세요\n");
        fprintf(stderr, "  예: --path 0.0.0.0:서버IP:443\n");
        return 1;
    }

    /* 서버: --wg 필수 */
    if (program_mode == server_mode && !g_wg_addr.is_vaild()) {
        fprintf(stderr, "error: 서버 모드에서 --wg WireGuard주소:포트 를 지정하세요\n");
        fprintf(stderr, "  예: --wg 127.0.0.1:51820\n");
        return 1;
    }

    /* 릴레이: --upstream 또는 --route 중 하나 이상 필수. FEC 불필요 → 바로 진입 */
    /* --route가 --obfs-mode보다 먼저 파싱되면 route obfs의 mode가 기본값(QUIC)으로
     * 초기화된다. 파싱 완료 후 최종 g_obfs_mode로 재적용해 순서 독립성 보장. */
    for (auto &route : g_routes) {
        obfs_init(&route.obfs, route.key_str, g_obfs_mode);
        if (g_auth_interval) route.obfs.auth_interval = g_auth_interval;
    }

    /* rand() 시드 초기화 — beat 랜덤화, probe 응답 크기 랜덤화에 사용.
     * clock_gettime 나노초 단위로 초 단위 time()보다 높은 엔트로피 확보.
     * 보안 목적 난수가 아니므로 rand()로 충분. */
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        srand((unsigned)(ts.tv_sec ^ ts.tv_nsec));
    }

    if (program_mode == relay_mode) {
        if (!g_upstream_addr.is_vaild() && g_routes.empty()) {
            fprintf(stderr, "error: 릴레이 모드에서 --upstream 또는 --route 를 지정하세요\n");
            fprintf(stderr, "  단일 upstream: --upstream 1.2.3.4:443\n");
            fprintf(stderr, "  키별 라우팅:   --route \"key1 1.2.3.4:443\" --route \"key2 5.6.7.8:443\"\n");
            return 1;
        }
        init_random_number_fd();
        signal(SIGPIPE, SIG_IGN);

        ev_signal_init(&g_ev_sigterm, ev_sig_cb, SIGTERM);
        ev_signal_init(&g_ev_sigint,  ev_sig_cb, SIGINT);
        ev_signal_start(ev_default_loop(0), &g_ev_sigterm);
        ev_signal_start(ev_default_loop(0), &g_ev_sigint);

        /* -k 지정 시 HMAC 검증 활성화, 미지정 시 투명 중계 (--route 미사용 시에만 적용) */
        static struct obfs_ctx relay_obfs;
        const struct obfs_ctx *relay_obfs_ptr = NULL;
        if (g_key_set && g_routes.empty()) {
            obfs_init(&relay_obfs, g_key_string, g_obfs_mode);
            if (g_auth_interval) relay_obfs.auth_interval = g_auth_interval;
            relay_obfs_ptr = &relay_obfs;
            mylog(log_info, "릴레이 HMAC 검증 활성화 (obfs=%s)\n",
                  g_obfs_mode == OBFS_MODE_TLS ? "tls" : "quic");
        }

        if (!g_routes.empty()) {
            mylog(log_info, "릴레이 모드 시작: %s  키별 라우팅 %zu개\n",
                  local_addr.get_str(), g_routes.size());
        } else {
            mylog(log_info, "릴레이 모드 시작: %s → %s\n",
                  local_addr.get_str(), g_upstream_addr.get_str());
        }
        mf_relay_event_loop(local_addr, g_upstream_addr, relay_obfs_ptr, g_decoy_addr);
        return 0;
    }

    init_random_number_fd();

    signal(SIGPIPE, SIG_IGN);

    ev_signal_init(&g_ev_sigterm, ev_sig_cb, SIGTERM);
    ev_signal_init(&g_ev_sigint,  ev_sig_cb, SIGINT);
    ev_signal_start(ev_default_loop(0), &g_ev_sigterm);
    ev_signal_start(ev_default_loop(0), &g_ev_sigint);

    /* 클라이언트: 랜덤 session_id 생성
     * 서버가 POP 경유 여부와 무관하게 동일 클라이언트를 식별하는 데 사용. */
    if (program_mode == client_mode) {
        int rfd = open("/dev/urandom", O_RDONLY);
        if (rfd < 0 || read(rfd, g_session_id, SESSION_ID_LEN) != SESSION_ID_LEN) {
            mylog(log_fatal, "session_id 생성 실패\n");
            return 1;
        }
        close(rfd);
        mylog(log_info, "session_id: %016llx\n",
              (unsigned long long)(*(uint64_t *)g_session_id));
    }

    /* FEC 파라미터 */
    strncpy(rs_par_str, g_fec_str, rs_str_len - 1);
    if (g_fec_par.rs_from_str(g_fec_str) != 0) {
        fprintf(stderr, "error: FEC 파라미터 파싱 실패: '%s'\n", g_fec_str);
        return 1;
    }
    g_fec_par.timeout   = g_fec_timeout_ms * 1000;
    g_fec_par.mtu       = g_mtu;
    g_fec_par.queue_len = g_queue_len;
    g_fec_par.mode      = g_fec_mode;

    print_parameter();

    /* obfs 초기화 */
    static struct obfs_ctx obfs;
    obfs_init(&obfs, g_key_string, g_obfs_mode);
    if (!g_disable_obfs) {
        obfs.hop_interval = g_hop_interval;
        if (g_auth_interval) obfs.auth_interval = g_auth_interval;
    }

    if (!g_disable_obfs) {
        if (g_hop_interval > 0) {
            mylog(log_info, "obfs: mode=%s + HMAC-auth (interval=%us) + size-norm + port-hop (interval=%us)\n",
                  g_obfs_mode == OBFS_MODE_TLS ? "TLS-AppData" : "QUIC-ShortHeader",
                  obfs.auth_interval, g_hop_interval);
        } else {
            mylog(log_info, "obfs: mode=%s + HMAC-auth (interval=%us) + size-norm\n",
                  g_obfs_mode == OBFS_MODE_TLS ? "TLS-AppData" : "QUIC-ShortHeader",
                  obfs.auth_interval);
        }
    }

    /* mud 생성
     *
     * 서버: mud 소켓 = 리슨 소켓 (-l 주소에 바인딩)
     * 클라이언트: mud 소켓은 WireGuard 프록시 포트(-l)와 별개.
     *   0.0.0.0:0 으로 생성 → OS가 임의 포트 할당.
     *   경로별 출발지 IP는 mud_send_path()의 IP_PKTINFO로 선택됨.
     */
    union mud_sockaddr mud_local;
    memset(&mud_local, 0, sizeof(mud_local));

    if (program_mode == server_mode) {
        if (local_addr.get_type() == AF_INET)
            mud_local.sin  = local_addr.inner.ipv4;
        else
            mud_local.sin6 = local_addr.inner.ipv6;
    } else {
        /* 클라이언트: 0.0.0.0:0 */
        mud_local.sin.sin_family      = AF_INET;
        mud_local.sin.sin_addr.s_addr = htonl(INADDR_ANY);
        mud_local.sin.sin_port        = 0;
    }

    struct mud *mud = mud_create(&mud_local);
    if (!mud) {
        mylog(log_fatal, "mud 생성 실패: %s\n", strerror(errno));
        return 1;
    }
    mylog(log_info, "mud fd=%d\n", mud_get_fd(mud));

    /* 소켓 버퍼 설정 (--sock-buf) */
    if (g_sock_buf > 0) {
        int bufsz = g_sock_buf * 1024;
        int mfd   = mud_get_fd(mud);
        if (setsockopt(mfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz)) < 0 ||
            setsockopt(mfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz)) < 0) {
            mylog(log_warn, "sock-buf setsockopt 실패: %s\n", strerror(errno));
        } else {
            mylog(log_info, "sock-buf=%d kB\n", g_sock_buf);
        }
    }

    /* FIFO 런타임 커맨드 채널 */
    static struct ev_io fifo_watcher;
    if (fifo_file[0] != '\0') {
        int fifo_fd = create_fifo(fifo_file);
        if (fifo_fd < 0) {
            mylog(log_fatal, "FIFO 생성 실패: %s\n", fifo_file);
            return 1;
        }
        mylog(log_info, "fifo=%s fd=%d\n", fifo_file, fifo_fd);
        ev_io_init(&fifo_watcher, fifo_read_cb, fifo_fd, EV_READ);
        ev_io_start(ev_default_loop(0), &fifo_watcher);
    }

    /* obfs 훅 등록 */
    if (!g_disable_obfs)
        mud_set_obfs(mud, obfs_enc_cb, obfs_dec_cb, obfs_init_cb, &obfs);
    else
        mylog(log_warn, "obfs 비활성화됨 (--disable-obfs)\n");

    /* mud keepalive 설정
     * mud 시간 단위 = 마이크로초 (MUD_ONE_MSEC=1000, MUD_ONE_SEC=1,000,000)
     * timetolerance: 패킷 전송/수신 시각 차이 허용 오차.
     *   0 = mud_create 기본값(10초) 사용. WAN RTT 고려시 최소 수초 필요. */
    struct mud_conf mconf;
    memset(&mconf, 0, sizeof(mconf));
    mconf.keepalive     = 5000000ULL;   /* 5초 (5,000,000 µs) */
    mconf.timetolerance = 30000000ULL;  /* 30초 — HMAC ±30s 허용범위와 일치, 시계 오차 대응 */
    mud_set(mud, &mconf);

    setnonblocking(mud_get_fd(mud));

    /* 클라이언트: 정적 경로 등록 */
    if (program_mode == client_mode)
        setup_static_paths(mud);

    /* 포트 호핑 (--port-hop-interval)
     * 클라이언트: PortHopper가 mud 경로의 원격 포트를 TOTP로 전환
     * 서버: mf_server_event_loop 내부에서 슬롯별 raw UDP 소켓 직접 관리 */
    PortHopper *hopper = NULL;
    if (g_hop_interval > 0 && !g_disable_obfs && program_mode == client_mode) {
        hopper = new PortHopper(mud, &obfs, g_paths, false);
        hopper->start(ev_default_loop(0));
    }

    const char *mp_mode_str =
        (g_multipath_mode == MULTIPATH_DUPLICATE)           ? "duplicate" :
        (g_multipath_mode == MULTIPATH_AGGREGATE)           ? "aggregate" :
        (g_multipath_mode == MULTIPATH_AGGREGATE_DUPLICATE) ? "aggregate-duplicate" :
                                                              "failover";
    if (g_multipath_mode == MULTIPATH_AGGREGATE_DUPLICATE)
        mylog(log_info, "%s 모드 시작 (multipath=%s dup-factor=%u)\n",
              program_mode == client_mode ? "클라이언트" : "서버",
              mp_mode_str, g_dup_factor);
    else
        mylog(log_info, "%s 모드 시작 (multipath=%s)\n",
              program_mode == client_mode ? "클라이언트" : "서버", mp_mode_str);

    if (program_mode == client_mode)
        mf_client_event_loop(mud, &obfs);
    else
        mf_server_event_loop(mud, &obfs, -1, g_decoy_addr);

    if (hopper) {
        hopper->stop(ev_default_loop(0));
        delete hopper;
    }

    mud_delete(mud);
    mylog(log_info, "종료\n");
    return 0;
}
