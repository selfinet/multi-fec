/*
 * mf_logfp.h — client-IP log fingerprinting.
 *
 * Relay traffic logs identify clients by a one-way fingerprint ("cf:xxxxxxxx")
 * instead of a raw IP, so logs shipped off the host (central collection,
 * backups, support tickets) do not carry client addresses. The fingerprint is
 * keyed by a fixed per-deployment salt held in a 0600 file, so an operator who
 * holds the salt can map a known IP list forward to fingerprints
 * (`multi-fec --fingerprint-ip <ip>`); nobody without the salt can.
 */
#ifndef MF_LOGFP_H
#define MF_LOGFP_H

#include "common.h"   /* address_t */

#define MF_LOG_SALT_PATH "/etc/multi-fec/log-salt"
#define MF_LOG_FP_LEN    12   /* "cf:" + 8 hex + NUL */

/* Load the salt from MF_LOG_SALT_PATH (overridable by env MF_LOG_SALT_FILE),
 * creating it (0600, 16 random bytes) if absent. Returns 0 on success. On
 * failure it falls back to a process-random salt so logging still works (the
 * fingerprints are then not mappable across restarts) and returns -1. */
int mf_log_salt_init(void);

/* Fingerprint an address by its IP only (port ignored, matching the probe
 * limiter's per-IP policy) → "cf:xxxxxxxx". out must hold MF_LOG_FP_LEN. */
void mf_client_fp(address_t &a, char *out, size_t out_len);

#endif /* MF_LOGFP_H */
