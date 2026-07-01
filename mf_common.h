#pragma once
/*
 * mf_common.h — multi-fec shared types and global variables
 */
#include "common.h"
#include "obfs.h"
#include <vector>
#include <stdint.h>

/* session_id: 8-byte random identifier the client generates at startup.
 * Prepended to every client->server FEC packet so the server can identify
 * the same client regardless of path (POP). */
#define SESSION_ID_LEN 8
extern uint8_t g_session_id[SESSION_ID_LEN];

/* --path local_ip:remote_ip:port parse result */
struct PathSpec {
    address_t local;   /* local interface IP (port=0 -> OS auto-select) */
    address_t remote;  /* remote IP:port */
};

/*
 * Multipath operating modes
 *   MULTIPATH_FAILOVER           : priority-ordered Active-Standby. Uses only the top path.
 *   MULTIPATH_DUPLICATE          : sends the same packet on all paths. Highest availability.
 *   MULTIPATH_AGGREGATE          : distributes different packets across paths (weighted round-robin).
 *                                  Aggregates total bandwidth. Weight proportional to tx.rate.
 *   MULTIPATH_AGGREGATE_DUPLICATE: aggregate + duplicate. Sends each packet on dup_factor paths.
 *                                  Mix of bandwidth aggregation + path redundancy.
 */
enum multipath_mode_t {
    MULTIPATH_FAILOVER            = 0,
    MULTIPATH_DUPLICATE           = 1,
    MULTIPATH_AGGREGATE           = 2,
    MULTIPATH_AGGREGATE_DUPLICATE = 3,
};

/*
 * Relay per-key upstream routing table entry.
 * Registered via the --route "keystring ip:port" option.
 * If g_routes is empty, operates in the legacy single --upstream mode.
 */
struct route_entry_t {
    char            key_str[1000];
    address_t       upstream_addr;
    struct obfs_ctx obfs;          /* HMAC context initialized from key_str */
};

/* Defined in main.cpp, referenced from other modules via extern */
extern std::vector<PathSpec>      g_paths;          /* client --path list */
extern address_t                  g_wg_addr;        /* server --wg WireGuard upstream address */
extern multipath_mode_t           g_multipath_mode; /* multipath operating mode */
extern unsigned                   g_dup_factor;     /* aggregate-duplicate path duplication count */
extern std::vector<route_entry_t> g_routes;         /* relay per-key upstream routing table */
