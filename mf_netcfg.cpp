/*
 * mf_netcfg.cpp — v1.4.0 network-side configuration helpers. See mf_netcfg.h.
 */
#include "mf_netcfg.h"
#include "log.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>

/* ─── small utilities ───────────────────────────────────────────── */

std::string mf_ip4_str(struct in_addr a)
{
    char b[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &a, b, sizeof(b));
    return b;
}

static std::vector<std::string> split_ws(const char *s)
{
    std::vector<std::string> v;
    std::istringstream is(s);
    std::string t;
    while (is >> t) v.push_back(t);
    return v;
}

static int parse_ip4(const std::string &s, struct in_addr *out)
{
    return inet_pton(AF_INET, s.c_str(), out) == 1 ? 0 : -1;
}

/* address_t::from_str()/from_str_ip_only() exit the process on bad input
 * (upstream code), so validate with inet_pton first and only then call them. */
static int safe_addr(const std::string &s, address_t &a, bool with_port)
{
    std::string ip = s, port;
    if (with_port) {
        size_t c = s.rfind(':');
        if (c == std::string::npos) return -1;
        ip = s.substr(0, c);
        port = s.substr(c + 1);
        char *end = NULL;
        long p = strtol(port.c_str(), &end, 10);
        if (port.empty() || *end || p < 0 || p > 65535) return -1;
        if (ip.size() > 2 && ip[0] == '[' && ip[ip.size() - 1] == ']') ip = ip.substr(1, ip.size() - 2);
    }
    unsigned char buf[16];
    int fam = ip.find(':') == std::string::npos ? AF_INET : AF_INET6;
    if (inet_pton(fam, ip.c_str(), buf) != 1) return -1;
    std::string copy = s;
    return with_port ? a.from_str((char *)copy.c_str()) : a.from_str_ip_only((char *)copy.c_str());
}

/* A trailing "# ..." is a comment. systemd's EnvironmentFile does not strip inline
 * comments, so `DEST_A=1.2.3.4:443   # relay ch1` reaches us as part of the value;
 * 1.3.x ignored everything after the port, and service configs rely on that
 * (DJ08M, 2026-10-19). Drop it with a warning instead of refusing to start. */
static std::vector<std::string> split_spec(const char *spec, const char *what)
{
    std::vector<std::string> t = split_ws(spec);
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i][0] != '#') continue;
        /* never echo the value: a route spec starts with the key */
        mylog(log_warn, "%s: trailing \"# ...\" comment ignored — systemd EnvironmentFile keeps inline "
              "comments in the value; put comments on their own line\n", what);
        t.resize(i);
        break;
    }
    return t;
}

bool mf_file_too_open(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0) return false;
    return (st.st_mode & 077) != 0;
}

/* ─── spec parsing ──────────────────────────────────────────────── */

