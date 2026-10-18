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
#include "mf_config.h"
#include "mf_netcfg.h"

#include <getopt.h>
#include <signal.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <fcntl.h>
#include <unistd.h>
#include <net/if.h>
#include <sys/stat.h>
#include <set>
#include <string>
#include <fstream>
#include <dirent.h>

/* ─── Event loop entry points ─────────────────────────────────── */

extern "C" void mf_client_event_loop(struct mud *mud, const struct obfs_ctx *obfs);
extern "C" void mf_server_event_loop(struct mud *mud, const struct obfs_ctx *obfs,
                                     int decoy_fd, address_t decoy_addr);
extern "C" void mf_relay_event_loop(address_t &listen_addr, address_t &upstream_addr,
                                    const struct obfs_ctx *obfs, address_t decoy_addr);

/* ─── Global variable definitions ─────────────────────────────── */

std::vector<PathSpec>      g_paths;
address_t                  g_wg_addr;
multipath_mode_t           g_multipath_mode = MULTIPATH_DUPLICATE;   /* v1.4.0: was failover */
unsigned                   g_dup_factor     = 2;  /* aggregate-duplicate path duplication count */
std::vector<route_entry_t> g_routes;
uint8_t               g_session_id[SESSION_ID_LEN] = {0};

/* init_random_number_fd from speeder common.cpp treated as a no-op */
void init_random_number_fd() {}

extern int  disable_anti_replay;
extern char rs_par_str[];

/* ─── Option variables ────────────────────────────────────────── */

static char        g_key_string[1000] = "default-key";
static bool        g_key_set          = false;   /* whether a key was explicitly set (-k/--key/key-file/MF_KEY) */
static const char *g_key_from         = "";      /* where the key came from, for the log */
static char        g_key_file[1000]   = "";      /* --key-file */
static char        g_route_file[1000] = "";      /* relay: --route-file */
static int         g_disable_obfs     = 0;
static obfs_mode_t g_obfs_mode        = OBFS_MODE_QUIC;  /* --obfs-mode */
static uint32_t    g_hop_interval     = 0;               /* --port-hop-interval (0=disabled) */
/* v1.4.0 defaults = the values every deployment already passed explicitly
 * (testnet and service units). Of these only auth-interval must match the
 * peer, which is why it is 60 here and must not change again (DESIGN-1.4.0 §4). */
static uint32_t    g_auth_interval    = 60;              /* --auth-interval (0 = legacy 30s) */
static address_t   g_decoy_addr;                          /* --decoy */
static char        g_fec_str[256]     = "5:1,20:4";       /* was 20:10 */
static int         g_fec_timeout_ms   = 10;               /* was 8 */
static int         g_fec_mode         = 1;                /* was 0 */
static int         g_mtu              = 1350;             /* was default_mtu (1250) */
static int         g_queue_len        = 500;              /* was 200 */
int                g_sock_buf         = 4096;             /* --sock-buf kB (was 0 = OS default; read by mf_relay.cpp) */
static address_t   g_upstream_addr;                       /* relay: --upstream */
address_t          g_upstream_local;                      /* relay: --upstream-local (read by mf_relay.cpp) */
static std::vector<address_t> g_accept_local;             /* server: --accept-local (allowed local addrs) */

/* ─── --sock-buf ──────────────────────────────────────────────────
 * SO_RCVBUF/SO_SNDBUF are silently capped at net.core.rmem_max/wmem_max
 * (212992 on a stock kernel), so a plain setsockopt turned `--sock-buf 4096`
 * into 416 KB while the log claimed 4096 kB (2026-10-05, test-results/
 * 2026-10-05-vm-guard-calib). Try the *FORCE variants first — they bypass the
 * cap when we hold CAP_NET_ADMIN (the units run as root) — then fall back and
 * read the result back so the caller can say what it actually got.
 *
 * Returns 0 = applied, 1 = applied but capped below the request, -1 = failed.
 * rcv_kb/snd_kb receive the effective sizes (the kernel reports double the
 * set value to account for overhead; we halve it back to the requested unit). */
int mf_set_sock_buf(int fd, int kb, int *rcv_kb, int *snd_kb)
{
    int want = kb * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDBUFFORCE, &want, sizeof(want)) < 0 &&
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF,      &want, sizeof(want)) < 0)
        return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &want, sizeof(want)) < 0 &&
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF,      &want, sizeof(want)) < 0)
        return -1;

    int rcv = 0, snd = 0;
    socklen_t len = sizeof(rcv);
    getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, &len);
    len = sizeof(snd);
    getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, &len);
    if (rcv_kb) *rcv_kb = rcv / 2 / 1024;
    if (snd_kb) *snd_kb = snd / 2 / 1024;
    return (rcv / 2 < want || snd / 2 < want) ? 1 : 0;
}

/* ─── obfs hook wrappers ──────────────────────────────────────── */

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

/* ─── Signal handlers ─────────────────────────────────────────── */

/* libev ev_signal watcher callback — safely invoked from inside the event loop */
static void ev_sig_cb(struct ev_loop *loop, ev_signal *w, int /*revents*/)
{
    mylog(log_info, "signal %d received, exiting\n", w->signum);
    about_to_exit = 1;
    ev_break(loop, EVBREAK_ALL);
}

static ev_signal g_ev_sigterm;
static ev_signal g_ev_sigint;

/* ─── FIFO runtime command callback ───────────────────────────── */

