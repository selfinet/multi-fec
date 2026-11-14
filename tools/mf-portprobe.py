#!/usr/bin/env python3
"""mf-portprobe — 출발 포트별 UDP 왕복 지연 측정 (multi-fec relay·server 대상, 설치 불필요·표준 라이브러리만)

왜: 통신사 ECMP 는 UDP 5-tuple 로 갈래를 정한다. relay 의 upstream 출발 포트는 커널이 임의로 고르므로
재시작할 때마다 갈래가 다시 뽑힌다(2026-10-24 ch3→kt 44 / 63 ms 두 갈래). 어느 출발 포트가 빠른 갈래를
타는지 재서, 고정할 포트를 고르는 데 쓴다.

어떻게: 출발 포트마다 UDP 소켓을 bind 해 대상(다음 홉 relay 또는 server 의 ip:443)으로 인증되지 않은
1200 B 패킷을 보낸다. multi-fec relay·server 는 인증 실패 패킷에 같은 소켓으로 QUIC Server Initial 을
응답하므로(mf_probe.cpp probe_reply) 실제 데이터와 같은 5-tuple 로 왕복 지연을 잴 수 있다.
ICMP 를 쓰지 않으므로 라우터의 ICMP 후순위·속도 제한 영향을 받지 않고, 오는 방향 갈래도 포함된다.
대상에 경로·세션이 생기지 않는다(서버 mud 경로 슬롯을 쓰지 않음).

제약 (대상 쪽 코드):
  - 요청 1200 B 이상이어야 응답한다(QUIC_INITIAL_SIZE).
  - v1.4.2+ 대상은 소스 IP 당 초당 2회(버스트 5)만 응답한다(PROBE_SRC_RATE) — 포트를 바꿔도 IP 가 같으면
    같은 버킷이다. 그래서 기본 간격이 0.55 초이고, 더 빠르게 보내면 응답이 빠져 손실로 보인다.
  - 대상에 --decoy 가 있으면 응답은 decoy(nginx 등)가 만든다. 왕복은 재지지만 decoy 세션이 생긴다.
  - 대상 로그에 60초마다 "[probe] last period: replied N" 한 줄이 남는다.

주의: 실제 relay 와 같은 조건에서 재야 같은 갈래를 탄다 — relay route 의 local(소스 IP)을 --local 로 주고,
같은 호스트에서 실행한다. 쓰는 포트는 multi-fec 이 쓰지 않는 범위(기본 20000번대, 커널 임의 포트 범위 밖).
이미 쓰이는 포트는 건너뛴다(SO_REUSEADDR 를 쓰지 않는다 — 살아 있는 소켓과 섞이지 않게).

예:
  ./mf-portprobe.py 121.126.223.135:443 --local 1.2.3.4 --ports 20000-20029 --samples 8
  ./mf-portprobe.py 121.126.223.135:443 --ports 20101,20117 --samples 20 --json out.json
"""
import argparse
import errno
import json
import os
import select
import socket
import sys
import time

PAYLOAD_SIZE = 1200          # QUIC_INITIAL_SIZE — 이보다 작으면 대상이 응답하지 않는다
DEFAULT_INTERVAL = 0.55      # PROBE_SRC_RATE 2/s 보다 약간 느리게


def parse_hostport(s):
    if s.startswith('['):                       # [v6]:port
        host, _, rest = s[1:].partition(']')
        return host, int(rest.lstrip(':'))
    host, sep, port = s.rpartition(':')
    if not sep:
        raise argparse.ArgumentTypeError('ip:port 형식이어야 합니다: %r' % s)
    return host, int(port)


def parse_ports(spec):
    out = []
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            a, b = part.split('-', 1)
            a, b = int(a), int(b)
            if a > b:
                a, b = b, a
            out.extend(range(a, b + 1))
        else:
            out.append(int(part))
    bad = [p for p in out if not 1 <= p <= 65535]
    if bad:
        raise argparse.ArgumentTypeError('포트 범위 밖: %s' % bad[:5])
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def make_payload():
    # 첫 바이트 0x40-0x7F = QUIC short header 처럼 보이게. 나머지는 난수라 HMAC 검증에 실패한다
    # (8 B 토큰이 우연히 맞을 확률 2^-64).
    b = bytearray(os.urandom(PAYLOAD_SIZE))
    b[0] = 0x40 | (b[0] & 0x3F)
    return bytes(b)


def ephemeral_range():
    try:
        with open('/proc/sys/net/ipv4/ip_local_port_range') as f:
            lo, hi = f.read().split()
            return int(lo), int(hi)
    except (OSError, ValueError):
        return None