int mf_parse_path_spec(const char *spec, PathSpec &ps, std::string &err)
{
    memset(&ps, 0, sizeof(ps));
    std::vector<std::string> t = split_spec(spec, "--path");
    if (t.empty()) { err = "empty path"; return -1; }

    /* first token: "ip:port" (source auto) or the original "local:remote:port" */
    const std::string &a = t[0];
    size_t colons = std::count(a.begin(), a.end(), ':');
    std::string local = "0.0.0.0", remote_ip, port_s;
    if (colons == 1) {
        remote_ip = a.substr(0, a.find(':'));
        port_s    = a.substr(a.find(':') + 1);
    } else if (colons == 2) {
        size_t c1 = a.find(':'), c2 = a.find(':', c1 + 1);
        local     = a.substr(0, c1);
        remote_ip = a.substr(c1 + 1, c2 - c1 - 1);
        port_s    = a.substr(c2 + 1);
    } else {
        err = "path is <remote_ip>:<port> or <local_ip>:<remote_ip>:<port>: '" + a + "'";
        return -1;
    }
    char *end = NULL;
    long port = strtol(port_s.c_str(), &end, 10);
    if (port_s.empty() || *end || port <= 0 || port > 65535) {
        err = "path port out of range (1-65535): '" + port_s + "'";
        return -1;
    }
    if (safe_addr(local + ":0", ps.local, true) != 0) {
        err = "path local IP parse failed: '" + local + "'";
        return -1;
    }
    if (safe_addr(remote_ip + ":" + port_s, ps.remote, true) != 0) {
        err = "path remote parse failed: '" + remote_ip + ":" + port_s + "'";
        return -1;
    }

    bool have_gw = false;
    for (size_t i = 1; i < t.size(); i += 2) {
        if (i + 1 >= t.size()) { err = "path: '" + t[i] + "' needs a value"; return -1; }
        if (t[i] == "via") {
            if (t[i + 1].size() >= sizeof(ps.ifname)) { err = "path: interface name too long"; return -1; }
            strcpy(ps.ifname, t[i + 1].c_str());
        } else if (t[i] == "gw") {
            struct in_addr g;
            if (parse_ip4(t[i + 1], &g) != 0) { err = "path: gw must be an IPv4 address: '" + t[i + 1] + "'"; return -1; }
            ps.gw.from_ip_port_new(AF_INET, &g, 0);
            have_gw = true;
        } else {
            err = "path: unknown word '" + t[i] + "' (expected via / gw)";
            return -1;
        }
    }
    if (have_gw && !ps.ifname[0]) { err = "path: gw needs via <interface>"; return -1; }
    if (ps.ifname[0] && ps.remote.get_type() != AF_INET) { err = "path: via is IPv4 only"; return -1; }
    return 0;
}

int mf_parse_route_spec(const char *spec, route_entry_t &re, std::string &err)
{
    memset(&re, 0, sizeof(re));
    std::vector<std::string> t = split_spec(spec, "--route");
    if (t.size() < 2) { err = "route is \"<key> <ip:port> [via if] [gw ip] [local ip]\""; return -1; }
    if (t[0].size() > sizeof(re.key_str) - 1) { err = "route key longer than 999 characters"; return -1; }
    strcpy(re.key_str, t[0].c_str());
    if (safe_addr(t[1], re.upstream_addr, true) != 0) {
        err = "route upstream address parse failed: '" + t[1] + "'";
        return -1;
    }
    bool have_gw = false;
    for (size_t i = 2; i < t.size(); i += 2) {
        if (i + 1 >= t.size()) { err = "route: '" + t[i] + "' needs a value"; return -1; }
        if (t[i] == "via") {
            if (t[i + 1].size() >= sizeof(re.ifname)) { err = "route: interface name too long"; return -1; }
            strcpy(re.ifname, t[i + 1].c_str());
        } else if (t[i] == "gw") {
            struct in_addr g;
            if (parse_ip4(t[i + 1], &g) != 0) { err = "route: gw must be an IPv4 address: '" + t[i + 1] + "'"; return -1; }
            re.gw.from_ip_port_new(AF_INET, &g, 0);
            have_gw = true;
        } else if (t[i] == "local") {
            if (safe_addr(t[i + 1], re.local, false) != 0) {
                err = "route: local must be a bare IP: '" + t[i + 1] + "'";
                return -1;
            }
        } else {
            err = "route: unknown word '" + t[i] + "' (expected via / gw / local)";
            return -1;
        }
    }
    if (have_gw && !re.ifname[0]) { err = "route: gw needs via <interface>"; return -1; }
    if (re.local.is_vaild() && re.local.get_type() != re.upstream_addr.get_type()) {
        err = "route: local and upstream address families differ";
        return -1;
    }
    return 0;
}

int mf_load_route_file(const char *path, std::vector<route_entry_t> &out, std::string &err)
{
    std::ifstream f(path);
    if (!f) { err = std::string("cannot read route file ") + path + ": " + strerror(errno); return -1; }
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        n++;
        /* '#' starts a comment at the line start or after whitespace */
        for (size_t i = 0; i < line.size(); i++)
            if (line[i] == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) { line.resize(i); break; }
        if (split_ws(line.c_str()).empty()) continue;
        route_entry_t re;
        std::string e;
        if (mf_parse_route_spec(line.c_str(), re, e) != 0) {
            std::ostringstream os;
            os << path << ":" << n << ": " << e;   /* the line itself holds a key — never echo it */
            err = os.str();
            return -1;
        }
        out.push_back(re);
    }
    return 0;
}