static void fifo_read_cb(struct ev_loop * /*loop*/, struct ev_io *watcher, int /*revents*/)
{
    char buf[4096];
    int n = read(watcher->fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';

    /* split on newlines to handle multiple commands */
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

/* ─── Help ────────────────────────────────────────────────────── */

static void print_help(const char *prog)
{
    fprintf(stderr,
        "multi-fec %s: UDP FEC proxy with multipath and GFW obfuscation\n"
        "Build:   %s (git %s)\n"
        "\n"
        "Usage:\n",
        MULTI_FEC_VERSION, build_date, gitversion);
    fprintf(stderr,
        "  Any:    %s --config FILE [--check | --apply-routes | --remove-routes]\n"
        "            FILE: \"name = value\" lines, name = long option without --,\n"
        "            plus mode = client|server|relay and fec-mode = 0|1|2.\n"
        "            Command-line options override the file.\n",
        prog);
    fprintf(stderr,
        "  Client: %s -c [-l <local>] --path <spec> [--path ...] -k <key> [options]\n"
        "  Server: %s -s -l <listen> [--wg <wg_addr>] -k <key> [options]\n"
        "  Relay:  %s -r -l <listen> --upstream <server_addr> [options]\n"
        "\n"
        "Required:\n"
        "  -c                    Client mode\n"
        "  -s                    Server mode\n"
        "  -r                    Relay mode (POP — transparent UDP forwarder)\n"
        "  -l ip:port            Local listen address\n"
        "                          Client: WireGuard proxy port  [default: 127.0.0.1:51821]\n"
        "                          Server: listen port           (e.g. 0.0.0.0:443)\n"
        "  --path \"remote:port [via IF [gw IP]]\"   or   local:remote:port\n"
        "                        [Client] Add a multipath entry. Repeatable.\n"
        "                          remote:port         source picked by the kernel (= 0.0.0.0:remote:port)\n"
        "                          via IF              send this path out of interface IF. The source IP\n"
        "                                              alone does NOT choose the interface (Linux routes by\n"
        "                                              destination) — use via, or policy routing.\n"
        "                          gw IP               gateway for --apply-routes (default: IF's default route)\n"
        "                        Example:\n"
        "                          --path 1.2.3.4:443\n"
        "                          --path \"5.6.7.8:443 via eth1\"\n"
        "  --multipath-mode M    [Client] Multipath behavior  [default: duplicate]\n"
        "                          failover            : Active-Standby. Priority follows --path order.\n"
        "                          duplicate           : Same packet on all paths. Highest availability.\n"
        "                          aggregate           : Distribute distinct packets per path (weighted round-robin).\n"
        "                                                Aggregates total bandwidth. Weighting proportional to tx.rate.\n"
        "                          aggregate-duplicate : Aggregate + duplicate. Sent over --dup-factor paths.\n"
        "                                                Bandwidth aggregation + redundancy mix.\n"
        "  --dup-factor N        [Client] Paths per packet in aggregate-duplicate mode [default: 2]\n"
        "                          Range: 1–8. Clamped automatically if greater than path count.\n"
        "  --wg ip:port          [Server] WireGuard server upstream address  [default: 127.0.0.1:51820]\n"
        "  --accept-local ip     [Server] Serve only packets that arrived on this local\n"
        "                          address. Repeatable, up to 16. Bare IP, no port.\n"
        "                          Only meaningful with -l 0.0.0.0 (or [::]): a socket\n"
        "                          bound to one address is already restricted by the\n"
        "                          kernel, and non-matching entries are refused at start.\n"
        "                          Default: unset, every local address is served.\n"
        "                          Non-matching packets are dropped silently — answering\n"
        "                          would advertise the service on an unserved address.\n"
        "                          (e.g. -l 0.0.0.0:443 --accept-local 1.2.3.4\n"
        "                                --accept-local 5.6.7.8)\n"
        "  --upstream ip:port    [Relay]  Server address to forward packets to\n"
        "                          (e.g. 1.2.3.4:443)\n"
        "  --upstream-local ip   [Relay]  Source IP for the upstream (relay->server)\n"
        "                          socket. Bare IP, no port — the source port is always\n"
        "                          ephemeral (one upstream socket per client session).\n"
        "                          Default: unset, kernel picks the route-preferred source.\n"
        "                          The -l listen address does NOT carry over: listen and\n"
        "                          upstream are separate sockets. Set this when several\n"
        "                          relay instances on one host must be distinguishable\n"
        "                          by source IP upstream.\n"
        "                          (e.g. --upstream-local 192.168.100.86)\n"
        "  --route \"key ip:port [via IF] [gw IP] [local IP]\"\n"
        "                        [Relay]  Key-based upstream routing. Repeatable.\n"
        "                          via/local pin this key's upstream interface/source IP.\n"
        "  --route-file FILE     [Relay]  One route per line (same syntax), '#' comments.\n"
        "                          HMAC of each key tried in order; first match routes\n"
        "                          the session to that upstream. Mutually exclusive with\n"
        "                          --upstream/-k single-key mode.\n"
        "                          (e.g. --route \"keyA 1.2.3.4:443\" --route \"keyB 5.6.7.8:443\")\n"
        "  -k / --key keystring  Pre-shared key for obfuscation + TOTP. Hidden from ps once read.\n"
        "  --key-file FILE       Key from the first line of FILE (chmod 600). Env MF_KEY also works.\n"
        "                          Precedence: -k/--key/key= > --key-file > MF_KEY. Empty keys refused.\n"
        "                          [Relay] optional — if set, HMAC is verified before\n"
        "                          forwarding; invalid packets get TLS close_notify.\n"
        "                          If omitted, relay forwards all packets transparently.\n"
        "\n"
        "FEC options:\n"
        "  -f x:y[,x:y...]       FEC ratio  [default: 5:1,20:4]\n"
        "  --fec-timeout N       FEC group flush timeout ms  [default: 10]\n"
        "  --mode / --fec-mode 0|1|2\n"
        "                        FEC mode: 0=bandwidth-saving, 1=low-latency, 2=RNLC  [default: 1]\n"
        "                          0 and 1 interoperate (the receiver reads the packet type); 2 must match.\n"
        "  --mtu N               FEC packet MTU bytes  [default: 1350, needs WireGuard MTU 1300]\n"
        "  -q N / --queue-len N  FEC encode queue length (mode 0)  [default: 500]\n"
        "  --decode-buf N        FEC decoder ring buffer, in packets (300-20000)  [default: 2000]\n"
        "                        Allocated PER CONNECTION, ~3.8 KB/entry:\n"
        "                        2000 -> 7.3 MB/conn, 8000 -> 29 MB/conn, 20000 -> 73 MB/conn\n"
        "  --disable-fec         Disable FEC entirely (passthrough mode)\n"
        "\n"
        "Network options:\n"
        "  --sock-buf N          UDP socket send/recv buffer size kB (10-10240)  [default: 4096]\n"
        "\n"
        "Obfuscation:\n"
        "  --obfs-mode M         Protocol mimicry mode  [default: quic]\n"
        "                          quic : QUIC Short Header (0x40-0x7F) — optimal for UDP/443\n"
        "                          tls  : TLS 1.3 Application Data record (0x17 0x03 0x03)\n"
        "                                 auto-detected even if the two ends use different modes\n"
        "  --decoy ip:port       [Server/Relay] Forward HMAC-auth-failed packets to a real\n"
        "                          QUIC/HTTPS server. Looks like a legitimate server to GFW active probing.\n"
        "                          ip:port = local nginx/caddy HTTP/3(QUIC) listen address.\n"
        "                          Example: --decoy 127.0.0.1:8443\n"
        "  --disable-obfs        Disable obfuscation entirely (for testing)\n"
        "  --port-hop-interval N [Client/Server] TOTP port-hopping slot length (seconds).\n"
        "                          0=disabled (default). Minimum 30.\n"
        "                          Port computed from PSK + slot number; client and server\n"
        "                          share the same sequence. Auto-switches every N seconds.\n"
        "                          Example: --port-hop-interval 60\n"
        "  --auth-interval N     [All] HMAC token slot length (seconds)  [default: 60; 0 = 30]\n"
        "                          Must be set identically on client, relay and server.\n"
        "                          1.3.x defaulted to 30: a 1.3.x peer without the option needs 30 here.\n"
        "                          Longer slots make boundary detection harder and increase clock tolerance.\n"
        "                          Minimum 30 seconds. Example: --auth-interval 60\n"
        "\n"
        "Simulation / debug:\n"
        "  -j N / --jitter N     Add artificial jitter 0-N ms (or min:max)  [default: 0]\n"
        "  --random-drop N       Simulate packet loss N/10000 (0-10000)  [default: 0]\n"
        "  --disable-checksum    Disable packet checksum\n"
        "\n"
        "Runtime control:\n"
        "  --fifo PATH           FIFO file for runtime commands (mtu/fec/mode/timeout)\n"
        "                          [default with --config: /run/multi-fec/<instance>.fifo]\n"
        "  --report N            Statistics report interval in seconds  [default: 60]\n"
        "\n"
        "Setup (with --config):\n"
        "  --check               Print effective settings and their source, check paths, routes,\n"
        "                          keys, permissions and port conflicts, then exit (1 on errors).\n"
        "  --apply-routes        Install the /32 routes that via/gw need (idempotent), then exit.\n"
        "                          Never overwrites a route multi-fec did not install.\n"
        "  --remove-routes       Remove this instance's routes unless another instance uses them.\n"
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

/* ─── key handling (v1.4.0) ──────────────────────────────────────
 * The key used to be visible to every local user in ps and /proc/<pid>/cmdline.
 * Overwrite it in place once copied: argv and the initial environment live in
 * the memory /proc reads, so this is what ps shows afterwards. A short window at
 * startup and the key length remain visible — key/key-file/MF_KEY avoid argv. */
static void scrub(char *p)
{
    if (p) for (; *p; p++) *p = '*';
}

static void set_key(const char *k, const char *from)
{
    if (strlen(k) > sizeof(g_key_string) - 1) {
        fprintf(stderr, "error: key longer than %zu characters\n", sizeof(g_key_string) - 1);
        exit(1);
    }
    strcpy(g_key_string, k);
    g_key_set  = true;
    g_key_from = from;
}

static int read_key_file(const char *path)
{
    std::ifstream f(path);
    if (!f) {
        fprintf(stderr, "error: cannot read --key-file %s: %s\n", path, strerror(errno));
        return -1;
    }
    std::string k;
    std::getline(f, k);
    while (!k.empty() && (k.back() == '\r' || k.back() == ' ' || k.back() == '\t')) k.pop_back();
    size_t a = k.find_first_not_of(" \t");
    k = a == std::string::npos ? "" : k.substr(a);
    set_key(k.c_str(), "key-file");
    if (mf_file_too_open(path))
        mylog(log_warn, "key file %s is readable by group/other — chmod 600\n", path);
    return 0;
}

/* ─── --path parsing ──────────────────────────────────────────────
 * "remote_ip:port" or "local_ip:remote_ip:port", then "via <if>" / "gw <ip>".
 * The parser lives in mf_netcfg.cpp so --config and --check share it. */

static int parse_path_spec(const char *spec, PathSpec &ps)
{
    std::string err;
    if (mf_parse_path_spec(spec, ps, err) != 0) {
        fprintf(stderr, "error: --path: %s\n", err.c_str());
        return -1;
    }
    return 0;
}

static int parse_path_spec_legacy(const char *spec, PathSpec &ps) __attribute__((unused));
static int parse_path_spec_legacy(const char *spec, PathSpec &ps)
{
    char local_str[64]  = "0.0.0.0";
    char remote_str[64] = {0};
    int  port           = 0;

    /* "local_ip:remote_ip:port" format: exactly two colons */
    if (sscanf(spec, "%63[^:]:%63[^:]:%d", local_str, remote_str, &port) != 3) {
        fprintf(stderr, "error: --path format is local_ip:remote_ip:port: '%s'\n", spec);
        return -1;
    }
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "error: --path port out of range (1-65535): %d\n", port);
        return -1;
    }

    /* local IP (no port, set to 0) */
    char local_with_port[72];
    snprintf(local_with_port, sizeof(local_with_port), "%s:0", local_str);
    ps.local.clear();
    if (ps.local.from_str(local_with_port) != 0) {
        fprintf(stderr, "error: --path local IP parse failed: '%s'\n", local_str);
        return -1;
    }

    /* remote IP:port */
    char remote_with_port[72];
    snprintf(remote_with_port, sizeof(remote_with_port), "%s:%d", remote_str, port);
    ps.remote.clear();
    if (ps.remote.from_str(remote_with_port) != 0) {
        fprintf(stderr, "error: --path remote parse failed: '%s:%d'\n", remote_str, port);
        return -1;
    }

    return 0;
}

/* ─── Argument parsing ────────────────────────────────────────── */

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
    OPT_UPSTREAM_LOCAL,
    OPT_ACCEPT_LOCAL,
    OPT_KEY,
    OPT_KEY_FILE,
    OPT_ROUTE_FILE,
    OPT_CONFIG,
    OPT_CHECK,
    OPT_APPLY_ROUTES,
    OPT_REMOVE_ROUTES,
};

static const struct option long_opts[] = {
    { "path",             required_argument, NULL, OPT_PATH            },
    { "wg",               required_argument, NULL, OPT_WG              },
    { "upstream",         required_argument, NULL, OPT_UPSTREAM        },
    { "multipath-mode",   required_argument, NULL, OPT_MULTIPATH_MODE  },
    { "dup-factor",       required_argument, NULL, OPT_DUP_FACTOR      },
    { "fec-timeout",      required_argument, NULL, OPT_FEC_TIMEOUT     },
    { "mode",             required_argument, NULL, OPT_FEC_MODE        },
    { "fec-mode",         required_argument, NULL, OPT_FEC_MODE        },
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
    { "upstream-local",     required_argument, NULL, OPT_UPSTREAM_LOCAL      },
    { "accept-local",       required_argument, NULL, OPT_ACCEPT_LOCAL        },
    { "key",                required_argument, NULL, OPT_KEY                 },
    { "key-file",           required_argument, NULL, OPT_KEY_FILE            },
    { "route-file",         required_argument, NULL, OPT_ROUTE_FILE          },
    { "config",             required_argument, NULL, OPT_CONFIG              },
    { "check",              no_argument,       NULL, OPT_CHECK               },
    { "apply-routes",       no_argument,       NULL, OPT_APPLY_ROUTES        },
    { "remove-routes",      no_argument,       NULL, OPT_REMOVE_ROUTES       },
    { "help",               no_argument,       NULL, 'h'                     },
    { NULL,               0,                 NULL, 0                   },
};

enum mf_action_t { ACT_RUN = 0, ACT_CHECK, ACT_APPLY_ROUTES, ACT_REMOVE_ROUTES };
static mf_action_t g_action = ACT_RUN;

static void parse_args(int argc, char *argv[])
{
    int opt, opt_idx = 0;

    while ((opt = getopt_long(argc, argv, "csrl:f:k:q:j:h", long_opts, &opt_idx)) != -1) {
        switch (opt) {
        case 'c':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: specify only one of -c/-s/-r\n");
                exit(1);
            }
            program_mode = client_mode;
            break;

        case 's':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: specify only one of -c/-s/-r\n");
                exit(1);
            }
            program_mode = server_mode;
            break;

        case 'r':
            if (program_mode != unset_mode) {
                fprintf(stderr, "error: specify only one of -c/-s/-r\n");
                exit(1);
            }
            program_mode = relay_mode;
            break;

        case 'l':
            if (local_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: -l address parse failed: '%s'\n", optarg);
                exit(1);
            }
            break;

        case 'f':
            strncpy(g_fec_str, optarg, sizeof(g_fec_str) - 1);
            break;

        case 'k':
        case OPT_KEY:
            set_key(optarg, "command line");
            scrub(optarg);
            break;

        case OPT_KEY_FILE:
            strncpy(g_key_file, optarg, sizeof(g_key_file) - 1);
            break;

        case OPT_ROUTE_FILE:
            strncpy(g_route_file, optarg, sizeof(g_route_file) - 1);
            break;

        case OPT_CONFIG:   /* consumed before getopt — see main() */
            break;
        case OPT_CHECK:         g_action = ACT_CHECK;         break;
        case OPT_APPLY_ROUTES:  g_action = ACT_APPLY_ROUTES;  break;
        case OPT_REMOVE_ROUTES: g_action = ACT_REMOVE_ROUTES; break;

        case OPT_PATH: {
            PathSpec ps;
            if (parse_path_spec(optarg, ps) != 0) exit(1);
            g_paths.push_back(ps);
            mylog(log_info, "path added: local=%s remote=%s%s%s\n",
                  ps.local.get_str(), ps.remote.get_str(),
                  ps.ifname[0] ? " via " : "", ps.ifname);
            break;
        }

        case OPT_WG:
            if (g_wg_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --wg address parse failed: '%s'\n", optarg);
                exit(1);
            }
            mylog(log_info, "WireGuard upstream: %s\n", g_wg_addr.get_str());
            break;

        case OPT_UPSTREAM:
            if (g_upstream_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --upstream address parse failed: '%s'\n", optarg);
                exit(1);
            }
            mylog(log_info, "relay upstream: %s\n", g_upstream_addr.get_str());
            break;

        case OPT_ACCEPT_LOCAL: {
            /* Bare IP only, like --upstream-local: the port comes from -l. */
            const char *colon = strchr(optarg, ':');
            if (optarg[0] == '[' || (colon && strchr(optarg, '.'))) {
                fprintf(stderr, "error: --accept-local takes a bare IP, not ip:port: '%s'\n", optarg);
                fprintf(stderr, "  the port is set by -l\n");
                exit(1);
            }
            if (g_accept_local.size() >= MUD_ACCEPT_LOCAL_MAX) {
                fprintf(stderr, "error: --accept-local accepts at most %d entries\n",
                        MUD_ACCEPT_LOCAL_MAX);
                fprintf(stderr, "  for more addresses, omit it (serve all) and filter in the firewall\n");
                exit(1);
            }
            address_t a;
            if (a.from_str_ip_only(optarg) != 0) {
                fprintf(stderr, "error: --accept-local address parse failed: '%s'\n", optarg);
                exit(1);
            }
            g_accept_local.push_back(a);
            mylog(log_info, "accept-local: %s\n", g_accept_local.back().get_str());
            break;
        }

        case OPT_UPSTREAM_LOCAL: {
            /* Bare IP only — no port. The relay allocates one upstream socket PER
             * client session, so a fixed source port would bind-collide on the
             * second session. Reject it explicitly rather than fail at runtime. */
            const char *colon = strchr(optarg, ':');
            if (optarg[0] == '[' || (colon && strchr(optarg, '.'))) {
                fprintf(stderr, "error: --upstream-local takes a bare IP, not ip:port: '%s'\n", optarg);
                fprintf(stderr, "  the source port is always ephemeral (one socket per relay session)\n");
                exit(1);
            }
            if (g_upstream_local.from_str_ip_only(optarg) != 0) {
                fprintf(stderr, "error: --upstream-local address parse failed: '%s'\n", optarg);
                exit(1);
            }
            mylog(log_info, "relay upstream source: %s\n", g_upstream_local.get_str());
            break;
        }

        case OPT_ROUTE: {
            /* --route "keystring ip:port [via if] [gw ip] [local ip]" */
            route_entry_t entry;
            std::string err;
            if (mf_parse_route_spec(optarg, entry, err) != 0) {
                /* err never contains the key */
                fprintf(stderr, "error: --route: %s\n", err.c_str());
                exit(1);
            }
            scrub(optarg);   /* the key is the first word */
            obfs_init(&entry.obfs, entry.key_str, g_obfs_mode);
            g_routes.push_back(entry);
            /* Fingerprint, never the key itself — this line lands in journald
             * and used to publish the PSK to anyone who can read the log. */
            char kfp[OBFS_KEY_FP_LEN];
            obfs_key_fingerprint(entry.key_str, kfp, sizeof(kfp));
            mylog(log_info, "route added: key=%s upstream=%s\n", kfp, entry.upstream_addr.get_str());
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
                fprintf(stderr, "error: --multipath-mode must be one of failover, duplicate, "
                                "aggregate, aggregate-duplicate\n");
                exit(1);
            }
            break;

        case OPT_DUP_FACTOR:
            g_dup_factor = (unsigned)atoi(optarg);
            if (g_dup_factor < 1 || g_dup_factor > 8) {
                fprintf(stderr, "error: --dup-factor range is 1–8\n");
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
                fprintf(stderr, "error: --obfs-mode must be quic or tls\n");
                exit(1);
            }
            break;

        case OPT_DECOY:
            if (g_decoy_addr.from_str(optarg) != 0) {
                fprintf(stderr, "error: --decoy address parse failed: '%s'\n", optarg);
                exit(1);
            }
            break;

        case OPT_DISABLE_OBFS:
            g_disable_obfs = 1;
            break;

        case OPT_PORT_HOP_INTERVAL:
            g_hop_interval = (uint32_t)atoi(optarg);
            if (g_hop_interval != 0 && g_hop_interval < 30) {
                fprintf(stderr, "error: --port-hop-interval minimum 30 seconds or 0 (disabled)\n");
                exit(1);
            }
            break;

        case OPT_AUTH_INTERVAL:
            g_auth_interval = (uint32_t)atoi(optarg);
            if (g_auth_interval != 0 && g_auth_interval < 30) {
                fprintf(stderr, "error: --auth-interval minimum 30 seconds or 0 (default 30s)\n");
                exit(1);
            }
            break;

        case OPT_VERSION:
            printf("multi-fec %s\n"
                   "git:   %s\n"
                   "build: %s\n",
                   MULTI_FEC_VERSION, gitversion, build_date);
            exit(0);

        case 'h':
            print_help(argv[0]);
            exit(0);

        default:
            fprintf(stderr, "unknown option\n");
            print_help(argv[0]);
            exit(1);
        }
    }
}

