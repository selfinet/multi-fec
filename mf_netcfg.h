#pragma once
/*
 * mf_netcfg.h — v1.4.0 network-side configuration helpers
 *
 *   - --path / --route spec parsing, shared by the CLI, --config and --route-file
 *   - interface lookups (index, IPv4, on-link)
 *   - IPv4 main-table route queries and /32 install/remove over rtnetlink
 *     (--check, --apply-routes, --remove-routes, the client's per-path egress report)
 *   - who already holds a UDP port (--check: SO_REUSEPORT lets a second process
 *     bind silently and split the traffic)
 *
 * Background and measurements: DESIGN-1.4.0.md §6–§8.
 */
#include "mf_common.h"
#include <netinet/in.h>
#include <string>
#include <vector>

/* ── spec parsing ───────────────────────────────────────────────── */

/* "remote_ip:port"  or  "local_ip:remote_ip:port", then optional
 * "via <ifname>" and "gw <ipv4>" (gw requires via). */
int mf_parse_path_spec(const char *spec, PathSpec &ps, std::string &err);

/* "<key> <ip:port>" then optional "via <ifname>", "gw <ipv4>", "local <ip>". */
int mf_parse_route_spec(const char *spec, route_entry_t &re, std::string &err);

/* Read a route file: one route spec per line, '#' comments. Appends to out.
 * Returns 0, or -1 with err set (file/line). */
int mf_load_route_file(const char *path, std::vector<route_entry_t> &out, std::string &err);

/* Warn-worthy permission bits (group/other readable) on a file holding keys. */
bool mf_file_too_open(const char *path);

/* ── interfaces ─────────────────────────────────────────────────── */

unsigned mf_ifindex(const char *ifname);                       /* 0 = no such interface */
int      mf_if_ipv4(const char *ifname, struct in_addr *out);  /* first IPv4, 0 = found */
bool     mf_if_onlink(const char *ifname, struct in_addr dst); /* dst inside one of its IPv4 subnets */
bool     mf_local_addr_exists(address_t &a);                   /* IP configured on any interface */

/* ── routes (IPv4, rtnetlink) ───────────────────────────────────── */

struct mf_route_info {
    bool           found;
    unsigned       oif;
    char           dev[16];
    bool           has_gw;
    struct in_addr gw;
    bool           has_src;
    struct in_addr src;
};

/* Like `ip route get <dst> [from <src>] [oif <oif>]`. src/oif may be NULL/0. */
int mf_route_get(struct in_addr dst, const struct in_addr *src, unsigned oif, mf_route_info &out);

/* Lowest-metric default route out of oif in the main table. 0 = found. */
int mf_route_default_gw(unsigned oif, struct in_addr *gw);

/* Number of distinct interfaces holding an IPv4 default route in the main table. */
int mf_default_route_ifaces();

/* Existing <dst>/32 in the main table (any gateway/device). out.found tells. */
int mf_route_exact(struct in_addr dst, mf_route_info &out);

int mf_route_replace(struct in_addr dst, struct in_addr gw, unsigned oif);  /* idempotent */
int mf_route_delete (struct in_addr dst, struct in_addr gw, unsigned oif);  /* gone = ok */

/* ── --apply-routes / --remove-routes ───────────────────────────── */

struct mf_want_route {
    struct in_addr dst;
    struct in_addr gw;
    unsigned       oif;
    char           ifname[16];
};

#define MF_RUN_DIR "/run/multi-fec"

/* Routes this instance needs: one /32 per path/route that has "via" and whose
 * destination is not already on-link for that interface. Fills gw from the
 * interface default when not given. Returns 0, or -1 with err set. */
int mf_collect_routes(const std::vector<PathSpec> &paths, const std::vector<route_entry_t> &routes,
                      std::vector<mf_want_route> &out, std::string &err);

/* Install (replace) the wanted routes, record them in MF_RUN_DIR/<instance>.routes,
 * and drop routes this instance installed before that are no longer wanted and
 * not recorded by another instance. A differing /32 that no multi-fec instance
 * recorded (netplan, an operator) is never overwritten: returns 1. */
int mf_apply_routes(const char *instance, const std::vector<mf_want_route> &want);

/* Remove what MF_RUN_DIR/<instance>.routes recorded, except routes another
 * instance also recorded. */
int mf_remove_routes(const char *instance);

/* ── UDP port owners ────────────────────────────────────────────── */

struct mf_port_owner {
    int         pid;      /* 0 = socket found but owner not visible (needs root) */
    std::string cmdline;
};

/* Processes holding a UDP socket bound to the port of addr (same IP or wildcard). */
int mf_udp_port_owners(address_t &addr, std::vector<mf_port_owner> &out);

/* Human-readable "a.b.c.d" (static buffer per call site is the caller's problem). */
std::string mf_ip4_str(struct in_addr a);
