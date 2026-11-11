#include <common.h>
#include <log.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdio_ext.h>
#include <sys/socket.h>
#include <sys/stat.h>

int log_level = log_info;

int enable_log_position = 0;
int enable_log_color = 1;

/* ─── Non-blocking log output (v1.4.3, 2026-11-11) ───────────────
 *
 * Logs used printf + fflush(stdout): a blocking write on the thread that also
 * runs the event loop. Under systemd stdout is a stream socket to journald;
 * when journald stalls (disk I/O freeze, rate limiting, restart) the socket
 * buffer fills and the write blocks — and with it every forward, probe and
 * timer. Measured 2026-11-09: a relay whose stdout pipe nobody read stopped
 * forwarding after 1,500 probe log lines (round trips 50/50 → 0/50), and on a
 * KVM host with I/O stalls the same thing produced 10-second outages.
 *
 * Now each line is formatted into one buffer and written without blocking:
 *   socket          → send(MSG_DONTWAIT)  (per call, the fd's flags untouched)
 *   pipe / tty      → a private O_NONBLOCK description opened via /proc/self/fd/1
 *                     (setting O_NONBLOCK on fd 1 itself would also change it
 *                      for the shell or whoever shares that description)
 *   regular file    → plain write (page cache; non-blocking has no effect there)
 * A line that cannot be written is dropped and counted; the next line that gets
 * through is preceded by "[log] N line(s) dropped". Logging never blocks the
 * loop, at the price of losing lines while the reader is stuck. */

static int                log_fd          = -1;
static int                log_is_sock     = 0;
static unsigned long long log_dropped     = 0;
static int                log_broken_line = 0;  /* a partial line is on the wire */

static void log_init_fd()
{
    if (log_fd != -1) return;
    log_fd = STDOUT_FILENO;
    struct stat st;
    if (fstat(STDOUT_FILENO, &st) != 0) return;
    if (S_ISSOCK(st.st_mode)) {
        log_is_sock = 1;
    } else if (S_ISFIFO(st.st_mode) || S_ISCHR(st.st_mode)) {
        int fd = open("/proc/self/fd/1", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd >= 0) log_fd = fd;
    }
}

static ssize_t log_try_write(const char *p, size_t n)
{
    for (;;) {
        ssize_t w = log_is_sock ? send(log_fd, p, n, MSG_DONTWAIT | MSG_NOSIGNAL)
                                : write(log_fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        return w;
    }
}

/* returns 1 when the whole buffer went out */
static int log_write_all(const char *p, size_t n)
{
    size_t off = 0;
    while (off < n) {
        ssize_t w = log_try_write(p + off, n - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
    if (off > 0 && off < n) log_broken_line = 1;
    return off == n;
}

static void log_emit(const char *buf, size_t len)
{
    log_init_fd();
    /* keep order with output written through stdio (help, --check, debug dumps) */
    if (__fpending(stdout)) fflush(stdout);

    if (log_dropped || log_broken_line) {
        char note[128];
        int m = snprintf(note, sizeof note, "%s[log] %llu line(s) dropped: log output blocked\n",
                         log_broken_line ? "\n" : "", log_dropped);
        int had_broken = log_broken_line;
        log_broken_line = 0;
        if (!log_write_all(note, (size_t)m)) {
            log_broken_line |= had_broken;
            log_dropped++;
            return;
        }
        log_dropped = 0;
    }
    if (!log_write_all(buf, len)) log_dropped++;
}

#define LOG_LINE_MAX 4096

static size_t log_vappend(char *buf, size_t pos, const char *fmt, va_list ap)
{
    if (pos >= LOG_LINE_MAX - 1) return pos;
    int n = vsnprintf(buf + pos, LOG_LINE_MAX - pos, fmt, ap);
    if (n < 0) return pos;
    pos += (size_t)n;
    return pos < LOG_LINE_MAX - 1 ? pos : LOG_LINE_MAX - 1;
}

static size_t log_append(char *buf, size_t pos, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    pos = log_vappend(buf, pos, fmt, ap);
    va_end(ap);
    return pos;
}

void log0(const char* file, const char* function, int line, int level, const char* str, ...) {
    if (level > log_level) return;
    if (level > log_trace || level < 0) return;
    int saved_errno = errno;

    char out[LOG_LINE_MAX];
    size_t pos = 0;

    time_t timer;
    char buffer[100];
    struct tm* tm_info;

    time(&timer);
    tm_info = localtime(&timer);

    if (enable_log_color)
        pos = log_append(out, pos, "%s", log_color[level]);

    strftime(buffer, 100, "%Y-%m-%d %H:%M:%S", tm_info);
    pos = log_append(out, pos, "[%s][%s]", buffer, log_text[level]);

    if (enable_log_position) pos = log_append(out, pos, "[%s,func:%s,line:%d]", file, function, line);

    va_list vlist;
    va_start(vlist, str);
    pos = log_vappend(out, pos, str, vlist);
    va_end(vlist);
    if (enable_log_color)
        pos = log_append(out, pos, "%s", RESET);

    log_emit(out, pos);

    if (log_level == log_fatal) {
        about_to_exit = 1;
    }
    errno = saved_errno;
}

void log_bare(int level, const char* str, ...) {
    if (level > log_level) return;
    if (level > log_trace || level < 0) return;
    int saved_errno = errno;

    char out[LOG_LINE_MAX];
    size_t pos = 0;
    if (enable_log_color)
        pos = log_append(out, pos, "%s", log_color[level]);
    va_list vlist;
    va_start(vlist, str);
    pos = log_vappend(out, pos, str, vlist);
    va_end(vlist);
    if (enable_log_color)
        pos = log_append(out, pos, "%s", RESET);

    log_emit(out, pos);
    errno = saved_errno;
}
