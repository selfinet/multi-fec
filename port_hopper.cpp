/*
 * port_hopper.cpp — TOTP-based port rotation for mud_lite multipath
 */

#include "port_hopper.h"

#include <string.h>
#include <assert.h>
#include <arpa/inet.h>
#include <netinet/in.h>

/* ────────────────────────────────────────────────────────────────
 * Constructor / Destructor
 * ──────────────────────────────────────────────────────────────── */

PortHopper::PortHopper(struct mud            *mud,
                       const struct obfs_ctx *obfs,
                       const std::vector<PathSpec> &paths,
                       bool                   is_server)
    : mud_(mud)
    , obfs_(obfs)
    , paths_(paths)
    , is_server_(is_server)
    , current_slot_(0)
{
    memset(&timer_, 0, sizeof(timer_));
    for (int i = 0; i < SLOT_TRACK; i++) {
        slot_active_[i]  = (uint64_t)-1;
        slot_present_[i] = false;
    }
}

PortHopper::~PortHopper()
{
    /* timer should have been stopped via stop() before destruction */
}

/* ────────────────────────────────────────────────────────────────
 * start / stop
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::start(struct ev_loop *loop)
{
    /* Check every hop_interval/2 seconds so we catch slot transitions
     * without missing them (Nyquist-ish). Minimum 1 second. */
    double interval = (double)obfs_->hop_interval / 2.0;
    if (interval < 1.0) interval = 1.0;

    timer_.data = this;
    ev_timer_init(&timer_, PortHopper::timer_cb, interval, interval);

    /* Run an immediate update before first timer fire */
    update_paths();

    ev_timer_start(loop, &timer_);
    mylog(log_info, "[port_hopper] started, check interval=%.1fs hop_interval=%u\n",
          interval, obfs_->hop_interval);
}

void PortHopper::stop(struct ev_loop *loop)
{
    ev_timer_stop(loop, &timer_);
    mylog(log_info, "[port_hopper] stopped\n");
}

/* ────────────────────────────────────────────────────────────────
 * timer callback
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::timer_cb(struct ev_loop * /*loop*/, ev_timer *w, int /*revents*/)
{
    PortHopper *self = static_cast<PortHopper *>(w->data);
    self->update_paths();
}

/* ────────────────────────────────────────────────────────────────
 * Helper: build mud_path_conf for a given port
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::make_path_conf(struct mud_path_conf *pc,
                                PathSpec             *ps,
                                uint16_t              port,
                                enum mud_state        state,
                                unsigned char         pref)
{
    memset(pc, 0, sizeof(*pc));
    pc->state = state;
    pc->pref  = pref;

    if (is_server_) {
        /* Server: local = INADDR_ANY:port, remote = zeroed (any) */
        pc->local.sin.sin_family      = AF_INET;
        pc->local.sin.sin_addr.s_addr = htonl(INADDR_ANY);
        pc->local.sin.sin_port        = htons(port);
        pc->remote.sa.sa_family       = AF_UNSPEC;
    } else {
        /* Client: local from PathSpec (port=0 → OS auto-assign),
         *         remote = PathSpec's remote IP with TOTP-computed port. */
        assert(ps != NULL);

        if (ps->local.get_type() == AF_INET) {
            pc->local.sin           = ps->local.inner.ipv4;
            pc->local.sin.sin_port  = 0;
        } else {
            pc->local.sin6              = ps->local.inner.ipv6;
            pc->local.sin6.sin6_port    = 0;
        }

        if (ps->remote.get_type() == AF_INET) {
            pc->remote.sin          = ps->remote.inner.ipv4;
            pc->remote.sin.sin_port = htons(port);
        } else {
            pc->remote.sin6             = ps->remote.inner.ipv6;
            pc->remote.sin6.sin6_port   = htons(port);
        }
    }
}

/* ────────────────────────────────────────────────────────────────
 * Helper: add a path for a slot
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::add_path_for_slot(uint64_t slot, enum mud_state state, unsigned char pref)
{
    uint16_t port = obfs_port_for_slot(obfs_, slot);
    int any_ok = 0;

    if (is_server_) {
        struct mud_path_conf pc;
        make_path_conf(&pc, NULL, port, state, pref);
        if (mud_set_path(mud_, &pc) == 0)
            any_ok = 1;
    } else {
        /* Client: one mud path per PathSpec entry */
        for (size_t i = 0; i < paths_.size(); i++) {
            struct mud_path_conf pc;
            make_path_conf(&pc, &paths_[i], port, state, pref);
            if (mud_set_path(mud_, &pc) == 0)
                any_ok = 1;
            else
                mylog(log_warn,
                      "[port_hopper] mud_set_path add failed slot=%llu port=%u path=%zu\n",
                      (unsigned long long)slot, port, i);
        }
    }

    if (any_ok) {
        mylog(log_info, "[port_hopper] added paths slot=%llu port=%u state=%d pref=%u\n",
              (unsigned long long)slot, port, (int)state, (unsigned)pref);
        for (int i = 0; i < SLOT_TRACK; i++) {
            if (!slot_present_[i]) {
                slot_active_[i]  = slot;
                slot_present_[i] = true;
                break;
            }
        }
    }
}