/* ─── interfaces ────────────────────────────────────────────────── */

unsigned mf_ifindex(const char *ifname)
{
    return ifname && ifname[0] ? if_nametoindex(ifname) : 0;
}

int mf_if_ipv4(const char *ifname, struct in_addr *out)
{
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return -1;
    int rc = -1;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strcmp(p->ifa_name, ifname)) continue;
        *out = ((struct sockaddr_in *)p->ifa_addr)->sin_addr;
        rc = 0;
        break;
    }
    freeifaddrs(ifa);
    return rc;
}

bool mf_if_onlink(const char *ifname, struct in_addr dst)
{
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return false;
    bool on = false;
    for (struct ifaddrs *p = ifa; p && !on; p = p->ifa_next) {
        if (!p->ifa_addr || !p->ifa_netmask || p->ifa_addr->sa_family != AF_INET || strcmp(p->ifa_name, ifname))
            continue;
        uint32_t a = ((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr;
        uint32_t m = ((struct sockaddr_in *)p->ifa_netmask)->sin_addr.s_addr;
        on = (a & m) == (dst.s_addr & m);
    }
    freeifaddrs(ifa);
    return on;
}

bool mf_local_addr_exists(address_t &a)
{
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return true;   /* cannot tell — do not raise a false alarm */
    bool found = false;
    for (struct ifaddrs *p = ifa; p && !found; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != a.get_type()) continue;
        if (a.get_type() == AF_INET)
            found = ((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr == a.inner.ipv4.sin_addr.s_addr;
        else
            found = !memcmp(&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr, &a.inner.ipv6.sin6_addr,
                            sizeof(a.inner.ipv6.sin6_addr));
    }
    freeifaddrs(ifa);
    if (found) return true;
    /* Addresses can be local without being listed (all of 127/8 on lo, routes
     * of type local). A bind to port 0 is the kernel's own answer. */
    int fd = socket(a.get_type(), SOCK_DGRAM, 0);
    if (fd < 0) return true;
    address_t t = a;
    if (t.get_type() == AF_INET) t.inner.ipv4.sin_port = 0; else t.inner.ipv6.sin6_port = 0;
    found = bind(fd, (struct sockaddr *)&t.inner, t.get_len()) == 0;
    close(fd);
    return found;
}

/* ─── rtnetlink ─────────────────────────────────────────────────── */

struct nl_req {
    struct nlmsghdr nh;
    struct rtmsg    rt;
    char            attrs[256];
};

static void nl_addattr(struct nlmsghdr *n, int type, const void *data, int alen)
{
    int len = RTA_LENGTH(alen);
    struct rtattr *rta = (struct rtattr *)(((char *)n) + NLMSG_ALIGN(n->nlmsg_len));
    rta->rta_type = type;
    rta->rta_len  = len;
    memcpy(RTA_DATA(rta), data, alen);
    n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len);
}

static int nl_open()
{
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0) return -1;
    struct sockaddr_nl sa;
    memset(&sa, 0, sizeof(sa));
    sa.nl_family = AF_NETLINK;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    struct timeval tv = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return fd;
}

static void nl_init(nl_req &r, int type, int flags)
{
    memset(&r, 0, sizeof(r));
    r.nh.nlmsg_len   = NLMSG_LENGTH(sizeof(struct rtmsg));
    r.nh.nlmsg_type  = type;
    r.nh.nlmsg_flags = NLM_F_REQUEST | flags;
    r.nh.nlmsg_seq   = 1;
    r.rt.rtm_family  = AF_INET;
}

/* Parse one RTM_NEWROUTE into an mf_route_info. Returns rtm or NULL. */
static struct rtmsg *nl_parse_route(struct nlmsghdr *h, mf_route_info &ri, unsigned *table,
                                    unsigned *prio, bool *has_dst, struct in_addr *dst)
{
    memset(&ri, 0, sizeof(ri));
    struct rtmsg *rtm = (struct rtmsg *)NLMSG_DATA(h);
    int len = h->nlmsg_len - NLMSG_LENGTH(sizeof(*rtm));
    if (len < 0) return NULL;
    *table = rtm->rtm_table;
    *prio = 0;
    *has_dst = false;
    for (struct rtattr *a = RTM_RTA(rtm); RTA_OK(a, len); a = RTA_NEXT(a, len)) {
        switch (a->rta_type) {
        case RTA_OIF:      ri.oif = *(unsigned *)RTA_DATA(a); break;
        case RTA_GATEWAY:  if (RTA_PAYLOAD(a) == 4) { ri.has_gw = true; memcpy(&ri.gw, RTA_DATA(a), 4); } break;
        case RTA_PREFSRC:  if (RTA_PAYLOAD(a) == 4) { ri.has_src = true; memcpy(&ri.src, RTA_DATA(a), 4); } break;
        case RTA_TABLE:    *table = *(unsigned *)RTA_DATA(a); break;
        case RTA_PRIORITY: *prio = *(unsigned *)RTA_DATA(a); break;
        case RTA_DST:      if (RTA_PAYLOAD(a) == 4) { *has_dst = true; memcpy(dst, RTA_DATA(a), 4); } break;
        }
    }
    ri.found = true;
    if (ri.oif) if_indextoname(ri.oif, ri.dev);
    return rtm;
}

int mf_route_get(struct in_addr dst, const struct in_addr *src, unsigned oif, mf_route_info &out)
{
    memset(&out, 0, sizeof(out));
    int fd = nl_open();
    if (fd < 0) return -1;
    nl_req r;
    nl_init(r, RTM_GETROUTE, 0);
    r.rt.rtm_dst_len = 32;
    nl_addattr(&r.nh, RTA_DST, &dst, 4);
    if (src) { r.rt.rtm_src_len = 32; nl_addattr(&r.nh, RTA_SRC, src, 4); }
    if (oif) nl_addattr(&r.nh, RTA_OIF, &oif, 4);

    int rc = -1;
    if (send(fd, &r, r.nh.nlmsg_len, 0) >= 0) {
        char buf[8192];
        int n = recv(fd, buf, sizeof(buf), 0);
        struct nlmsghdr *h = (struct nlmsghdr *)buf;
        if (n > 0 && NLMSG_OK(h, (unsigned)n)) {
            if (h->nlmsg_type == NLMSG_ERROR) {
                errno = -((struct nlmsgerr *)NLMSG_DATA(h))->error;
            } else if (h->nlmsg_type == RTM_NEWROUTE) {
                unsigned table, prio; bool hd; struct in_addr d;
                if (nl_parse_route(h, out, &table, &prio, &hd, &d)) rc = 0;
            }
        }
    }
    close(fd);
    return rc;
}

/* Dump the IPv4 main table, calling fn(rtm, info, prio, has_dst, dst) per unicast route. */
template <typename F>
static int nl_dump_main(F fn)
{
    int fd = nl_open();
    if (fd < 0) return -1;
    nl_req r;
    nl_init(r, RTM_GETROUTE, NLM_F_DUMP);
    if (send(fd, &r, r.nh.nlmsg_len, 0) < 0) { close(fd); return -1; }
    static char buf[65536];
    bool done = false;
    int rc = 0;
    while (!done) {
        int n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) { rc = -1; break; }
        for (struct nlmsghdr *h = (struct nlmsghdr *)buf; NLMSG_OK(h, (unsigned)n); h = NLMSG_NEXT(h, n)) {
            if (h->nlmsg_type == NLMSG_DONE) { done = true; break; }
            if (h->nlmsg_type == NLMSG_ERROR) { rc = -1; done = true; break; }
            if (h->nlmsg_type != RTM_NEWROUTE) continue;
            mf_route_info ri;
            unsigned table, prio; bool has_dst; struct in_addr dst; dst.s_addr = 0;
            struct rtmsg *rtm = nl_parse_route(h, ri, &table, &prio, &has_dst, &dst);
            if (!rtm || table != RT_TABLE_MAIN || rtm->rtm_type != RTN_UNICAST) continue;
            fn(rtm, ri, prio, has_dst, dst);
        }
    }
    close(fd);
    return rc;
}