def percentile(sorted_vals, q):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * q
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def open_sockets(target, local, ports):
    family = socket.AF_INET6 if ':' in target[0] else socket.AF_INET
    socks, skipped = {}, {}
    for p in ports:
        s = socket.socket(family, socket.SOCK_DGRAM)
        try:
            s.bind((local or ('::' if family == socket.AF_INET6 else '0.0.0.0'), p))
            s.connect(target)
            s.setblocking(False)
        except OSError as e:
            skipped[p] = errno.errorcode.get(e.errno, str(e))
            s.close()
            continue
        socks[p] = s
    return socks, skipped


def drain(s):
    n = 0
    while True:
        try:
            s.recv(65535)
            n += 1
        except (BlockingIOError, InterruptedError):
            return n
        except ConnectionRefusedError:      # 이전 ICMP port unreachable
            n += 1


def measure(socks, samples, interval, timeout, progress):
    res = {p: {'sent': 0, 'recv': 0, 'late': 0, 'refused': 0, 'rtt': []} for p in socks}
    order = list(socks)
    total = len(order) * samples
    done = 0
    next_send = time.monotonic()
    for rnd in range(samples):
        for p in order:
            s = socks[p]
            r = res[p]
            r['late'] += drain(s)
            now = time.monotonic()
            if now < next_send:
                time.sleep(next_send - now)
            next_send = max(next_send + interval, time.monotonic())
            t0 = time.monotonic_ns()
            try:
                s.send(make_payload())
            except OSError:
                r['sent'] += 1
                r['refused'] += 1
                done += 1
                continue
            r['sent'] += 1
            deadline = t0 + int(timeout * 1e9)
            while True:
                left = (deadline - time.monotonic_ns()) / 1e9
                if left <= 0:
                    break
                rd, _, _ = select.select([s], [], [], left)
                if not rd:
                    break
                try:
                    s.recv(65535)
                except (BlockingIOError, InterruptedError):
                    continue
                except ConnectionRefusedError:
                    r['refused'] += 1
                    break
                r['recv'] += 1
                r['rtt'].append((time.monotonic_ns() - t0) / 1e6)
                break
            done += 1
            if progress and (done % 20 == 0 or done == total):
                sys.stderr.write('\r  %d/%d' % (done, total))
                sys.stderr.flush()
    if progress:
        sys.stderr.write('\n')
    return res


def summarize(res):
    rows = []
    for p, r in res.items():
        v = sorted(r['rtt'])
        rows.append({
            'port': p, 'sent': r['sent'], 'recv': r['recv'],
            'loss_pct': round(100.0 * (r['sent'] - r['recv']) / r['sent'], 1) if r['sent'] else None,
            'min_ms': round(v[0], 2) if v else None,
            'median_ms': round(percentile(v, 0.5), 2) if v else None,
            'p90_ms': round(percentile(v, 0.9), 2) if v else None,
            'max_ms': round(v[-1], 2) if v else None,
            'late': r['late'], 'refused': r['refused'],
        })
    return rows


def group_rows(rows, gap_ms, gap_rel):
    """중앙값을 정렬해 간격이 max(gap_ms, gap_rel×앞값) 보다 크면 새 갈래로 본다."""
    ok = sorted((r for r in rows if r['median_ms'] is not None), key=lambda r: r['median_ms'])
    groups, cur = [], []
    for r in ok:
        if cur and r['median_ms'] - cur[-1]['median_ms'] > max(gap_ms, gap_rel * cur[-1]['median_ms']):
            groups.append(cur)
            cur = []
        cur.append(r)
    if cur:
        groups.append(cur)
    return groups


