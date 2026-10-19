#!/usr/bin/env python3
"""mf_agent.py — multi-fec 상태 에이전트 (2026-10-19, 테스트망 전용 — 서비스망 적용 금지)

각 호스트에서 multi-fec 유닛·경로·세션·자원을 모아 JSON 으로 중앙(mf_status.py)에 보낸다(push).
지사 client 는 NAT 뒤라 중앙이 가져가는(pull) 방식은 닿지 않을 수 있어 에이전트가 보낸다.

  mf_agent.py --url http://<중앙>:8780 --token <토큰>            # 30초마다 push
  mf_agent.py --stdout --count 3 --interval 10                     # push 없이 JSON 줄 출력 (시험)
  mf_agent.py --once                                               # 한 번 수집해 보기 좋게 출력

읽기 전용이다: systemctl show · journalctl · /proc · ss · wg show 만 읽는다. root 로 실행해야 다른 유닛의
저널·소켓이 보인다. **키는 보내지 않는다** — 지문(kf:)과 가린 명령줄만 보낸다. Python 3.8+ 표준 라이브러리만.
"""
import argparse, json, os, re, socket, subprocess, sys, time, urllib.request

VERSION = '0.1'
ANSI = re.compile(r'\x1b\[[0-9;]*m')
HZ = os.sysconf('SC_CLK_TCK')

RE_TS      = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]')
RE_VER     = re.compile(r'multi-fec (\d+\.\d+\.\d+) \(git ([^)]+)\)')
RE_KF      = re.compile(r'key (kf:[0-9a-f]{8}) from ([\w -]+)')
RE_ROUTE   = re.compile(r'route\[(\d+)\] key=(kf:[0-9a-f]{8}) upstream=(\S+)')
RE_PATH    = re.compile(r'\[client\] path\[(\d+)\] (\w+) (?:owd=([\d.]+)ms jit=([\d.]+)ms|rtt=(\d+)us jit=(\d+)us) '
                        r'loss=(\d+)% rate=([\d.]+)Mbps tx=(\d+) rx=(\d+)(?: dev=(\S+))?')
RE_REPORT  = re.compile(r'\[report\](?:\[([^\]]+)\])?client-->server:\(original:(\d+) pkt;(\d+) byte\) '
                        r'\(fec:(\d+) pkt[;,](\d+) byte\)\s+server-->client:\(original:(\d+) pkt;(\d+) byte\) '
                        r'\(fec:(\d+) pkt[;,](\d+) byte\)')   # 클라이언트 쪽은 fec 구간이 "pkt," 로 찍힌다
RE_SESSION = re.compile(r'\[relay\] (new session|session removed): client=(\S+)(?: upstream=(\S+))? fd=(\d+)')
RE_PROBE   = re.compile(r'\[relay/decoy\] new session prober=(\S+)')
RE_FULL    = re.compile(r'\[relay\] session table full')