/* ─── mud_set_path wrapper ────────────────────────────────────── */

static void setup_static_paths(struct mud *mud)
{
    for (size_t i = 0; i < g_paths.size(); i++) {
        PathSpec &ps = g_paths[i];   /* non-const: address_t methods not const-qualified */

        struct mud_path_conf pc;
        memset(&pc, 0, sizeof(pc));

        pc.state      = MUD_UP;
        pc.loss_limit = 200;
        pc.fixed_rate = 0;
        pc.beat       = (uint64_t)(80 + rand() % 41) * 1000ULL;  /* 80–120ms random */

        /*
         * Failover             : pref 0,1,2,... — only the top path RUNNING, promoted on failure.
         * Duplicate            : pref=0 — all paths RUNNING simultaneously.
         * Aggregate            : pref=0 — all paths RUNNING, weighted round-robin distribution.
         * Aggregate-Duplicate  : pref=0 — all paths RUNNING, dup_factor sends per packet.
         */
        if (g_multipath_mode == MULTIPATH_FAILOVER)
            pc.pref = (unsigned char)i;
        else
            pc.pref = 0;
        pc.ifindex = ps.ifindex;   /* via <if>: 0 = kernel routes by destination */

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
            mylog(log_warn, "mud_set_path failed [%zu] remote=%s : %s\n",
                  i, ps.remote.get_str(), strerror(errno));
        else
            mylog(log_info, "static path registered [%zu] local=%s remote=%s\n",
                  i, ps.local.get_str(), ps.remote.get_str());
    }
}