int mf_route_default_gw(unsigned oif, struct in_addr *gw)
{
    bool found = false;
    unsigned best = ~0u;
    nl_dump_main([&](struct rtmsg *rtm, mf_route_info &ri, unsigned prio, bool, struct in_addr) {
        if (rtm->rtm_dst_len != 0 || ri.oif != oif || !ri.has_gw) return;
        if (!found || prio < best) { *gw = ri.gw; best = prio; found = true; }
    });
    return found ? 0 : -1;
}

int mf_default_route_ifaces()
{
    std::set<unsigned> oifs;
    nl_dump_main([&](struct rtmsg *rtm, mf_route_info &ri, unsigned, bool, struct in_addr) {
        if (rtm->rtm_dst_len == 0 && ri.oif) oifs.insert(ri.oif);
    });
    return (int)oifs.size();
}

int mf_route_exact(struct in_addr want, mf_route_info &out)
{
    memset(&out, 0, sizeof(out));
    return nl_dump_main([&](struct rtmsg *rtm, mf_route_info &ri, unsigned, bool has_dst, struct in_addr dst) {
        if (out.found || rtm->rtm_dst_len != 32 || !has_dst || dst.s_addr != want.s_addr) return;
        out = ri;
    });
}

static int nl_route_change(int type, int flags, struct in_addr dst, struct in_addr gw, unsigned oif)
{
    int fd = nl_open();
    if (fd < 0) return -1;
    nl_req r;
    nl_init(r, type, flags | NLM_F_ACK);
    r.rt.rtm_dst_len  = 32;
    r.rt.rtm_table    = RT_TABLE_MAIN;
    r.rt.rtm_protocol = RTPROT_STATIC;
    r.rt.rtm_scope    = RT_SCOPE_UNIVERSE;
    r.rt.rtm_type     = RTN_UNICAST;
    nl_addattr(&r.nh, RTA_DST, &dst, 4);
    if (gw.s_addr) nl_addattr(&r.nh, RTA_GATEWAY, &gw, 4);
    nl_addattr(&r.nh, RTA_OIF, &oif, 4);
    int rc = -1;
    if (send(fd, &r, r.nh.nlmsg_len, 0) >= 0) {
        char buf[4096];
        int n = recv(fd, buf, sizeof(buf), 0);
        struct nlmsghdr *h = (struct nlmsghdr *)buf;
        if (n > 0 && NLMSG_OK(h, (unsigned)n) && h->nlmsg_type == NLMSG_ERROR) {
            int e = -((struct nlmsgerr *)NLMSG_DATA(h))->error;
            if (e == 0) rc = 0; else errno = e;
        }
    }
    close(fd);
    return rc;
}

