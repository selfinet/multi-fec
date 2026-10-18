#pragma once
/*
 * mf_config.h — v1.4.0 --config FILE
 *
 * The file is translated into the equivalent command-line tokens and parsed by
 * the existing getopt code, so ranges, errors and semantics stay identical to
 * the CLI. Rules (DESIGN-1.4.0.md §3):
 *   - "name = value" per line, '#' comments, name = CLI long option without "--"
 *   - mode = client|server|relay ; the FEC mode is "fec-mode" (CLI --mode)
 *   - unknown names, a scalar set twice, or a numeric "mode" refuse to start
 *   - precedence: command line > file > built-in default; a repeatable option
 *     given on the command line replaces the file's lines for that option
 */
#include <set>
#include <string>
#include <utility>
#include <vector>

struct mf_cfg {
    std::string path;       /* as given */
    std::string instance;   /* basename without .conf — names the FIFO and route state */
    std::string mode;       /* client | server | relay | "" */
    std::vector<std::pair<std::string, std::string> > items;   /* canonical name, value; file order */
};

/* Parse and validate. Returns 0, or -1 with err ("file:line: why"). */
int mf_config_load(const char *path, mf_cfg &cfg, std::string &err);

/* Canonical name of a command-line token ("-k" -> "key", "--mode" -> "fec-mode",
 * "--fec-timeout=10" -> "fec-timeout"); "" when not an option. */
std::string mf_cli_canonical(const char *token);

/* Append the file's tokens, skipping names the command line already sets. */
void mf_config_to_args(const mf_cfg &cfg, const std::set<std::string> &cli_names,
                       std::vector<std::string> &args);

/* True when name is a repeatable option (path, route, accept-local). */
bool mf_config_repeatable(const std::string &name);