/* ─── v1.4.0: --config, defaults, --check ──────────────────────── */

static mf_cfg                g_cfg;
static bool                  g_have_cfg = false;
static std::set<std::string> g_cli_names;          /* settings given on the command line */
static std::vector<std::string> g_cfg_args;        /* config translated to CLI tokens */
static std::vector<char *>   g_argv2;
static bool                  g_fifo_default = false;

/* Where a setting came from: "cli", "config" or "default". */
static const char *src_of(const char *name)
{
    if (g_cli_names.count(name)) return "cli";
    if (g_have_cfg) {
        if (!strcmp(name, "mode") && !g_cfg.mode.empty()) return "config";
        for (auto &it : g_cfg.items) if (it.first == name) return "config";
    }
    return "default";
}

/* Pull --config out of argv, load it, and lay out argv for getopt as
 * [prog] [config tokens] [command-line tokens] so the command line wins. */
static int build_argv(int argc, char *argv[], int &argc2, char **&argv2)
{
    const char *cfg_path = NULL;
    std::vector<char *> cli;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--config")) {
            if (i + 1 >= argc) { fprintf(stderr, "error: --config needs a file\n"); return -1; }
            cfg_path = argv[++i];
            continue;
        }
        if (!strncmp(argv[i], "--config=", 9)) { cfg_path = argv[i] + 9; continue; }
        cli.push_back(argv[i]);
        std::string c = mf_cli_canonical(argv[i]);
        if (!c.empty()) g_cli_names.insert(c);
    }
    g_argv2.push_back(argv[0]);
    if (cfg_path) {
        std::string err;
        if (mf_config_load(cfg_path, g_cfg, err) != 0) {
            fprintf(stderr, "error: %s\n", err.c_str());
            return -1;
        }
        g_have_cfg = true;
        mf_config_to_args(g_cfg, g_cli_names, g_cfg_args);
        for (std::string &a : g_cfg_args) g_argv2.push_back(&a[0]);
    }
    for (char *c : cli) g_argv2.push_back(c);
    g_argv2.push_back(NULL);
    argc2 = (int)g_argv2.size() - 1;
    argv2 = g_argv2.data();
    return 0;
}

static const char *mp_name(multipath_mode_t m)
{
    return m == MULTIPATH_DUPLICATE           ? "duplicate" :
           m == MULTIPATH_AGGREGATE           ? "aggregate" :
           m == MULTIPATH_AGGREGATE_DUPLICATE ? "aggregate-duplicate" : "failover";
}

/* Settings that took a v1.4.0 default the user did not choose — logged so an
 * upgrade that silently changed behaviour is visible in the journal. */
static std::string defaults_in_effect()
{
    std::string out;
    char b[64];
    auto add = [&](const char *name, const char *val) {
        if (strcmp(src_of(name), "default")) return;
        out += " "; out += name; out += "="; out += val;
    };
    if (program_mode == client_mode || program_mode == server_mode) {
        add("fec", g_fec_str);
        snprintf(b, sizeof(b), "%d", g_fec_mode);        add("fec-mode", b);
        snprintf(b, sizeof(b), "%d", g_fec_timeout_ms);  add("fec-timeout", b);
        snprintf(b, sizeof(b), "%d", g_mtu);             add("mtu", b);
        snprintf(b, sizeof(b), "%d", g_queue_len);       add("queue-len", b);
        add("multipath-mode", mp_name(g_multipath_mode));
        snprintf(b, sizeof(b), "%d", report_interval);   add("report", b);
    }
    snprintf(b, sizeof(b), "%d", g_sock_buf);            add("sock-buf", b);
    if (program_mode != relay_mode || g_key_set || !g_routes.empty()) {
        snprintf(b, sizeof(b), "%u", g_auth_interval);   add("auth-interval", b);
    }
    return out;
}

static bool is_tunnel_dev(const char *dev)
{
    return !strncmp(dev, "wg", 2) || !strncmp(dev, "tun", 3);
}

static bool addr_is_wildcard(address_t &a)
{
    return (a.get_type() == AF_INET && a.inner.ipv4.sin_addr.s_addr == htonl(INADDR_ANY)) ||
           (a.get_type() == AF_INET6 && IN6_IS_ADDR_UNSPECIFIED(&a.inner.ipv6.sin6_addr));
}

/* Resolve via <if> for client paths. Two paths to the SAME destination share
 * mud's path key (local, remote, port) unless their sources differ, so a
 * via-pinned path with a wildcard source takes the interface's IPv4 then. */
static int resolve_paths(std::string &err)
{
    for (size_t i = 0; i < g_paths.size(); i++) {
        PathSpec &ps = g_paths[i];
        if (!ps.ifname[0]) continue;
        ps.ifindex = mf_ifindex(ps.ifname);
        if (!ps.ifindex) { err = std::string("path via ") + ps.ifname + ": no such interface"; return -1; }
        bool shared = false;
        for (size_t j = 0; j < g_paths.size(); j++)
            if (j != i && !memcmp(&g_paths[j].remote.inner, &ps.remote.inner, sizeof(ps.remote.inner))) shared = true;
        if (shared && addr_is_wildcard(ps.local)) {
            struct in_addr ip;
            if (mf_if_ipv4(ps.ifname, &ip) != 0) {
                err = std::string("path via ") + ps.ifname + ": interface has no IPv4 address";
                return -1;
            }
            ps.local.from_ip_port_new(AF_INET, &ip, 0);
        }
    }
    return 0;
}

/* Egress of a client path as the kernel will route it. */
static int path_egress(PathSpec &ps, mf_route_info &ri)
{
    if (ps.remote.get_type() != AF_INET) return -1;
    struct in_addr src = ps.local.inner.ipv4.sin_addr;
    return mf_route_get(ps.remote.inner.ipv4.sin_addr, addr_is_wildcard(ps.local) ? NULL : &src,
                        ps.ifindex, ri);
}