int mf_route_replace(struct in_addr dst, struct in_addr gw, unsigned oif)
{
    /* replace, not add: add fails with EEXIST when the route is already there,
     * and re-applying on every start is the normal path (2026-10-18, r). */
    return nl_route_change(RTM_NEWROUTE, NLM_F_CREATE | NLM_F_REPLACE, dst, gw, oif);
}

int mf_route_delete(struct in_addr dst, struct in_addr gw, unsigned oif)
{
    int rc = nl_route_change(RTM_DELROUTE, 0, dst, gw, oif);
    if (rc != 0 && errno == ESRCH) rc = 0;
    return rc;
}

/* ─── --apply-routes / --remove-routes ──────────────────────────── */

static bool want_add(std::vector<mf_want_route> &out, const mf_want_route &w, std::string &err)
{
    for (const mf_want_route &o : out) {
        if (o.dst.s_addr != w.dst.s_addr) continue;
        if (o.gw.s_addr == w.gw.s_addr && o.oif == w.oif) return true;   /* duplicate */
        err = "destination " + mf_ip4_str(w.dst) + " needs a /32 out of both " + o.ifname + " and " + w.ifname +
              " — one /32 can point one way only. Give one of the interfaces a default route "
              "(metric higher than the primary) so `via` alone selects it";
        return false;
    }
    out.push_back(w);
    return true;
}

