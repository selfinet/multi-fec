/*
 * mf_config.cpp — v1.4.0 --config FILE. See mf_config.h.
 */
#include "mf_config.h"

#include <ctype.h>
#include <errno.h>
#include <string.h>

#include <fstream>
#include <sstream>

namespace {

enum kind_t { K_VALUE, K_FLAG, K_REPEAT };

struct opt_t {
    const char *name;   /* canonical (= file) name */
    const char *cli;    /* command-line token */
    kind_t      kind;
};

/* Everything the CLI accepts except the actions (--config/--check/--apply-routes/
 * --remove-routes/--version/--help). "mode" and "wg" are handled specially. */
const opt_t k_opts[] = {
    { "listen",            "-l",                  K_VALUE  },
    { "key",               "-k",                  K_VALUE  },
    { "key-file",          "--key-file",          K_VALUE  },
    { "fec",               "-f",                  K_VALUE  },
    { "fec-mode",          "--mode",              K_VALUE  },
    { "path",              "--path",              K_REPEAT },
    { "route",             "--route",             K_REPEAT },
    { "route-file",        "--route-file",        K_VALUE  },
    { "accept-local",      "--accept-local",      K_REPEAT },
    { "upstream",          "--upstream",          K_VALUE  },
    { "upstream-local",    "--upstream-local",    K_VALUE  },
    { "multipath-mode",    "--multipath-mode",    K_VALUE  },
    { "dup-factor",        "--dup-factor",        K_VALUE  },
    { "fec-timeout",       "--fec-timeout",       K_VALUE  },
    { "mtu",               "--mtu",               K_VALUE  },
    { "queue-len",         "--queue-len",         K_VALUE  },
    { "decode-buf",        "--decode-buf",        K_VALUE  },
    { "disable-fec",       "--disable-fec",       K_FLAG   },
    { "sock-buf",          "--sock-buf",          K_VALUE  },
    { "jitter",            "--jitter",            K_VALUE  },
    { "random-drop",       "--random-drop",       K_VALUE  },
    { "disable-checksum",  "--disable-checksum",  K_FLAG   },
    { "fifo",              "--fifo",              K_VALUE  },
    { "report",            "--report",            K_VALUE  },
    { "log-level",         "--log-level",         K_VALUE  },
    { "log-position",      "--log-position",      K_FLAG   },
    { "disable-color",     "--disable-color",     K_FLAG   },
    { "enable-color",      "--enable-color",      K_FLAG   },
    { "obfs-mode",         "--obfs-mode",         K_VALUE  },
    { "decoy",             "--decoy",             K_VALUE  },
    { "disable-obfs",      "--disable-obfs",      K_FLAG   },
    { "port-hop-interval", "--port-hop-interval", K_VALUE  },
    { "auth-interval",     "--auth-interval",     K_VALUE  },
    { "wg",                "--wg",                K_VALUE  },   /* client: becomes listen */
};

const opt_t *find_opt(const std::string &name)
{
    for (const opt_t &o : k_opts)
        if (name == o.name) return &o;
    return NULL;
}

std::string trim(const std::string &s)
{
    size_t a = 0, b = s.size();
    while (a < b && isspace((unsigned char)s[a])) a++;
    while (b > a && isspace((unsigned char)s[b - 1])) b--;
    return s.substr(a, b - a);
}

std::string lineerr(const char *path, int n, const std::string &why)
{
    std::ostringstream os;
    os << path << ":" << n << ": " << why;
    return os.str();
}

}  // namespace

bool mf_config_repeatable(const std::string &name)
{
    const opt_t *o = find_opt(name);
    return o && o->kind == K_REPEAT;
}