def main():
    ap = argparse.ArgumentParser(
        description='출발 포트별 UDP 왕복 지연 측정 (multi-fec relay·server 의 인증 실패 응답 이용)',
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split('\n\n', 1)[1])
    ap.add_argument('target', type=parse_hostport, help='대상 ip:port (다음 홉 relay 또는 server, 보통 :443)')
    ap.add_argument('--local', default='', help='소스 IP — relay route 의 local / --upstream-local 과 같게 (기본: 커널 선택)')
    ap.add_argument('--ports', type=parse_ports, default=parse_ports('20000-20029'),
                    help='후보 출발 포트. 예: 20000-20029 또는 20101,20117 (기본 20000-20029)')
    ap.add_argument('--samples', type=int, default=8, help='포트당 측정 횟수 (기본 8)')
    ap.add_argument('--interval', type=float, default=DEFAULT_INTERVAL,
                    help='전체 송신 간격 초 (기본 %.2f — v1.4.2+ 대상은 소스 IP 당 초당 2회만 응답)' % DEFAULT_INTERVAL)
    ap.add_argument('--timeout', type=float, default=1.0, help='응답 대기 초 (기본 1.0)')
    ap.add_argument('--gap-ms', type=float, default=3.0, help='갈래 구분 최소 간격 ms (기본 3)')
    ap.add_argument('--gap-rel', type=float, default=0.08, help='갈래 구분 상대 간격 (기본 0.08 = 8%%)')
    ap.add_argument('--pick', type=int, default=2, help='추천 포트 수 (기본 2 — client 재시작 시 옛 세션 60초 겹침 대비)')
    ap.add_argument('--json', metavar='FILE', help='결과를 JSON 으로 저장')
    ap.add_argument('-q', '--quiet', action='store_true', help='진행 표시 끄기')
    a = ap.parse_args()

    if a.samples < 1 or a.interval <= 0 or a.timeout <= 0:
        ap.error('--samples ≥ 1, --interval·--timeout > 0')

    er = ephemeral_range()
    if er:
        inside = [p for p in a.ports if er[0] <= p <= er[1]]
        if inside:
            sys.stderr.write('경고: 포트 %d개가 커널 임의 포트 범위(%d-%d) 안에 있다 — 고정용으로 쓰려면 범위 밖이나 '
                             'ip_local_reserved_ports 에 등록된 포트를 고를 것: %s\n'
                             % (len(inside), er[0], er[1], inside[:8]))
    if a.interval < 0.5:
        sys.stderr.write('경고: --interval %.2f < 0.5 — v1.4.2+ 대상은 소스 IP 당 초당 2회만 응답하므로 '
                         '응답이 빠져 손실로 보인다\n' % a.interval)

    socks, skipped = open_sockets(a.target, a.local, a.ports)
    if skipped:
        sys.stderr.write('건너뜀(bind/connect 실패) %d개: %s\n'
                         % (len(skipped), ', '.join('%d=%s' % kv for kv in list(skipped.items())[:10])))
    if not socks:
        sys.stderr.write('쓸 수 있는 포트가 없다\n')
        return 2

    est = len(socks) * a.samples * a.interval
    src = '%s' % (a.local or '(커널 선택)')
    print('대상 %s:%d  소스 %s  포트 %d개 × %d회  간격 %.2fs  예상 %.0f초'
          % (a.target[0], a.target[1], src, len(socks), a.samples, a.interval, est))
    started = time.time()
    try:
        res = measure(socks, a.samples, a.interval, a.timeout, not a.quiet)
    except KeyboardInterrupt:
        sys.stderr.write('\n중단\n')
        return 130
    finally:
        for s in socks.values():
            s.close()

    rows = summarize(res)
    groups = group_rows(rows, a.gap_ms, a.gap_rel)
    rows_by_port = sorted(rows, key=lambda r: (r['median_ms'] is None, r['median_ms'] or 0))

    print('\n%6s %5s %5s %6s %8s %8s %8s %8s' % ('port', 'sent', 'recv', 'loss%', 'min', 'median', 'p90', 'max'))
    for r in rows_by_port:
        f = lambda v: '%8.2f' % v if v is not None else '%8s' % '-'
        print('%6d %5d %5d %6s %s %s %s %s' % (r['port'], r['sent'], r['recv'],
              '%.1f' % r['loss_pct'] if r['loss_pct'] is not None else '-',
              f(r['min_ms']), f(r['median_ms']), f(r['p90_ms']), f(r['max_ms'])))

    no_reply = [r['port'] for r in rows if r['recv'] == 0]
    print('\n갈래(중앙값 간격 기준) %d개:' % len(groups))
    for i, g in enumerate(groups):
        meds = [r['median_ms'] for r in g]
        print('  %s: %.2f~%.2f ms  포트 %d개  %s' % (chr(ord('A') + i) if i < 26 else str(i), min(meds), max(meds),
              len(g), ','.join(str(r['port']) for r in g[:12]) + (' …' if len(g) > 12 else '')))
    if no_reply:
        print('  응답 없음 %d개: %s' % (len(no_reply), ','.join(map(str, no_reply[:12]))))

    pick = []
    if groups:
        best = sorted(groups[0], key=lambda r: (r['loss_pct'], r['p90_ms'], r['median_ms']))
        pick = [r['port'] for r in best[:a.pick]]
        print('\n추천 포트(가장 빠른 갈래 중 손실·p90 낮은 순): %s' % ','.join(map(str, pick)))
        if len(groups) == 1:
            print('  (갈래가 하나로 보인다 — 포트 고정 효과가 없거나 후보가 적다)')
    else:
        print('\n응답이 하나도 없다 — 대상 주소·포트, 방화벽, 대상이 multi-fec relay/server 인지 확인')

    if a.json:
        out = {'target': '%s:%d' % a.target, 'local': a.local, 'samples': a.samples, 'interval': a.interval,
               'started': started, 'skipped': skipped, 'rows': rows,
               'groups': [[r['port'] for r in g] for g in groups], 'pick': pick}
        with open(a.json, 'w') as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print('JSON: %s' % a.json)
    return 0 if groups else 1


if __name__ == '__main__':
    sys.exit(main())