/* One via-pinned destination: does the kernel already reach dst out of that
 * interface with a gateway (or on-link)? Only otherwise is a /32 needed —
 * with no route out of the interface the kernel treats dst as on-link and the
 * packets never leave (2026-10-18, r: `ip route get … oif ens19` → no via). */
static int collect_one(const char *ifname, address_t &remote, address_t &gw_cfg,
                       std::vector<mf_want_route> &out, std::string &err)
{
    unsigned oif = mf_ifindex(ifname);
    if (!oif) { err = std::string("interface ") + ifname + " does not exist"; return -1; }
    struct in_addr dst = remote.inner.ipv4.sin_addr;
    if (mf_if_onlink(ifname, dst)) return 0;

    mf_want_route w;
    memset(&w, 0, sizeof(w));
    w.dst = dst;
    w.oif = oif;
    strncpy(w.ifname, ifname, sizeof(w.ifname) - 1);

    if (gw_cfg.is_vaild()) {
        w.gw = gw_cfg.inner.ipv4.sin_addr;
    } else {
        mf_route_info ri;
        if (mf_route_get(dst, NULL, oif, ri) == 0 && ri.oif == oif && ri.has_gw) return 0;
        if (mf_route_default_gw(oif, &w.gw) != 0) {
            err = std::string("no gateway known for ") + ifname + " to reach " + mf_ip4_str(dst) +
                  " — add \"gw <ip>\" or give " + ifname + " a default route";
            return -1;
        }
    }
    return want_add(out, w, err) ? 0 : -1;
}

int mf_collect_routes(const std::vector<PathSpec> &paths, const std::vector<route_entry_t> &routes,
                      std::vector<mf_want_route> &out, std::string &err)
{
    for (const PathSpec &p : paths) {
        if (!p.ifname[0]) continue;
        PathSpec c = p;
        if (collect_one(c.ifname, c.remote, c.gw, out, err) != 0) return -1;
    }
    for (const route_entry_t &r : routes) {
        if (!r.ifname[0]) continue;
        address_t up = r.upstream_addr, gw = r.gw;
        if (up.get_type() != AF_INET) { err = "via is IPv4 only"; return -1; }
        if (collect_one(r.ifname, up, gw, out, err) != 0) return -1;
    }
    return 0;
}

static std::string state_path(const char *instance)
{
    return std::string(MF_RUN_DIR) + "/" + instance + ".routes";
}

static std::vector<mf_want_route> state_read(const std::string &path)
{
    std::vector<mf_want_route> v;
    std::ifstream f(path);
    std::string dst, gw, ifname;
    unsigned oif;
    while (f >> dst >> gw >> oif >> ifname) {
        mf_want_route w;
        memset(&w, 0, sizeof(w));
        if (parse_ip4(dst, &w.dst) || parse_ip4(gw, &w.gw)) continue;
        w.oif = oif;
        strncpy(w.ifname, ifname.c_str(), sizeof(w.ifname) - 1);
        v.push_back(w);
    }
    return v;
}

static int state_write(const std::string &path, const std::vector<mf_want_route> &v)
{
    mkdir(MF_RUN_DIR, 0755);
    std::string tmp = path + ".tmp";
    FILE *f = fopen(tmp.c_str(), "w");
    if (!f) return -1;
    for (const mf_want_route &w : v)
        fprintf(f, "%s %s %u %s\n", mf_ip4_str(w.dst).c_str(), mf_ip4_str(w.gw).c_str(), w.oif, w.ifname);
    fclose(f);
    return rename(tmp.c_str(), path.c_str());
}

