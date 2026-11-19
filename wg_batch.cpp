/* wg_batch — 설명은 wg_batch.h */
#include "wg_batch.h"
#include "misc.h"
#include "log.h"
#include "fd_manager.h"
#include <sys/socket.h>
#include <errno.h>
#include <string.h>

extern int random_drop;

#define WG_BATCH_CAP 64

struct wg_batch_item {
    int fd;
    struct sockaddr_storage addr;
    socklen_t alen;             /* 0 = 연결된 소켓(send) */
    int len;
    char data[buf_len];
};
static wg_batch_item s_items[WG_BATCH_CAP];
static int s_n = 0;
static unsigned long long s_err = 0;

int wg_batch_flush()
{
    int sent_total = 0;
    struct mmsghdr msgs[WG_BATCH_CAP];
    struct iovec iov[WG_BATCH_CAP];
    int i = 0;
    while (i < s_n) {
        int j = i;
        while (j < s_n && s_items[j].fd == s_items[i].fd) j++;   /* 같은 소켓이 이어지는 구간 */
        int cnt = j - i;
        for (int k = 0; k < cnt; k++) {
            wg_batch_item &it = s_items[i + k];
            iov[k].iov_base = it.data;
            iov[k].iov_len  = (size_t)it.len;
            memset(&msgs[k], 0, sizeof(msgs[k]));
            msgs[k].msg_hdr.msg_iov     = &iov[k];
            msgs[k].msg_hdr.msg_iovlen  = 1;
            msgs[k].msg_hdr.msg_name    = it.alen ? (void *)&it.addr : NULL;
            msgs[k].msg_hdr.msg_namelen = it.alen;
        }
        int off = 0;
        while (off < cnt) {
            int r = sendmmsg(s_items[i].fd, msgs + off, (unsigned)(cnt - off), MSG_DONTWAIT);
            if (r <= 0) {
                /* sendto() 한 번이 실패하면 그 패킷만 잃던 것과 맞춘다 — 실패한 하나를 건너뛰고 계속 */
                s_err++;
                if (s_err == 1 || s_err % 1000 == 0)
                    mylog(log_warn, "[wg_batch] sendmmsg fd=%d: %s (total %llu)\n", s_items[i].fd, strerror(errno), s_err);
                off++;
                continue;
            }
            off += r;
            sent_total += r;
        }
        i = j;
    }
    s_n = 0;
    return sent_total;
}

int wg_batch_send(my_time_t delay, const dest_t &dest, char *data, int len)
{
    if (delay != 0 || random_drop != 0 || dest.cook || len <= 0 || len > buf_len)
        return delay_send(delay, dest, data, len);
    int fd = -1;
    const address_t *addr = NULL;
    switch (dest.type) {
        case type_fd_addr:
            fd = dest.inner.fd_addr.fd; addr = &dest.inner.fd_addr.addr; break;
        case type_fd64:
            if (!fd_manager.exist(dest.inner.fd64)) return -1;
            fd = fd_manager.to_fd(dest.inner.fd64); break;
        case type_fd:
            fd = dest.inner.fd; break;
        default:
            return delay_send(delay, dest, data, len);
    }
    if (s_n == WG_BATCH_CAP) wg_batch_flush();
    wg_batch_item &it = s_items[s_n++];
    it.fd  = fd;
    it.len = len;
    memcpy(it.data, data, (size_t)len);
    if (addr) {
        it.alen = const_cast<address_t *>(addr)->get_len();   /* get_len() 이 const 가 아니다(upstream) */
        memcpy(&it.addr, &addr->inner, it.alen);
    } else {
        it.alen = 0;
    }
    return 0;
}