int mf_config_load(const char *path, mf_cfg &cfg, std::string &err)
{
    std::ifstream f(path);
    if (!f) { err = std::string("cannot read ") + path + ": " + strerror(errno); return -1; }
    cfg = mf_cfg();
    cfg.path = path;
    {
        std::string b = path;
        size_t sl = b.rfind('/');
        if (sl != std::string::npos) b = b.substr(sl + 1);
        if (b.size() > 5 && b.compare(b.size() - 5, 5, ".conf") == 0) b.resize(b.size() - 5);
        cfg.instance = b;
    }

    std::set<std::string> seen;
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        n++;
        for (size_t i = 0; i < line.size(); i++)
            if (line[i] == '#' && (i == 0 || isspace((unsigned char)line[i - 1]))) { line.resize(i); break; }
        line = trim(line);
        if (line.empty()) continue;

        size_t eq = line.find('=');
        if (eq == std::string::npos) { err = lineerr(path, n, "expected \"name = value\""); return -1; }
        std::string name = trim(line.substr(0, eq)), val = trim(line.substr(eq + 1));
        for (char &c : name) { c = (char)tolower((unsigned char)c); if (c == '_') c = '-'; }
        if (val.size() >= 2 && val[0] == '"' && val[val.size() - 1] == '"') val = val.substr(1, val.size() - 2);
        if (val.empty()) { err = lineerr(path, n, "\"" + name + "\" has no value"); return -1; }

        if (name == "mode") {
            if (val == "client" || val == "server" || val == "relay") {
                if (!cfg.mode.empty()) { err = lineerr(path, n, "\"mode\" is set twice"); return -1; }
                cfg.mode = val;
                continue;
            }
            if (val == "0" || val == "1" || val == "2") {
                err = lineerr(path, n, "\"mode\" is client|server|relay — the FEC mode is \"fec-mode = " + val + "\"");
                return -1;
            }
            err = lineerr(path, n, "\"mode\" must be client, server or relay");
            return -1;
        }

        const opt_t *o = find_opt(name);
        if (!o) {
            /* never echo the line: it may hold a key */
            err = lineerr(path, n, "unknown setting \"" + name + "\" (names are the long command-line options without --)");
            return -1;
        }
        if (o->kind != K_REPEAT) {
            if (seen.count(name)) { err = lineerr(path, n, "\"" + name + "\" is set twice"); return -1; }
            seen.insert(name);
        }
        if (o->kind == K_FLAG) {
            std::string v = val;
            for (char &c : v) c = (char)tolower((unsigned char)c);
            if (v == "yes" || v == "true" || v == "on" || v == "1") val = "yes";
            else if (v == "no" || v == "false" || v == "off" || v == "0") val = "no";
            else { err = lineerr(path, n, "\"" + name + "\" takes yes or no"); return -1; }
        }
        cfg.items.push_back(std::make_pair(name, val));
    }

    /* "wg" means the WireGuard side in both roles: the client's local listen,
     * the server's upstream. Resolve it now so precedence works on one name. */
    bool has_listen = seen.count("listen") > 0, has_wg = seen.count("wg") > 0;
    if (cfg.mode == "client" && has_wg) {
        if (has_listen) { err = std::string(path) + ": client takes \"wg\" or \"listen\", not both (they are the same socket)"; return -1; }
        for (auto &it : cfg.items) if (it.first == "wg") it.first = "listen";
    }
    if (cfg.mode == "relay" && has_wg) { err = std::string(path) + ": \"wg\" is not a relay setting"; return -1; }
    return 0;
}

std::string mf_cli_canonical(const char *token)
{
    if (!token || token[0] != '-' || !token[1]) return "";
    if (token[1] != '-') {
        switch (token[1]) {
        case 'c': case 's': case 'r': return "mode";
        case 'l': return "listen";
        case 'k': return "key";
        case 'f': return "fec";
        case 'q': return "queue-len";
        case 'j': return "jitter";
        default:  return "";
        }
    }
    std::string n = token + 2;
    size_t eq = n.find('=');
    if (eq != std::string::npos) n.resize(eq);
    if (n == "mode") return "fec-mode";
    if (n == "key") return "key";
    return n;
}

void mf_config_to_args(const mf_cfg &cfg, const std::set<std::string> &cli_names,
                       std::vector<std::string> &args)
{
    if (!cfg.mode.empty() && !cli_names.count("mode"))
        args.push_back(cfg.mode == "client" ? "-c" : cfg.mode == "server" ? "-s" : "-r");
    for (const auto &it : cfg.items) {
        if (cli_names.count(it.first)) continue;   /* command line wins (repeatables: replaced whole) */
        const opt_t *o = find_opt(it.first);
        if (!o) continue;
        if (o->kind == K_FLAG) {
            if (it.second == "yes") args.push_back(o->cli);
            continue;
        }
        args.push_back(o->cli);
        args.push_back(it.second);
    }
}