/* listen-side address of an instance (what a second process would collide on) */
static void cfg_listen_addrs(const mf_cfg &c, std::vector<std::pair<std::string, std::string> > &out)
{
    std::string listen, wg;
    for (auto &it : c.items) {
        if (it.first == "listen") listen = it.second;
        if (it.first == "wg") wg = it.second;
    }
    if (c.mode == "client") out.push_back(std::make_pair("listen", listen.empty() ? "127.0.0.1:51821" : listen));
    if (c.mode == "server") {
        if (!listen.empty()) out.push_back(std::make_pair("listen", listen));
        out.push_back(std::make_pair("wg", wg.empty() ? "127.0.0.1:51820" : wg));
    }
    if (c.mode == "relay" && !listen.empty()) out.push_back(std::make_pair("listen", listen));
}

static bool addr_str_conflict(const std::string &a, const std::string &b)
{
    size_t ca = a.rfind(':'), cb = b.rfind(':');
    if (ca == std::string::npos || cb == std::string::npos) return false;
    if (a.substr(ca) != b.substr(cb)) return false;
    std::string ia = a.substr(0, ca), ib = b.substr(0, cb);
    return ia == ib || ia == "0.0.0.0" || ib == "0.0.0.0" || ia == "[::]" || ib == "[::]";
}

static int run_check()
{
    int errs = 0, warns = 0;
    auto ok   = [&](const std::string &m) { printf("  [OK]   %s\n", m.c_str()); };
    auto warn = [&](const std::string &m) { printf("  [WARN] %s\n", m.c_str()); warns++; };
    auto bad  = [&](const std::string &m) { printf("  [ERR]  %s\n", m.c_str()); errs++; };
    const char *mode = program_mode == client_mode ? "client" : program_mode == server_mode ? "server" :
                       program_mode == relay_mode ? "relay" : "(unset)";
    char b[256];

    printf("multi-fec %s --check%s%s\n", MULTI_FEC_VERSION, g_have_cfg ? "  " : "",
           g_have_cfg ? g_cfg.path.c_str() : "");
    printf("mode: %s%s%s\n\n", mode, g_have_cfg ? "   instance: " : "", g_have_cfg ? g_cfg.instance.c_str() : "");

    /* effective settings and where each came from */
    printf("settings (value / source):\n");
    auto row = [&](const char *name, const std::string &val) {
        printf("  %-16s %-34s %s\n", name, val.c_str(), src_of(name));
    };
    char kfp[OBFS_KEY_FP_LEN] = "kf:-";
    if (g_key_set) obfs_key_fingerprint(g_key_string, kfp, sizeof(kfp));
    if (local_addr.is_vaild()) row("listen", local_addr.get_str());
    if (program_mode == server_mode) row("wg", g_wg_addr.is_vaild() ? g_wg_addr.get_str() : "(unset)");
    for (PathSpec &ps : g_paths) {
        snprintf(b, sizeof(b), "%s from %s%s%s", ps.remote.get_str(), ps.local.get_str(),
                 ps.ifname[0] ? " via " : "", ps.ifname);
        row("path", b);
    }
    if (program_mode == relay_mode) {
        if (g_upstream_addr.is_vaild()) row("upstream", g_upstream_addr.get_str());
        if (g_upstream_local.is_vaild()) row("upstream-local", g_upstream_local.get_str());
        for (route_entry_t &r : g_routes) {
            char fp[OBFS_KEY_FP_LEN];
            obfs_key_fingerprint(r.key_str, fp, sizeof(fp));
            snprintf(b, sizeof(b), "%s -> %s%s%s%s%s", fp, r.upstream_addr.get_str(),
                     r.ifname[0] ? " via " : "", r.ifname,
                     r.local.is_vaild() ? " local " : "", r.local.is_vaild() ? r.local.get_str() : "");
            printf("  %-16s %-34s %s\n", "route", b, g_route_file[0] ? "route-file" : src_of("route"));
        }
    }
    printf("  %-16s %-34s %s\n", "key", kfp, g_key_set ? g_key_from : "-");
    snprintf(b, sizeof(b), "%u", g_auth_interval ? g_auth_interval : 30); row("auth-interval", b);
    row("obfs-mode", g_obfs_mode == OBFS_MODE_TLS ? "tls" : "quic");
    if (program_mode != relay_mode) {
        row("multipath-mode", mp_name(g_multipath_mode));
        row("fec", g_fec_str);
        snprintf(b, sizeof(b), "%d", g_fec_mode);        row("fec-mode", b);
        snprintf(b, sizeof(b), "%d", g_fec_timeout_ms);  row("fec-timeout", b);
        snprintf(b, sizeof(b), "%d", g_mtu);             row("mtu", b);
        snprintf(b, sizeof(b), "%u", fec_buff_num);      row("decode-buf", b);
        snprintf(b, sizeof(b), "%d", g_queue_len);       row("queue-len", b);
        snprintf(b, sizeof(b), "%d", report_interval);   row("report", b);
        row("fifo", fifo_file[0] ? fifo_file : "(none)");
    }
    snprintf(b, sizeof(b), "%d", g_sock_buf);            row("sock-buf", b);
    snprintf(b, sizeof(b), "%d", log_level);             row("log-level", b);

    printf("\nchecks:\n");
    if (program_mode == unset_mode) bad("no mode (mode = client|server|relay, or -c/-s/-r)");
    if (g_have_cfg) {
        if (mf_file_too_open(g_cfg.path.c_str())) warn(g_cfg.path + " is readable by group/other — chmod 600 (it holds the key)");
        else ok(g_cfg.path + " permissions");
    }
    if (g_key_file[0] && mf_file_too_open(g_key_file)) warn(std::string(g_key_file) + " is readable by group/other — chmod 600");
    if (g_route_file[0] && mf_file_too_open(g_route_file)) warn(std::string(g_route_file) + " is readable by group/other — chmod 600");
    if ((program_mode == client_mode || program_mode == server_mode) && !g_disable_obfs) {
        if (!g_key_set) bad("no key (key = ..., key-file = ..., or MF_KEY)");
        else ok(std::string("key ") + kfp + " from " + g_key_from);
    }
    if (program_mode == server_mode && !local_addr.is_vaild()) bad("server needs listen = ip:port");
    if (program_mode == relay_mode) {
        if (!local_addr.is_vaild()) bad("relay needs listen = ip:port");
        if (!g_upstream_addr.is_vaild() && g_routes.empty()) bad("relay needs upstream or route-file/route");
        for (size_t i = 0; i < g_routes.size(); i++)
            for (size_t j = 0; j < i; j++)
                if (!strcmp(g_routes[i].key_str, g_routes[j].key_str)) {
                    char fp[OBFS_KEY_FP_LEN];
                    obfs_key_fingerprint(g_routes[i].key_str, fp, sizeof(fp));
                    warn(std::string("route key ") + fp + " appears twice — only the first line is used");
                }
    }
    if (program_mode == client_mode && g_paths.empty()) bad("client needs at least one path");

    /* listen address present on this host (fixed IP bind fails with errno 99) */
    if (local_addr.is_vaild() && !addr_is_wildcard(local_addr) && program_mode != client_mode) {
        address_t ip = local_addr;
        if (!mf_local_addr_exists(ip)) bad(std::string("listen IP ") + local_addr.get_str() + " is not on this host (bind would fail)");
    }

    /* client paths */
    std::string perr;
    if (resolve_paths(perr) != 0) bad(perr);
    std::set<std::string> devs;
    for (size_t i = 0; i < g_paths.size(); i++) {
        PathSpec &ps = g_paths[i];
        std::string tag = std::string("path[") + std::to_string(i) + "] " + ps.remote.get_str();
        if (!addr_is_wildcard(ps.local) && !mf_local_addr_exists(ps.local))
            bad(tag + ": source " + ps.local.get_str() + " is not on this host (the path would never come up)");
        mf_route_info ri;
        if (path_egress(ps, ri) != 0 || !ri.found) { warn(tag + ": no route (" + strerror(errno) + ")"); continue; }
        std::string via = ri.has_gw ? " via " + mf_ip4_str(ri.gw) : "";
        if (is_tunnel_dev(ri.dev)) bad(tag + ": routed into tunnel " + ri.dev + " — routing loop (CLAUDE.md rule 2); add a /32 to the real gateway");
        else if (ps.ifindex && ri.oif == ps.ifindex && !ri.has_gw && !mf_if_onlink(ps.ifname, ps.remote.inner.ipv4.sin_addr))
            warn(tag + ": leaves " + ri.dev + " without a gateway — run --apply-routes (or add gw) or packets never leave");
        else ok(tag + ": leaves dev " + ri.dev + via);
        devs.insert(ri.dev);
    }
    if (g_paths.size() > 1 && devs.size() == 1) {
        std::string d = *devs.begin();
        if (mf_default_route_ifaces() >= 2)
            warn("all paths leave via " + d + " — the host has several uplinks but no line redundancy (use via, or /32 routes)");
        else
            printf("  [NOTE] all paths leave via %s (one uplink — redundancy is per relay, not per line)\n", d.c_str());
    }

    /* relay routes with via/local */
    for (route_entry_t &r : g_routes) {
        char fp[OBFS_KEY_FP_LEN];
        obfs_key_fingerprint(r.key_str, fp, sizeof(fp));
        if (r.local.is_vaild() && !mf_local_addr_exists(r.local))
            bad(std::string("route ") + fp + ": local " + r.local.get_str() + " is not on this host");
        if (r.ifname[0] && !mf_ifindex(r.ifname)) bad(std::string("route ") + fp + ": no interface " + r.ifname);
        if (r.upstream_addr.get_type() == AF_INET) {
            mf_route_info ri;
            if (mf_route_get(r.upstream_addr.inner.ipv4.sin_addr, NULL, mf_ifindex(r.ifname), ri) == 0 && ri.found &&
                is_tunnel_dev(ri.dev))
                bad(std::string("route ") + fp + ": upstream routed into tunnel " + ri.dev);
        }
    }

    /* what --apply-routes would do */
    std::vector<mf_want_route> want;
    std::string rerr;
    if (mf_collect_routes(g_paths, g_routes, want, rerr) != 0) bad(rerr);
    for (mf_want_route &w : want) {
        mf_route_info ex;
        mf_route_exact(w.dst, ex);
        std::string r = mf_ip4_str(w.dst) + "/32 via " + mf_ip4_str(w.gw) + " dev " + w.ifname;
        if (ex.found && ex.oif == w.oif && ex.has_gw && ex.gw.s_addr == w.gw.s_addr) ok("route " + r + " present");
        else if (ex.found) warn("route " + r + " wanted, but a different " + mf_ip4_str(w.dst) + "/32 exists (dev " + ex.dev + ")");
        else warn("route " + r + " missing — --apply-routes installs it (ExecStartPre)");
    }

    /* port already held by another process: mud and relay listen sockets set
     * SO_REUSEPORT, so a second one binds without error and splits the traffic */
    if (local_addr.is_vaild()) {
        std::vector<mf_port_owner> owners;
        address_t la = local_addr;
        mf_udp_port_owners(la, owners);
        for (mf_port_owner &o : owners) {
            bool self = g_have_cfg && o.cmdline.find(g_cfg.path) != std::string::npos;
            if (self) { printf("  [NOTE] %s is held by this instance (pid %d, running)\n", local_addr.get_str(), o.pid); continue; }
            snprintf(b, sizeof(b), "%s is already bound by pid %d: %.80s", local_addr.get_str(), o.pid, o.cmdline.c_str());
            bad(std::string(b) + " — a second process would bind silently (SO_REUSEPORT) and split the traffic");
        }
        if (owners.empty()) ok(std::string(local_addr.get_str()) + " is free");
    }

    /* other instances configured next to this one */
    if (g_have_cfg) {
        std::string dir = g_cfg.path;
        size_t sl = dir.rfind('/');
        dir = sl == std::string::npos ? "." : dir.substr(0, sl);
        std::vector<std::pair<std::string, std::string> > mine;
        cfg_listen_addrs(g_cfg, mine);
        DIR *d = opendir(dir.c_str());
        while (d) {
            struct dirent *e = readdir(d);
            if (!e) break;
            std::string n = e->d_name;
            if (n.size() < 6 || n.compare(n.size() - 5, 5, ".conf")) continue;
            std::string full = dir + "/" + n;
            if (full == g_cfg.path || ("./" + n) == g_cfg.path || n == g_cfg.path) continue;
            mf_cfg other;
            std::string e2;
            if (mf_config_load(full.c_str(), other, e2) != 0 || other.mode.empty()) continue;   /* not a --config file */
            std::vector<std::pair<std::string, std::string> > theirs;
            cfg_listen_addrs(other, theirs);
            for (auto &m : mine)
                for (auto &t : theirs)
                    if (m.first == t.first && addr_str_conflict(m.second, t.second))
                        bad(m.first + " " + m.second + " is also used by " + full);
        }
        if (d) closedir(d);
    }

    printf("\nresult: %d error(s), %d warning(s)\n", errs, warns);
    return errs ? 1 : 0;
}

