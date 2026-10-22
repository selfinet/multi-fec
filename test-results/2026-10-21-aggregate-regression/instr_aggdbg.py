import sys, re
p = sys.argv[1] + '/mud_lite.c'; s = open(p).read()
# 1) 경로 구조체 대신 정적 배열로 송신 횟수를 센다 (구조체·와이어 무변경)
anchor = 'mud_send_next_peer(struct mud *mud, uint64_t peer, const void *data, size_t size,'
if anchor not in s:
    anchor = 'mud_send_next(struct mud *mud, const void *data, size_t size, unsigned dup_count)'
assert anchor in s, 'anchor'
dbg = r'''
/* ── AGGDBG (계측 빌드 전용, 리포 미반영) ── */
static unsigned long aggdbg_sent[64];
static uint64_t aggdbg_last;
static void aggdbg_dump(struct mud *mud, uint64_t now)
{
    if (now - aggdbg_last < 1000000ULL) return;
    aggdbg_last = now;
    unsigned long tot = 0;
    for (unsigned i = 0; i < mud->capacity && i < 64; i++) tot += aggdbg_sent[i];
    for (unsigned i = 0; i < mud->capacity && i < 64; i++) {
        struct mud_path *pa = &mud->paths[i];
        if (!pa->conf.state) continue;  /* 빈 슬롯 */
        fprintf(stderr, "AGGDBG t=%llu path=%u st=%d rate=%llu txloss=%u rxloss=%u sent=%lu share=%.3f\n",
                (unsigned long long)(now / 1000), i, (int)pa->status, (unsigned long long)pa->tx.rate,
                (unsigned)pa->tx.loss, (unsigned)pa->rx.loss, aggdbg_sent[i], tot ? (double)aggdbg_sent[i] / tot : 0.0);
        aggdbg_sent[i] = 0;
    }
}
'''
s = s.replace('int\n' + anchor, dbg + '\nint\n' + anchor, 1) if ('int\n' + anchor) in s else s.replace(anchor, dbg + '\n' + anchor, 1)
# 2) 송신 직전에 카운트 + 덤프
m = re.search(r'(\n(\s*)if \(mud_send_path\(mud, best, now, packet, pkt_size, 0\) >= 0\)\n)', s)
assert m, 'send site'
ind = m.group(2)
s = s.replace(m.group(1), '\n' + ind + 'aggdbg_sent[(unsigned)(best - mud->paths) & 63]++;\n' + ind + 'aggdbg_dump(mud, now);' + m.group(1), 1)
s = s.replace('#include <net/if.h>\n', '#include <net/if.h>\n#include <stdio.h>\n', 1)
open(p, 'w').write(s)
print('patched', p)