def sh(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ''


def journal_head(unit, pid, n=120):
    """프로세스 기동 직후 줄(버전·키 지문·route) — 오래 돈 프로세스도 앞부분만 읽는다."""
    try:
        p = subprocess.Popen(['journalctl', '-u', unit, f'_PID={pid}', '-o', 'cat', '--no-pager', '-q'],
                             stdout=subprocess.PIPE, text=True, errors='replace')
        lines = []
        for line in p.stdout:
            lines.append(ANSI.sub('', line.rstrip('\n')))
            if len(lines) >= n:
                break
        p.kill(); p.wait()
        return lines
    except Exception:
        return []


def journal_tail(unit, pid, n=300):
    out = sh(['journalctl', '-u', unit, f'_PID={pid}', '-o', 'cat', '--no-pager', '-q', '-n', str(n)])
    return [ANSI.sub('', l) for l in out.splitlines()]


def mask_cmdline(args):
    """키가 될 수 있는 값을 가린다(1.3.x 는 argv 에 키가 평문)."""
    out, hide = [], False
    for a in args:
        if hide:
            out.append('****'); hide = False; continue
        if a in ('-k', '--key', '--route'):
            out.append(a); hide = True; continue
        if a.startswith(('--key=', '--route=')):
            out.append(a.split('=', 1)[0] + '=****'); continue
        if a.startswith('-k') and len(a) > 2:
            out.append('-k****'); continue
        out.append(a)
    return out


def role_of(args):
    for a in args[1:]:
        if a in ('-c', '-s', '-r'):
            return {'-c': 'client', '-s': 'server', '-r': 'relay'}[a]
    if '--config' in args:
        try:
            path = args[args.index('--config') + 1]
            for line in open(path):
                m = re.match(r'\s*mode\s*=\s*(client|server|relay)', line)
                if m:
                    return m.group(1)
        except Exception:
            pass
    return '?'


def socket_inodes(pid):
    inodes = set()
    try:
        for fd in os.listdir(f'/proc/{pid}/fd'):
            try:
                t = os.readlink(f'/proc/{pid}/fd/{fd}')
            except OSError:
                continue
            if t.startswith('socket:['):
                inodes.add(t[8:-1])
    except OSError:
        pass
    return inodes


def udp_drops(inodes):
    total = 0
    for f in ('/proc/net/udp', '/proc/net/udp6'):
        try:
            for line in open(f).readlines()[1:]:
                x = line.split()
                if len(x) > 9 and x[9] in inodes:
                    total += int(x[-1])
        except OSError:
            pass
    return total


def connected_udp(pid):
    """연결된 UDP 소켓 수 — relay 에서는 세션 수(세션마다 upstream 소켓 1개)."""
    out = sh(['ss', '-unp'])
    return sum(1 for l in out.splitlines() if f'pid={pid},' in l)


class Agent:
    def __init__(self, unit_glob):
        self.unit_glob = unit_glob
        self.prev_ticks = {}       # pid -> (ticks, t)
        self.prev_net = None       # (rx, tx, t)
        self.head_cache = {}       # (unit, pid) -> parsed startup info
        self.relay_state = {}      # (unit, pid) -> 세션 표·커서

    def units(self):
        out = sh(['systemctl', 'list-units', '--plain', '--no-legend', '--all', '--type=service'] + self.unit_glob)
        return [l.split()[0] for l in out.splitlines() if l.strip() and l.split()[0].endswith('.service')]

    def unit(self, u, now):
        props = {}
        for line in sh(['systemctl', 'show', u, '-p', 'MainPID,ActiveState,SubState,NRestarts,ActiveEnterTimestamp,UnitFileState']).splitlines():
            if '=' in line:
                k, v = line.split('=', 1); props[k] = v
        pid = int(props.get('MainPID', '0') or 0)
        d = {'name': u.replace('.service', ''), 'active': props.get('ActiveState') == 'active',
             'state': f"{props.get('ActiveState')}/{props.get('SubState')}", 'enabled': props.get('UnitFileState'),
             'restarts': int(props.get('NRestarts', '0') or 0), 'started': props.get('ActiveEnterTimestamp', ''), 'pid': pid}
        if pid <= 0 or not os.path.exists(f'/proc/{pid}'):
            return d
        try:
            args = open(f'/proc/{pid}/cmdline').read().split('\0')[:-1]
        except OSError:
            args = []
        d['role'] = role_of(args)
        d['cmdline'] = ' '.join(mask_cmdline(args))[:400]
        try:
            st = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
            ticks = int(st[11]) + int(st[12])
            prev = self.prev_ticks.get(pid)
            if prev:
                d['cpu'] = round((ticks - prev[0]) / HZ / max(1e-3, now - prev[1]) * 100, 1)
            self.prev_ticks[pid] = (ticks, now)
            for line in open(f'/proc/{pid}/status'):
                if line.startswith('VmRSS:'):
                    d['rss_mb'] = round(int(line.split()[1]) / 1024, 1)
                if line.startswith('Threads:'):
                    d['threads'] = int(line.split()[1])
            d['fd'] = len(os.listdir(f'/proc/{pid}/fd'))
        except (OSError, IndexError, ValueError):
            pass
        d['drops'] = udp_drops(socket_inodes(pid))
        if d['role'] == 'relay':
            d['sessions'] = connected_udp(pid)

        key = (u, pid)
        if key not in self.head_cache:
            info = {'routes': {}}
            for l in journal_head(u, pid):
                m = RE_VER.search(l)
                if m and 'version' not in info:
                    info['version'], info['git'] = m.group(1), m.group(2)
                m = RE_KF.search(l)
                if m and 'kf' not in info:
                    info['kf'], info['kf_from'] = m.group(1), m.group(2).strip()
                m = RE_ROUTE.search(l)
                if m:
                    info['routes'][int(m.group(1))] = {'kf': m.group(2), 'upstream': m.group(3)}
            if 'version' not in info:    # 1.3.x 는 같은 줄을 남긴다; 그래도 없으면 실행 파일에 묻는다
                exe = os.path.realpath(f'/proc/{pid}/exe') if os.path.exists(f'/proc/{pid}/exe') else ''
                if os.path.basename(exe).startswith('multi-fec'):
                    v = sh([exe, '--version'], timeout=5)
                    m = re.search(r'multi-fec (\S+)\s+git:\s+(\S+)', v)
                    if m:
                        info['version'], info['git'] = m.group(1), m.group(2)
            self.head_cache = {k: v for k, v in self.head_cache.items() if k[0] != u}   # 재시작 시 이전 PID 정보 정리
            self.head_cache[key] = info
        info = self.head_cache[key]
        d.update({k: v for k, v in info.items() if k != 'routes'})
        if info['routes']:
            d['routes'] = [dict(i=i, **r) for i, r in sorted(info['routes'].items())]

        if d.get('role') == 'relay':
            self.relay_sessions(u, pid, d, info)

        tail = journal_tail(u, pid)
        paths, reports, last_ts = {}, {}, None
        for l in tail:
            mt = RE_TS.match(l)
            ts = mt.group(1) if mt else None
            m = RE_PATH.search(l)
            if m:
                i = int(m.group(1))
                p = {'i': i, 'status': m.group(2), 'loss': int(m.group(7)), 'rate': float(m.group(8)),
                     'tx': int(m.group(9)), 'rx': int(m.group(10)), 'dev': m.group(11), 'ts': ts}
                if m.group(3) is not None:
                    p['owd'], p['jit'] = float(m.group(3)), float(m.group(4))
                else:
                    p['legacy'] = True            # 1.3.2 이하의 rtt=..us 표기 (값은 ms 단위·시계 의존)
                paths[i] = p
            m = RE_REPORT.search(l)
            if m:
                reports[m.group(1) or '-'] = {'peer': m.group(1), 'up_pkt': int(m.group(2)), 'up_byte': int(m.group(3)),
                                              'dn_pkt': int(m.group(6)), 'dn_byte': int(m.group(7)), 'ts': ts}
            if 'WARN' in l or 'ERROR' in l or 'FATAL' in l:
                last_ts = ts
        if paths:
            d['paths'] = [paths[i] for i in sorted(paths)]
        if reports:
            d['reports'] = list(reports.values())
        warn = [l for l in tail if ('[ERROR]' in l or '[FATAL]' in l)]
        d['errors_recent'] = len(warn)
        return d

    def relay_sessions(self, u, pid, d, info):
        """relay 세션 표: 로그의 new session / session removed 를 커서로 이어 읽어 fd 별 표를 유지하고,
        그 fd 가 지금 실제로 열린 upstream 소켓인지 ss 로 확인한다. 세션별 트래픽은 OS 가 주지 않는다(UDP 소켓에 카운터 없음)."""
        st = self.relay_state.get((u, pid))
        if st is None:
            self.relay_state = {k: v for k, v in self.relay_state.items() if k[0] != u}
            st = self.relay_state[(u, pid)] = {'cursor': None, 'fds': {}, 'probes': 0, 'probe_ips': {}, 'full': 0}
        cmd = ['journalctl', '-u', u, f'_PID={pid}', '-o', 'cat', '--no-pager', '-q', '--show-cursor',
               '-g', r'\[relay(/decoy)?\] (new session|session removed|session table full)']
        if st['cursor']:
            cmd += ['--after-cursor', st['cursor']]
        for l in sh(cmd, timeout=30).splitlines():
            if l.startswith('-- cursor: '):
                st['cursor'] = l[11:].strip(); continue
            l = ANSI.sub('', l)
            mt = RE_TS.match(l); ts = mt.group(1) if mt else None
            m = RE_SESSION.search(l)
            if m:
                fd = int(m.group(4))
                if m.group(1) == 'new session':
                    st['fds'][fd] = {'client': m.group(2), 'upstream': m.group(3), 'since': ts}
                elif st['fds'].get(fd, {}).get('client') == m.group(2):
                    del st['fds'][fd]
                continue
            m = RE_PROBE.search(l)
            if m:
                st['probes'] += 1
                ip = m.group(1).rsplit(':', 1)[0]
                st['probe_ips'][ip] = st['probe_ips'].get(ip, 0) + 1
                if len(st['probe_ips']) > 200:                     # 상한 — 많이 온 것만 남긴다
                    st['probe_ips'] = dict(sorted(st['probe_ips'].items(), key=lambda x: -x[1])[:100])
                continue
            if RE_FULL.search(l):
                st['full'] += 1
        # 지금 열린 upstream 소켓 (fd → 로컬·원격·큐)
        socks = {}
        for line in sh(['ss', '-uanp']).splitlines():
            if f'pid={pid},' not in line:
                continue
            f = line.split()
            m = re.search(r'pid=%d,fd=(\d+)' % pid, line)
            if m and len(f) >= 5 and not f[4].endswith(':*'):
                socks[int(m.group(1))] = {'local': f[3], 'remote': f[4], 'recvq': int(f[1]), 'sendq': int(f[2])}
        up2kf = {}
        for r in info.get('routes', {}).values():
            up2kf.setdefault(r['upstream'], []).append(r['kf'])
        out = []
        for fd, se in sorted(st['fds'].items()):
            sk = socks.get(fd)
            if not sk:
                continue                      # 로그에는 있지만 소켓이 없다 = 놓친 removed (재시작 등)
            kf = up2kf.get(se['upstream']) or ([info['kf']] if info.get('kf') else [])
            try:     # 로그 시각은 호스트 현지 시각이다 — 여기서 epoch 로 바꿔야 타임존이 다른 중앙·브라우저에서 맞는다
                since_ts = int(time.mktime(time.strptime(se['since'], '%Y-%m-%d %H:%M:%S'))) if se['since'] else None
            except ValueError:
                since_ts = None
            out.append({'client': se['client'], 'upstream': se['upstream'], 'since': se['since'], 'since_ts': since_ts, 'fd': fd,
                        'local': sk['local'], 'recvq': sk['recvq'], 'sendq': sk['sendq'], 'kf': ' '.join(kf)})
        d['session_list'] = out[:500]
        d['probes'] = st['probes']
        d['probe_top'] = sorted(st['probe_ips'].items(), key=lambda x: -x[1])[:10]
        d['table_full'] = st['full']

    def host(self, now):
        h = {'cores': os.cpu_count()}
        try:
            h['load'] = [float(x) for x in open('/proc/loadavg').read().split()[:3]]
            mem = {}
            for line in open('/proc/meminfo'):
                k, v = line.split(':', 1); mem[k] = int(v.split()[0])
            h['mem_used_mb'] = round((mem['MemTotal'] - mem['MemAvailable']) / 1024)
            h['mem_total_mb'] = round(mem['MemTotal'] / 1024)
            rx = tx = 0
            for line in open('/proc/net/dev').readlines()[2:]:
                name, rest = line.split(':', 1)
                if name.strip() == 'lo':
                    continue
                f = rest.split(); rx += int(f[0]); tx += int(f[8])
            if self.prev_net:
                dt = max(1e-3, now - self.prev_net[2])
                h['rx_mbps'] = round((rx - self.prev_net[0]) * 8 / dt / 1e6, 2)
                h['tx_mbps'] = round((tx - self.prev_net[1]) * 8 / dt / 1e6, 2)
            self.prev_net = (rx, tx, now)
            lines = [l.split() for l in open('/proc/net/snmp') if l.startswith('Udp:')]
            if len(lines) == 2:
                u = dict(zip(lines[0][1:], map(int, lines[1][1:])))
                h['udp'] = {k: u.get(k, 0) for k in ('InDatagrams', 'OutDatagrams', 'InErrors', 'RcvbufErrors', 'SndbufErrors')}
        except (OSError, KeyError, ValueError):
            pass
        h['ntp_sync'] = sh(['timedatectl', 'show', '-p', 'NTPSynchronized', '--value']).strip() == 'yes'
        wg = []
        for line in sh(['wg', 'show', 'all', 'dump']).splitlines():
            f = line.split('\t')
            if len(f) == 9:          # 피어 줄 (인터페이스 줄은 5칸)
                hs = int(f[5]) if f[5].isdigit() else 0
                wg.append({'if': f[0], 'peer': f[1][:8], 'endpoint': f[3],
                           'handshake_age': (int(now) - hs) if hs else None, 'rx': int(f[6]), 'tx': int(f[7])})
        if wg:
            h['wg'] = wg
        return h

    def collect(self):
        now = time.time()
        return {'v': 1, 'agent': VERSION, 'host': socket.gethostname(), 'ts': int(now),
                'units': [self.unit(u, now) for u in self.units()], 'host_stats': self.host(now)}


def push(url, token, doc):
    req = urllib.request.Request(url.rstrip('/') + '/api/push', data=json.dumps(doc).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def main():
    ap = argparse.ArgumentParser(description='multi-fec 상태 에이전트 (테스트망 전용)')
    ap.add_argument('--url', help='중앙 mf_status 주소 (예: http://10.9.20.1:8780)')
    ap.add_argument('--token', default=os.environ.get('MF_AGENT_TOKEN', ''), help='호스트 토큰 (또는 MF_AGENT_TOKEN)')
    ap.add_argument('--interval', type=float, default=30)
    ap.add_argument('--count', type=int, default=0, help='N번 수집 후 종료 (0=계속)')
    ap.add_argument('--units', default='multi-fec*', help='감시할 유닛 glob (공백으로 여러 개)')
    ap.add_argument('--stdout', action='store_true', help='push 대신 JSON 한 줄씩 출력')
    ap.add_argument('--once', action='store_true', help='한 번 수집해 보기 좋게 출력')
    a = ap.parse_args()
    ag = Agent(a.units.split())
    if a.once:
        ag.collect(); time.sleep(2)               # CPU·트래픽 차이를 내려고 두 번
        print(json.dumps(ag.collect(), ensure_ascii=False, indent=1)); return
    if not a.stdout and not (a.url and a.token):
        ap.error('--url 과 --token (또는 --stdout / --once)')
    n = 0
    while True:
        doc = ag.collect()
        if a.stdout:
            print(json.dumps(doc, ensure_ascii=False), flush=True)
        else:
            try:
                push(a.url, a.token, doc)
            except Exception as e:
                print(f'push 실패: {e}', file=sys.stderr, flush=True)
        n += 1
        if a.count and n >= a.count:
            break
        time.sleep(a.interval)


if __name__ == '__main__':
    main()
