#pragma once
/*
 * port_hopper.h — TOTP-based port rotation for mud_lite multipath
 *
 * Server and client both compute the same TOTP port sequence from PSK.
 * Maintains 2 active ports at any time: current slot + previous slot.
 * ev_timer rotates ports every hop_interval/2 seconds (checks for slot change).
 * Uses mud_set_path() to add/remove paths from mud instance.
 */

#include <vector>
#include <stdint.h>

extern "C" {
#include "mud_lite.h"
}
#include "obfs.h"
#include "mf_common.h"
#include "my_ev.h"
#include "log.h"

class PortHopper {
public:
    /*
     * Constructor
     *   mud       — mud instance to manage paths on
     *   obfs      — obfs context (used for TOTP slot/port computation)
     *   paths     — client: PathSpec list (local+remote IPs); server: empty
     *   is_server — if true, bind local to INADDR_ANY:computed_port
     *               if false, add one mud path per PathSpec entry with TOTP port
     */
    PortHopper(struct mud *mud,
               const struct obfs_ctx *obfs,
               const std::vector<PathSpec> &paths,
               bool is_server);

    ~PortHopper();

    /* Start the rotation timer in the given event loop */
    void start(struct ev_loop *loop);

    /* Stop the rotation timer */
    void stop(struct ev_loop *loop);

    /* libev timer callback — calls update_paths() */
    static void timer_cb(struct ev_loop *loop, ev_timer *w, int revents);

private:
    /*
     * Compute ports for current and prev TOTP slots.
     * If the slot has changed since the last call:
     *   1. Remove the oldest path (slot-2)
     *   2. Add a new path for current slot (MUD_UP, pref=1)
     *   Keep the previous slot path as standby (MUD_UP, pref=2).
     */
    void update_paths();

    /* Helper: build a mud_path_conf for a given slot port.
     * ps == NULL is valid only when is_server_ == true. */
    void make_path_conf(struct mud_path_conf *pc,
                        PathSpec *ps,
                        uint16_t port,
                        enum mud_state state,
                        unsigned char pref);

    /* Helper: remove path for a given slot (if it exists) */
    void remove_path_for_slot(uint64_t slot);

    /* Helper: add path for a given slot */
    void add_path_for_slot(uint64_t slot, enum mud_state state, unsigned char pref);

    struct mud            *mud_;
    const struct obfs_ctx *obfs_;
    std::vector<PathSpec>  paths_;    /* client: one entry per --path; server: empty */
    bool                   is_server_;

    ev_timer               timer_;
    uint64_t               current_slot_;   /* slot active during last update */

    /* Track which slots have been added (parallel arrays, ring of 3) */
    static const int SLOT_TRACK = 4;
    uint64_t         slot_active_[SLOT_TRACK];   /* slot numbers */
    bool             slot_present_[SLOT_TRACK];  /* whether path exists */
};