/* dst recorded by any OTHER instance's state file */
static bool recorded_elsewhere(const char *instance, struct in_addr dst)
{
    DIR *d = opendir(MF_RUN_DIR);
    if (!d) return false;
    std::string self = std::string(instance) + ".routes";
    bool hit = false;
    while (struct dirent *e = readdir(d)) {
        std::string n = e->d_name;
        if (n == self || n.size() < 8 || n.compare(n.size() - 7, 7, ".routes")) continue;
        for (const mf_want_route &w : state_read(std::string(MF_RUN_DIR) + "/" + n))
            if (w.dst.s_addr == dst.s_addr) hit = true;
    }
    closedir(d);
    return hit;
}

static bool same_route(const mf_route_info &ri, const mf_want_route &w)
{
    return ri.oif == w.oif && ri.has_gw == (w.gw.s_addr != 0) && (!ri.has_gw || ri.gw.s_addr == w.gw.s_addr);
}

int mf_apply_routes(const char *instance, const std::vector<mf_want_route> &want)
{
    std::string sp = state_path(instance);
    std::vector<mf_want_route> prev = state_read(sp), rec;
    int rc = 0;

    for (const mf_want_route &w : want) {
        bool mine = false;
        for (const mf_want_route &p : prev) if (p.dst.s_addr == w.dst.s_addr) mine = true;

        mf_route_info ex;
        mf_route_exact(w.dst, ex);
        if (ex.found && same_route(ex, w)) {
            /* already right. Record it when a multi-fec instance put it there (this
             * one or another sharing it) so --remove-routes on either keeps it while
             * the other still needs it; an identical route from netplan stays
             * unrecorded so no --remove-routes ever deletes it. */
            if (mine || recorded_elsewhere(instance, w.dst)) rec.push_back(w);
            mylog(log_info, "route %s/32 via %s dev %s: already present\n",
                  mf_ip4_str(w.dst).c_str(), mf_ip4_str(w.gw).c_str(), w.ifname);
            continue;
        }
        if (ex.found && !mine && !recorded_elsewhere(instance, w.dst)) {
            /* replace would silently overwrite it (2026-10-18, r) */
            mylog(log_error, "route %s/32 already exists (%s%s dev %s) and was not installed by multi-fec — "
                  "not overwriting; remove it or fix the OS network config to match\n",
                  mf_ip4_str(w.dst).c_str(), ex.has_gw ? "via " : "",
                  ex.has_gw ? mf_ip4_str(ex.gw).c_str() : "", ex.dev);
            rc = 1;
            continue;
        }
        if (mf_route_replace(w.dst, w.gw, w.oif) != 0) {
            mylog(log_error, "route %s/32 via %s dev %s: %s\n", mf_ip4_str(w.dst).c_str(),
                  mf_ip4_str(w.gw).c_str(), w.ifname, strerror(errno));
            rc = 1;
            continue;
        }
        rec.push_back(w);
        mylog(log_info, "route %s/32 via %s dev %s: installed\n",
              mf_ip4_str(w.dst).c_str(), mf_ip4_str(w.gw).c_str(), w.ifname);
    }

    /* routes this instance put in before that the config no longer wants */
    for (const mf_want_route &p : prev) {
        bool still = false;
        for (const mf_want_route &w : rec) if (w.dst.s_addr == p.dst.s_addr) still = true;
        if (still) continue;
        if (recorded_elsewhere(instance, p.dst)) continue;
        mf_route_info ex;
        mf_route_exact(p.dst, ex);
        if (ex.found && same_route(ex, p) && mf_route_delete(p.dst, p.gw, p.oif) == 0)
            mylog(log_info, "route %s/32 dev %s: removed (no longer configured)\n",
                  mf_ip4_str(p.dst).c_str(), p.ifname);
    }

    if (rec.empty()) unlink(sp.c_str());
    else if (state_write(sp, rec) != 0) {
        mylog(log_error, "cannot write %s: %s\n", sp.c_str(), strerror(errno));
        rc = 1;
    }
    return rc;
}

