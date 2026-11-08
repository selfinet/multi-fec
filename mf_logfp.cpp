/*
 * mf_logfp.cpp — client-IP log fingerprinting. See mf_logfp.h.
 */
#include "mf_logfp.h"
#include "siphash.h"
#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <netinet/in.h>

static uint8_t g_salt[16];
static int     g_salt_ready = 0;

static const char *salt_path(void)
{
    const char *p = getenv("MF_LOG_SALT_FILE");
    return (p && *p) ? p : MF_LOG_SALT_PATH;
}

static int read_salt(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, g_salt, sizeof(g_salt));
    close(fd);
    return (n == (ssize_t)sizeof(g_salt)) ? 0 : -1;
}

static int fill_urandom(uint8_t *buf, size_t len)
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, len);
    close(fd);
    return (n == (ssize_t)len) ? 0 : -1;
}

static int create_salt(const char *path)
{
    uint8_t buf[16];
    if (fill_urandom(buf, sizeof(buf)) != 0) return -1;

    /* O_EXCL: if two instances start together, the loser falls back to reading
     * the winner's file so every process on this host shares one salt. */
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (errno == EEXIST) return read_salt(path);
        return -1;
    }
    ssize_t w = write(fd, buf, sizeof(buf));
    (void)fchmod(fd, 0600);
    close(fd);
    if (w != (ssize_t)sizeof(buf)) return -1;
    memcpy(g_salt, buf, sizeof(g_salt));
    return 0;
}

int mf_log_salt_init(void)
{
    const char *path = salt_path();

    if (read_salt(path) == 0) { g_salt_ready = 1; return 0; }

    if (create_salt(path) == 0) {
        g_salt_ready = 1;
        mylog(log_info, "[log] client fingerprint salt created at %s "
                        "(keep it to map fingerprints back to IPs)\n", path);
        return 0;
    }

    /* Fallback: process-random salt so logging still works. Fingerprints are
     * then only valid within this process lifetime. Warn once. */
    int saved = errno;
    if (fill_urandom(g_salt, sizeof(g_salt)) != 0)
        memset(g_salt, 0, sizeof(g_salt));
    g_salt_ready = 1;
    mylog(log_warn, "[log] cannot read or create salt %s (%s) — using a "
                    "process-random salt; fingerprints will not be mappable. "
                    "Create %s (0600) to fix\n",
          path, strerror(saved), path);
    return -1;
}

void mf_client_fp(address_t &a, char *out, size_t out_len)
{
    uint8_t ip[16] = {0};
    if (a.is_vaild() && a.get_type() == AF_INET6)
        memcpy(ip, &a.inner.ipv6.sin6_addr, 16);
    else
        memcpy(ip, &a.inner.ipv4.sin_addr, 4);   /* IPv4 in the first 4 bytes */

    if (!g_salt_ready) { snprintf(out, out_len, "cf:?"); return; }

    uint64_t h = siphash24(ip, sizeof(ip), g_salt);
    snprintf(out, out_len, "cf:%08x", (uint32_t)(h & 0xffffffffULL));
}