/* ─── main ───────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    working_mode = tunnel_mode;

    if (argc == 1) {
        print_help(argv[0]);
        return 1;
    }

    report_interval = 60;   /* v1.4.0 default (was 0 = off); --report overrides */

    int argc2;
    char **argv2;
    if (build_argv(argc, argv, argc2, argv2) != 0) return 1;
    parse_args(argc2, argv2);

    /* key: -k/--key/"key =" > --key-file > MF_KEY */
    if (g_key_set && !g_cli_names.count("key")) g_key_from = "config";
    if (!g_key_set && g_key_file[0] && read_key_file(g_key_file) != 0) return 1;
    if (!g_key_set) {
        const char *e = getenv("MF_KEY");
        if (e) set_key(e, "MF_KEY");
    }
    for (char **ep = environ; ep && *ep; ep++)   /* /proc/<pid>/environ is owner-only; scrub anyway */
        if (!strncmp(*ep, "MF_KEY=", 7)) scrub(*ep + 7);
    if (g_key_set && g_key_string[0] == '\0') {
        fprintf(stderr, "error: the key is empty (from %s)\n", g_key_from);
        fprintf(stderr, "  an empty key authenticates nothing — set the same non-empty key on every hop\n");
        return 1;
    }

    /* relay: --route-file */
    if (g_route_file[0]) {
        std::vector<route_entry_t> rf;
        std::string err;
        if (mf_load_route_file(g_route_file, rf, err) != 0) {
            fprintf(stderr, "error: %s\n", err.c_str());
            return 1;
        }
        if (rf.empty()) {
            fprintf(stderr, "error: %s has no routes\n", g_route_file);
            return 1;
        }
        for (route_entry_t &r : rf) g_routes.push_back(r);
        mylog(log_info, "route-file %s: %zu route(s)\n", g_route_file, rf.size());
        if (mf_file_too_open(g_route_file))
            mylog(log_warn, "%s is readable by group/other — chmod 600 (it holds keys)\n", g_route_file);
    }
    for (size_t i = 0; i < g_routes.size(); i++)
        for (size_t j = 0; j < i; j++)
            if (!strcmp(g_routes[i].key_str, g_routes[j].key_str)) {
                char fp[OBFS_KEY_FP_LEN];
                obfs_key_fingerprint(g_routes[i].key_str, fp, sizeof(fp));
                mylog(log_warn, "route key %s appears twice — the first match wins, route[%zu] is never used\n", fp, i);
            }

    /* v1.4.0 role defaults */
    if (program_mode == client_mode && !local_addr.is_vaild()) {
        char d[] = "127.0.0.1:51821";
        local_addr.from_str(d);
    }
    if (program_mode == server_mode && !g_wg_addr.is_vaild()) {
        char d[] = "127.0.0.1:51820";
        g_wg_addr.from_str(d);
    }
    if (g_have_cfg && fifo_file[0] == '\0' &&
        (program_mode == client_mode || program_mode == server_mode)) {
        snprintf(fifo_file, sizeof(fifo_file), "%s/%s.fifo", MF_RUN_DIR, g_cfg.instance.c_str());
        g_fifo_default = true;
    }

    if (g_action == ACT_CHECK) return run_check();
    if (g_action == ACT_APPLY_ROUTES || g_action == ACT_REMOVE_ROUTES) {
        if (!g_have_cfg) {
            fprintf(stderr, "error: --apply-routes/--remove-routes need --config (the instance name keys the route record)\n");
            return 1;
        }
        if (g_action == ACT_REMOVE_ROUTES) return mf_remove_routes(g_cfg.instance.c_str());
        std::string err;
        if (resolve_paths(err) != 0) { fprintf(stderr, "error: %s\n", err.c_str()); return 1; }
        std::vector<mf_want_route> want;
        if (mf_collect_routes(g_paths, g_routes, want, err) != 0) {
            fprintf(stderr, "error: %s\n", err.c_str());
            return 1;
        }
        return mf_apply_routes(g_cfg.instance.c_str(), want);
    }

    mylog(log_info, "multi-fec %s (git %s) build %s\n", MULTI_FEC_VERSION, gitversion, build_date);
    if (g_have_cfg) {
        mylog(log_info, "config %s (instance %s)\n", g_cfg.path.c_str(), g_cfg.instance.c_str());
        if (mf_file_too_open(g_cfg.path.c_str()))
            mylog(log_warn, "%s is readable by group/other — chmod 600 (it holds the key)\n", g_cfg.path.c_str());
    }
    if (g_key_set) {
        char kfp[OBFS_KEY_FP_LEN];
        obfs_key_fingerprint(g_key_string, kfp, sizeof(kfp));
        mylog(log_info, "key %s from %s\n", kfp, g_key_from);
    }
    {
        std::string d = defaults_in_effect();
        if (!d.empty()) mylog(log_info, "v1.4.0 defaults in effect (not set in config/CLI):%s\n", d.c_str());
    }

    /* mode validation */
    if (program_mode == unset_mode) {
        fprintf(stderr, "error: specify one of -c (client), -s (server), -r (relay)\n");
        print_help(argv[0]);
        return 1;
    }
    if (!local_addr.is_vaild()) {
        fprintf(stderr, "error: specify the -l local address\n");
        return 1;
    }

    /* client: --path required */
    if (program_mode == client_mode && g_paths.empty()) {
        fprintf(stderr, "error: specify at least one --path in client mode\n");
        fprintf(stderr, "  e.g.: --path 0.0.0.0:SERVER_IP:443\n");
        return 1;
    }

    /* server: --wg required */
    if (program_mode == server_mode && !g_wg_addr.is_vaild()) {
        fprintf(stderr, "error: specify --wg WireGuardAddr:Port in server mode\n");
        fprintf(stderr, "  e.g.: --wg 127.0.0.1:51820\n");
        return 1;
    }

    /* client/server: -k required whenever obfs is on.
     *
     * g_key_string defaults to a literal that ships in the source, so omitting
     * -k silently made the PSK public knowledge: anyone who can reach the UDP
     * port could then forge authenticated packets. Refuse to start rather than
     * run with a known key. --disable-obfs has no PSK at all, so it is exempt,
     * and relay keeps -k optional because it also serves as a transparent
     * forwarder (its key-based routing supplies keys through --route). */
    if ((program_mode == client_mode || program_mode == server_mode) &&
        !g_disable_obfs && !g_key_set) {
        fprintf(stderr, "error: specify -k <key> in %s mode\n",
                program_mode == client_mode ? "client" : "server");
        fprintf(stderr, "  the built-in default key is public — it authenticates nothing\n");
        fprintf(stderr, "  use the same key on client and server, or pass --disable-obfs for local tests\n");
        return 1;
    }

    /* relay: at least one of --upstream or --route required. FEC not needed → enter directly */
    /* If --route is parsed before --obfs-mode, the route obfs mode is initialized to the
     * default (QUIC). Reapply the final g_obfs_mode after parsing to ensure order independence. */
    for (auto &route : g_routes) {
        obfs_init(&route.obfs, route.key_str, g_obfs_mode);
        if (g_auth_interval) route.obfs.auth_interval = g_auth_interval;
    }

    /* rand() seed init — used for beat randomization and probe response size randomization.
     * clock_gettime nanoseconds gives higher entropy than second-granularity time().
     * Not a security random, so rand() is sufficient. */
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        srand((unsigned)(ts.tv_sec ^ ts.tv_nsec));
    }

    /* --accept-local validation.
     *
     * The filter lives in mud_recv(), so it only exists where mud does. The client
     * pins its local address per path via --path, and the relay's listen socket is
     * outside mud (no IP_PKTINFO plumbed), so accepting the option there would do
     * nothing. Refuse rather than appear to work. */
    if (!g_accept_local.empty()) {
        if (program_mode != server_mode) {
            fprintf(stderr, "error: --accept-local is valid only in server mode (-s)\n");
            fprintf(stderr, "  client: --path <local_ip>:<remote_ip>:<port> already pins the local IP\n");
            return 1;
        }
        /* A non-wildcard -l is already restricted by the kernel, so entries that do
         * not equal it can never match. That configuration drops every packet with
         * no log line — the hardest failure to diagnose — so refuse it outright. */
        int wildcard =
            (local_addr.get_type() == AF_INET &&
             local_addr.inner.ipv4.sin_addr.s_addr == htonl(INADDR_ANY)) ||
            (local_addr.get_type() == AF_INET6 &&
             IN6_IS_ADDR_UNSPECIFIED(&local_addr.inner.ipv6.sin6_addr));
        if (!wildcard) {
            for (address_t &a : g_accept_local) {
                int same = (a.get_type() == local_addr.get_type()) &&
                    (a.get_type() == AF_INET
                     ? a.inner.ipv4.sin_addr.s_addr == local_addr.inner.ipv4.sin_addr.s_addr
                     : !memcmp(&a.inner.ipv6.sin6_addr, &local_addr.inner.ipv6.sin6_addr,
                               sizeof(a.inner.ipv6.sin6_addr)));
                if (!same) {
                    fprintf(stderr, "error: --accept-local %s can never match: "
                            "-l is bound to a specific address\n", a.get_str());
                    fprintf(stderr, "  -l %s already restricts arrivals to that address\n",
                            local_addr.get_str());
                    fprintf(stderr, "  use -l 0.0.0.0:<port> to serve several addresses, "
                            "or drop --accept-local\n");
                    return 1;
                }
            }
            mylog(log_warn, "--accept-local is redundant: -l %s is not a wildcard\n",
                  local_addr.get_str());
        }
        /* A typo here silently blackholes everything, so check the addresses exist.
         * A warning, not an error: a floating VIP may legitimately appear later. */
        struct ifaddrs *ifa = NULL;
        if (getifaddrs(&ifa) == 0) {
            for (address_t &a : g_accept_local) {
                bool found = false;
                for (struct ifaddrs *p = ifa; p && !found; p = p->ifa_next) {
                    if (!p->ifa_addr || p->ifa_addr->sa_family != a.get_type()) continue;
                    if (a.get_type() == AF_INET)
                        found = ((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr ==
                                a.inner.ipv4.sin_addr.s_addr;
                    else
                        found = !memcmp(&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr,
                                        &a.inner.ipv6.sin6_addr, sizeof(a.inner.ipv6.sin6_addr));
                }
                if (!found)
                    mylog(log_warn, "--accept-local %s is not configured on any interface "
                          "— nothing will match it until it is\n", a.get_str());
            }
            freeifaddrs(ifa);
        }
    }

    /* --upstream-local only affects the relay's upstream socket. Silently ignoring it
     * elsewhere would look like it took effect, so refuse instead. */
    if (g_upstream_local.is_vaild() && program_mode != relay_mode) {
        fprintf(stderr, "error: --upstream-local is valid only in relay mode (-r)\n");
        fprintf(stderr, "  client: use --path <local_ip>:<remote_ip>:<port> to set the source IP\n");
        return 1;
    }

    if (program_mode == relay_mode) {
        if (!g_upstream_addr.is_vaild() && g_routes.empty()) {
            fprintf(stderr, "error: specify --upstream or --route in relay mode\n");
            fprintf(stderr, "  single upstream: --upstream 1.2.3.4:443\n");
            fprintf(stderr, "  key-based routing: --route \"key1 1.2.3.4:443\" --route \"key2 5.6.7.8:443\"\n");
            return 1;
        }
        /* The FIFO is set up further down, past this branch, so relay mode never
         * opens it. Say so instead of accepting the option silently -- a production
         * relay unit carried --fifo for months believing it worked (2026-10-06). */
        if (fifo_file[0] != '\0')
            mylog(log_warn, "--fifo %s is ignored in relay mode (runtime commands are client/server only)\n",
                  fifo_file);

        init_random_number_fd();
        signal(SIGPIPE, SIG_IGN);

        ev_signal_init(&g_ev_sigterm, ev_sig_cb, SIGTERM);
        ev_signal_init(&g_ev_sigint,  ev_sig_cb, SIGINT);
        ev_signal_start(ev_default_loop(0), &g_ev_sigterm);
        ev_signal_start(ev_default_loop(0), &g_ev_sigint);

        /* if -k is set, enable HMAC verification; otherwise transparent relay (applies only when --route is unused) */
        static struct obfs_ctx relay_obfs;
        const struct obfs_ctx *relay_obfs_ptr = NULL;
        if (g_key_set && g_routes.empty()) {
            obfs_init(&relay_obfs, g_key_string, g_obfs_mode);
            if (g_auth_interval) relay_obfs.auth_interval = g_auth_interval;
            relay_obfs_ptr = &relay_obfs;
            mylog(log_info, "relay HMAC verification enabled (obfs=%s)\n",
                  g_obfs_mode == OBFS_MODE_TLS ? "tls" : "quic");
        }

        if (!g_routes.empty()) {
            mylog(log_info, "relay mode started: %s  %zu key-based routes\n",
                  local_addr.get_str(), g_routes.size());
        } else {
            mylog(log_info, "relay mode started: %s → %s\n",
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

    /* client: generate a random session_id
     * used so the server can identify the same client regardless of POP transit. */
    if (program_mode == client_mode) {
        int rfd = open("/dev/urandom", O_RDONLY);
        if (rfd < 0 || read(rfd, g_session_id, SESSION_ID_LEN) != SESSION_ID_LEN) {
            mylog(log_fatal, "session_id generation failed\n");
            return 1;
        }
        close(rfd);
        mylog(log_info, "session_id: %016llx\n",
              (unsigned long long)(*(uint64_t *)g_session_id));
    }

    /* client paths: via <if>, egress per path, tunnel loop guard */
    if (program_mode == client_mode) {
        std::string err;
        if (resolve_paths(err) != 0) { fprintf(stderr, "error: %s\n", err.c_str()); return 1; }
        std::set<std::string> devs;
        for (size_t i = 0; i < g_paths.size(); i++) {
            mf_route_info ri;
            if (path_egress(g_paths[i], ri) != 0 || !ri.found) {
                mylog(log_warn, "path[%zu] %s: no route right now (%s)\n", i, g_paths[i].remote.get_str(), strerror(errno));
                continue;
            }
            if (is_tunnel_dev(ri.dev)) {
                /* the tunnel would carry its own transport: duplicate doubles it every lap */
                mylog(log_fatal, "path[%zu] %s is routed into %s — refusing to start (routing loop). "
                      "Route the relay/server IPs to the real gateway (a /32)\n", i, g_paths[i].remote.get_str(), ri.dev);
                return 1;
            }
            mylog(log_info, "path[%zu] %s leaves dev %s%s%s\n", i, g_paths[i].remote.get_str(), ri.dev,
                  ri.has_gw ? " via " : "", ri.has_gw ? mf_ip4_str(ri.gw).c_str() : "");
            devs.insert(ri.dev);
        }
        if (g_paths.size() > 1 && devs.size() == 1 && mf_default_route_ifaces() >= 2)
            mylog(log_warn, "all %zu paths leave via %s although the host has several uplinks — "
                  "no line redundancy (see --check)\n", g_paths.size(), devs.begin()->c_str());
    }

    /* FEC parameters */
    strncpy(rs_par_str, g_fec_str, rs_str_len - 1);
    if (g_fec_par.rs_from_str(g_fec_str) != 0) {
        fprintf(stderr, "error: FEC parameter parse failed: '%s'\n", g_fec_str);
        return 1;
    }
    g_fec_par.timeout   = g_fec_timeout_ms * 1000;
    g_fec_par.mtu       = g_mtu;
    g_fec_par.queue_len = g_queue_len;
    g_fec_par.mode      = g_fec_mode;

    print_parameter();

    /* obfs initialization */
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

    /* mud creation
     *
     * Server: mud socket = listen socket (bound to -l address)
     * Client: the mud socket is separate from the WireGuard proxy port (-l).
     *   Created as 0.0.0.0:0 → OS assigns an arbitrary port.
     *   Per-path source IP is selected via IP_PKTINFO in mud_send_path().
     */
    union mud_sockaddr mud_local;
    memset(&mud_local, 0, sizeof(mud_local));

    if (program_mode == server_mode) {
        if (local_addr.get_type() == AF_INET)
            mud_local.sin  = local_addr.inner.ipv4;
        else
            mud_local.sin6 = local_addr.inner.ipv6;
    } else {
        /* client: 0.0.0.0:0 */
        mud_local.sin.sin_family      = AF_INET;
        mud_local.sin.sin_addr.s_addr = htonl(INADDR_ANY);
        mud_local.sin.sin_port        = 0;
    }

    struct mud *mud = mud_create(&mud_local);
    if (!mud) {
        mylog(log_fatal, "mud creation failed: %s\n", strerror(errno));
        return 1;
    }
    mylog(log_info, "mud fd=%d\n", mud_get_fd(mud));

    /* --accept-local: hand the allow-list to mud. Validated in parse_args(). */
    for (address_t &a : g_accept_local) {
        union mud_sockaddr ml;
        memset(&ml, 0, sizeof(ml));
        if (a.get_type() == AF_INET) ml.sin  = a.inner.ipv4;
        else                         ml.sin6 = a.inner.ipv6;
        if (mud_add_accept_local(mud, &ml) != 0) {
            mylog(log_fatal, "accept-local registration failed: %s\n", strerror(errno));
            return 1;
        }
    }
    if (!g_accept_local.empty())
        mylog(log_info, "accept-local: serving %zu local address(es) only\n",
              g_accept_local.size());

    /* socket buffer setup (--sock-buf) */
    if (g_sock_buf > 0) {
        int rcv_kb = 0, snd_kb = 0;
        int r = mf_set_sock_buf(mud_get_fd(mud), g_sock_buf, &rcv_kb, &snd_kb);
        if (r < 0)
            mylog(log_warn, "sock-buf setsockopt failed: %s\n", strerror(errno));
        else if (r > 0)
            mylog(log_warn, "sock-buf=%d kB requested but kernel capped it at rcv=%d snd=%d kB — "
                  "raise net.core.rmem_max/wmem_max or run with CAP_NET_ADMIN\n",
                  g_sock_buf, rcv_kb, snd_kb);
        else
            mylog(log_info, "sock-buf=%d kB (rcv=%d snd=%d kB)\n", g_sock_buf, rcv_kb, snd_kb);
    }

    /* FIFO runtime command channel. create_fifo() exits on failure, so a FIFO
     * derived from the instance name is skipped (not fatal) when its directory
     * is missing — e.g. a manual run outside the unit's ExecStartPre mkdir. */
    if (g_fifo_default && access(MF_RUN_DIR, W_OK) != 0) {
        mylog(log_warn, "FIFO %s skipped (%s not writable) — runtime commands disabled\n", fifo_file, MF_RUN_DIR);
        fifo_file[0] = '\0';
    }
    static struct ev_io fifo_watcher;
    if (fifo_file[0] != '\0') {
        int fifo_fd = create_fifo(fifo_file);
        if (fifo_fd < 0) {
            mylog(log_fatal, "FIFO creation failed: %s\n", fifo_file);
            return 1;
        } else {
            mylog(log_info, "fifo=%s fd=%d\n", fifo_file, fifo_fd);
            ev_io_init(&fifo_watcher, fifo_read_cb, fifo_fd, EV_READ);
            ev_io_start(ev_default_loop(0), &fifo_watcher);
        }
    }

    /* register obfs hooks */
    if (!g_disable_obfs)
        mud_set_obfs(mud, obfs_enc_cb, obfs_dec_cb, obfs_init_cb, &obfs);
    else
        mylog(log_warn, "obfs disabled (--disable-obfs)\n");

    /* mud keepalive setup
     * mud time unit = microseconds (MUD_ONE_MSEC=1000, MUD_ONE_SEC=1,000,000)
     * timetolerance: allowed skew between packet send/receive times.
     *   0 = use mud_create default (10s). At least a few seconds needed given WAN RTT. */
    struct mud_conf mconf;
    memset(&mconf, 0, sizeof(mconf));
    mconf.keepalive     = 5000000ULL;   /* 5s (5,000,000 µs) */
    mconf.timetolerance = 30000000ULL;  /* 30s — matches HMAC ±30s tolerance, handles clock skew */
    mud_set(mud, &mconf);

    setnonblocking(mud_get_fd(mud));

    /* client: register static paths */
    if (program_mode == client_mode)
        setup_static_paths(mud);

    /* port hopping (--port-hop-interval)
     * Client: PortHopper switches the remote port of mud paths via TOTP
     * Server: mf_server_event_loop manages per-slot raw UDP sockets directly */
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
        mylog(log_info, "%s mode started (multipath=%s dup-factor=%u)\n",
              program_mode == client_mode ? "client" : "server",
              mp_mode_str, g_dup_factor);
    else
        mylog(log_info, "%s mode started (multipath=%s)\n",
              program_mode == client_mode ? "client" : "server", mp_mode_str);

    if (program_mode == client_mode)
        mf_client_event_loop(mud, &obfs);
    else
        mf_server_event_loop(mud, &obfs, -1, g_decoy_addr);

    if (hopper) {
        hopper->stop(ev_default_loop(0));
        delete hopper;
    }

    mud_delete(mud);
    mylog(log_info, "exiting\n");
    return 0;
}