int mf_remove_routes(const char *instance)
{
    std::string sp = state_path(instance);
    int rc = 0;
    for (const mf_want_route &p : state_read(sp)) {
        if (recorded_elsewhere(instance, p.dst)) {
            mylog(log_info, "route %s/32: kept (another instance uses it)\n", mf_ip4_str(p.dst).c_str());
            continue;
        }
        mf_route_info ex;
        mf_route_exact(p.dst, ex);
        if (!ex.found || !same_route(ex, p)) continue;
        if (mf_route_delete(p.dst, p.gw, p.oif) == 0)
            mylog(log_info, "route %s/32 dev %s: removed\n", mf_ip4_str(p.dst).c_str(), p.ifname);
        else {
            mylog(log_error, "route %s/32: %s\n", mf_ip4_str(p.dst).c_str(), strerror(errno));
            rc = 1;
        }
    }
    unlink(sp.c_str());
    return rc;
}

/* ─── UDP port owners ───────────────────────────────────────────── */

static void scan_proc_udp(const char *file, int family, address_t &addr, std::set<unsigned long> &inodes)
{
    std::ifstream f(file);
    std::string line;
    std::getline(f, line);   /* header */
    unsigned port = ntohs(addr.get_type() == AF_INET ? addr.inner.ipv4.sin_port : addr.inner.ipv6.sin6_port);
    while (std::getline(f, line)) {
        char local[64];
        unsigned long inode = 0;
        /* sl local rem st tx:rx tr:when retr uid timeout inode */
        if (sscanf(line.c_str(), "%*s %63s %*s %*s %*s %*s %*s %*s %*s %lu", local, &inode) != 2) continue;
        char *c = strchr(local, ':');
        if (!c) continue;
        if ((unsigned)strtoul(c + 1, NULL, 16) != port) continue;
        *c = 0;
        bool wild = strspn(local, "0") == strlen(local);
        bool same = false;
        if (family == AF_INET && addr.get_type() == AF_INET) {
            same = (uint32_t)strtoul(local, NULL, 16) == addr.inner.ipv4.sin_addr.s_addr;
            if (addr.inner.ipv4.sin_addr.s_addr == 0) same = true;
        } else if (family == AF_INET6) {
            same = addr.get_type() == AF_INET6 &&
                   IN6_IS_ADDR_UNSPECIFIED(&addr.inner.ipv6.sin6_addr);
        }
        if (wild || same) inodes.insert(inode);
    }
}

int mf_udp_port_owners(address_t &addr, std::vector<mf_port_owner> &out)
{
    std::set<unsigned long> inodes;
    scan_proc_udp("/proc/net/udp", AF_INET, addr, inodes);
    scan_proc_udp("/proc/net/udp6", AF_INET6, addr, inodes);
    if (inodes.empty()) return 0;

    std::set<unsigned long> seen;
    DIR *d = opendir("/proc");
    if (d) {
        while (struct dirent *e = readdir(d)) {
            int pid = atoi(e->d_name);
            if (pid <= 0) continue;
            std::string fdd = std::string("/proc/") + e->d_name + "/fd";
            DIR *fd = opendir(fdd.c_str());
            if (!fd) continue;
            bool hit = false;
            while (struct dirent *f = readdir(fd)) {
                char link[64] = {0};
                std::string p = fdd + "/" + f->d_name;
                if (readlink(p.c_str(), link, sizeof(link) - 1) <= 0) continue;
                unsigned long ino;
                if (sscanf(link, "socket:[%lu]", &ino) == 1 && inodes.count(ino)) { seen.insert(ino); hit = true; }
            }
            closedir(fd);
            if (!hit) continue;
            mf_port_owner o;
            o.pid = pid;
            std::ifstream cf(std::string("/proc/") + e->d_name + "/cmdline");
            std::getline(cf, o.cmdline, '\x01');
            for (char &ch : o.cmdline) if (ch == '\0') ch = ' ';
            out.push_back(o);
        }
        closedir(d);
    }
    if (seen.size() < inodes.size()) {   /* sockets whose owner we cannot see */
        mf_port_owner o;
        o.pid = 0;
        o.cmdline = "(owner not visible — run as root)";
        out.push_back(o);
    }
    return 0;
}