/* ────────────────────────────────────────────────────────────────
 * Helper: remove a path for a slot
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::remove_path_for_slot(uint64_t slot)
{
    bool found = false;
    for (int i = 0; i < SLOT_TRACK; i++) {
        if (slot_present_[i] && slot_active_[i] == slot) {
            found = true;
            slot_present_[i] = false;
            slot_active_[i]  = (uint64_t)-1;
            break;
        }
    }
    if (!found) return;

    uint16_t port = obfs_port_for_slot(obfs_, slot);

    if (is_server_) {
        struct mud_path_conf pc;
        make_path_conf(&pc, NULL, port, MUD_DOWN, 0);
        int ret = mud_set_path(mud_, &pc);
        if (ret == 0)
            mylog(log_info, "[port_hopper] removed path slot=%llu port=%u\n",
                  (unsigned long long)slot, port);
        else
            mylog(log_debug,
                  "[port_hopper] mud_set_path remove slot=%llu port=%u ret=%d\n",
                  (unsigned long long)slot, port, ret);
    } else {
        for (size_t i = 0; i < paths_.size(); i++) {
            struct mud_path_conf pc;
            make_path_conf(&pc, &paths_[i], port, MUD_DOWN, 0);
            mud_set_path(mud_, &pc);
        }
        mylog(log_info, "[port_hopper] removed paths slot=%llu port=%u\n",
              (unsigned long long)slot, port);
    }
}

/* ────────────────────────────────────────────────────────────────
 * Core: update_paths()
 *
 * We maintain exactly 2 active paths at any time:
 *   current slot: MUD_UP, pref=1  (preferred)
 *   prev    slot: MUD_UP, pref=2  (standby fallback)
 *
 * When the slot advances:
 *   1. Remove the (new_slot - 2) path — it is now 2 slots old.
 *   2. Add new_slot as MUD_UP pref=1.
 *   3. The (new_slot - 1) path is already active — update pref to 2.
 * ──────────────────────────────────────────────────────────────── */

void PortHopper::update_paths()
{
    uint64_t new_slot = obfs_current_slot(obfs_);

    if (new_slot == current_slot_) {
        /* No slot change — nothing to do */
        return;
    }

    mylog(log_info, "[port_hopper] slot change: %llu -> %llu\n",
          (unsigned long long)current_slot_, (unsigned long long)new_slot);

    /* First call: current_slot_ == 0 means not yet initialized */
    bool first_call = (current_slot_ == 0);

    if (first_call) {
        /* Add prev slot as standby */
        if (new_slot > 0) {
            add_path_for_slot(new_slot - 1, MUD_UP, 2);
        }
        /* Add current slot as preferred */
        add_path_for_slot(new_slot, MUD_UP, 1);
    } else {
        /* Remove path that is 2 slots old */
        if (new_slot >= 2) {
            remove_path_for_slot(new_slot - 2);
        }

        /* Demote the previous current slot to pref=2 (it is now new_slot-1) */
        {
            uint64_t prev_slot = new_slot - 1;
            uint16_t prev_port = obfs_port_for_slot(obfs_, prev_slot);
            if (is_server_) {
                struct mud_path_conf pc;
                make_path_conf(&pc, NULL, prev_port, MUD_UP, 2);
                mud_set_path(mud_, &pc);
            } else {
                for (size_t i = 0; i < paths_.size(); i++) {
                    struct mud_path_conf pc;
                    make_path_conf(&pc, &paths_[i], prev_port, MUD_UP, 2);
                    mud_set_path(mud_, &pc);
                }
            }
            mylog(log_debug, "[port_hopper] demoted slot=%llu port=%u to pref=2\n",
                  (unsigned long long)prev_slot, prev_port);
        }

        /* Add new current slot as pref=1 */
        add_path_for_slot(new_slot, MUD_UP, 1);
    }

    current_slot_ = new_slot;
}
