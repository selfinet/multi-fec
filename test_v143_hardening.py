#!/usr/bin/env python3
"""
test_v143_hardening.py — 1.4.3 hardening (CLAUDE.md §33). Loopback only; starts
its own processes on random ports and stops them by PID (never pkill).

  T1  TOTP port: authenticated datagram longer than the mud limit does not
      abort the server (FEC decoder assert, ≤1.4.2); a normal-size one still
      opens a session
  T2  --accept-local: a probe to an excluded local address gets no reply
      (mud socket); an accepted address still gets one
  T3  probe reply leaves from the address the probe was sent to (wildcard bind)
  T4  TOTP sockets bind to the -l address only (≤1.4.2: INADDR_ANY)
  T5  decoy flood + authenticated conv load share one FD budget: no socket
      allocation failure for legitimate convs, FD stays below RLIMIT
  T6  relay: session cap + decoy cap fit the FD budget (start-up log)

BIN=./multi-fec-old python3 test_v143_hardening.py   → A/B against an older build
"""
import os, re, socket, struct, subprocess, sys, tempfile, time, resource, signal

BIN = os.environ.get('BIN', './multi-fec')
KEY = 'v143-hardening-key'
AUTH_INTERVAL = 60
M64 = 0xFFFFFFFFFFFFFFFF

def _rotl(v, n): return ((v << n) | (v >> (64 - n))) & M64
def _round(v0, v1, v2, v3):
    v0 = (v0 + v1) & M64; v1 = _rotl(v1, 13); v1 ^= v0; v0 = _rotl(v0, 32)
    v2 = (v2 + v3) & M64; v3 = _rotl(v3, 16); v3 ^= v2
    v0 = (v0 + v3) & M64; v3 = _rotl(v3, 21); v3 ^= v0
    v2 = (v2 + v1) & M64; v1 = _rotl(v1, 17); v1 ^= v2; v2 = _rotl(v2, 32)
    return v0, v1, v2, v3
def siphash24(data, key):
    k0, k1 = struct.unpack_from('<QQ', key)
    v0 = k0 ^ 0x736f6d6570736575; v1 = k1 ^ 0x646f72616e646f6d
    v2 = k0 ^ 0x6c7967656e657261; v3 = k1 ^ 0x7465646279746573
    nb = len(data) // 8
    for i in range(nb):
        m = struct.unpack_from('<Q', data, i * 8)[0]
        v3 ^= m; v0, v1, v2, v3 = _round(*_round(v0, v1, v2, v3)); v0 ^= m
    b = (len(data) & 0xff) << 56
    for i, c in enumerate(data[nb * 8:]): b |= c << (8 * i)
    v3 ^= b; v0, v1, v2, v3 = _round(*_round(v0, v1, v2, v3)); v0 ^= b
    v2 ^= 0xff
    for _ in range(4): v0, v1, v2, v3 = _round(v0, v1, v2, v3)
    return (v0 ^ v1 ^ v2 ^ v3) & M64
DERIV = bytes([0x6d,0x75,0x6c,0x74,0x69,0x2d,0x66,0x65,0x63,0x2d,0x70,0x73,0x6b,0x2d,0x76,0x31])
def psk(k):
    kb = k.encode()
    return struct.pack('<QQ', siphash24(kb, DERIV), siphash24(kb + b'\x01', DERIV))
def token_now(k):
    slot = int(time.time()) // AUTH_INTERVAL
    return struct.pack('<Q', siphash24(struct.pack('<Q', slot), psk(k)))
def authed_quic(size):
    """QUIC-short obfs datagram with a valid token: [sid 8][FEC hdr 8][fill]."""
    tok = token_now(KEY)
    p = bytearray(size)
    p[0] = 0x40 | (tok[0] & 0x3F); p[1:8] = tok[1:8]; p[8] = tok[0]; p[9] = 0
    p[10:18] = os.urandom(8)
    p[18:22] = struct.pack('<I', 1); p[22] = 1
    return bytes(p)
def bad_quic(n): return bytes([0x40]) + os.urandom(n - 1)

passed = failed = 0
def check(name, ok, extra=''):
    global passed, failed
    if ok: passed += 1
    else:  failed += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  ' + extra) if extra else ''}")

def free_port(ip='127.0.0.1'):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ip, 0))
    p = s.getsockname()[1]; s.close(); return p

procs = []
def start(args, soft=None, settle=0.8):
    log = tempfile.NamedTemporaryFile(prefix='v143_', suffix='.log', delete=False)
    pre = (lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (soft, soft))) if soft else None
    p = subprocess.Popen([BIN] + args + ['--log-level', '4'], stdout=log,
                         stderr=subprocess.STDOUT, preexec_fn=pre)
    procs.append(p); time.sleep(settle)
    return p, log.name
def stop(p):
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
def stop_all():
    for p in procs: stop(p)
def probe(dst, port, data, timeout=0.6):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(timeout)
    s.sendto(data, (dst, port))
    try: r, a = s.recvfrom(4096)
    except socket.timeout: r, a = None, None
    s.close(); return r, a
def nfd(pid):
    try: return len(os.listdir('/proc/%d/fd' % pid))
    except OSError: return -1
def totp_ports(logfile):
    return [int(x) for x in re.findall(r'totp: listening port (\d+)', open(logfile).read())]

def t1_totp_oversize():
    print('\n[T1 TOTP oversize]')
    lp, wp = free_port(), free_port()
    p, log = start(['-s', '-l', f'127.0.0.1:{lp}', '--wg', f'127.0.0.1:{wp}', '-k', KEY,
                    '--port-hop-interval', '30'])
    ports = totp_ports(log)
    check('TOTP sockets open', len(ports) >= 1, f'ports={ports}')
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for port in ports: s.sendto(authed_quic(3790), ('127.0.0.1', port))
    time.sleep(0.8)
    check('3790 B authenticated datagram → server alive', p.poll() is None, f'rc={p.poll()}')
    for port in ports: s.sendto(authed_quic(1400), ('127.0.0.1', port))
    time.sleep(0.8)
    txt = open(log).read()
    check('1400 B authenticated datagram still accepted', 'totp: new session' in txt and p.poll() is None)
    s.close(); stop(p)

def t2_t3_accept_local_and_source():
    print('\n[T2/T3 accept-local · reply source]')
    lp = free_port()
    p, _ = start(['-s', '-l', f'0.0.0.0:{lp}', '--wg', '127.0.0.1:9', '-k', KEY,
                  '--accept-local', '127.0.0.2'])
    r, a = probe('127.0.0.2', lp, bad_quic(1300))
    check('probe to accepted 127.0.0.2 → reply', r is not None)
    check('reply source == 127.0.0.2 (address probed)', a is not None and a[0] == '127.0.0.2', f'from={a}')
    time.sleep(1.2)
    r, a = probe('127.0.0.3', lp, bad_quic(1300))
    check('probe to excluded 127.0.0.3 → no reply', r is None, f'got {len(r)} B from {a}' if r else '')
    stop(p)
    lp = free_port()
    p, _ = start(['-s', '-l', f'0.0.0.0:{lp}', '--wg', '127.0.0.1:9', '-k', KEY])
    r, a = probe('127.0.0.5', lp, bad_quic(1300))
    check('wildcard, no list: reply source == 127.0.0.5', a is not None and a[0] == '127.0.0.5', f'from={a}')
    stop(p)

def t4_totp_bind():
    print('\n[T4 TOTP bind address]')
    lp, wp = free_port('127.0.0.2'), free_port()
    p, log = start(['-s', '-l', f'127.0.0.2:{lp}', '--wg', f'127.0.0.1:{wp}', '-k', KEY,
                    '--port-hop-interval', '30'])
    ports = totp_ports(log)
    other = [probe('127.0.0.3', port, bad_quic(1300))[0] for port in ports]
    check('TOTP port on 127.0.0.3 (not -l) → no reply', ports and all(r is None for r in other))
    time.sleep(1.2)
    own = [probe('127.0.0.2', port, bad_quic(1300)) for port in ports[:1]]
    check('TOTP port on 127.0.0.2 (-l) → reply from 127.0.0.2',
          own and own[0][0] is not None and own[0][1][0] == '127.0.0.2', f'{own[0][1] if own else None}')
    stop(p)

def t5_fd_mix():
    print('\n[T5 decoy + conv FD budget]')
    SOFT = 200
    SP, WG, CP = free_port(), free_port(), free_port()
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sink.bind(('127.0.0.1', 0))
    wg = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); wg.bind(('127.0.0.1', WG)); wg.settimeout(0.05)
    srv, slog = start(['-s', '-l', f'127.0.0.1:{SP}', '--wg', f'127.0.0.1:{WG}', '-k', 'convcap',
                       '--decoy', f'127.0.0.1:{sink.getsockname()[1]}'], soft=SOFT, settle=0.6)
    cli, _ = start(['-c', '-l', f'127.0.0.1:{CP}', '--path', f'127.0.0.1:127.0.0.1:{SP}', '-k', 'convcap'],
                   settle=1.2)
    socks = []; fdmax = 0
    for i in range(300):                       # unauthenticated: no key needed
        c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        c.sendto(bad_quic(50), ('127.0.0.1', SP)); socks.append(c)
        if i % 50 == 49: time.sleep(0.05); fdmax = max(fdmax, nfd(srv.pid))
    time.sleep(0.5)
    got = set()
    for i in range(60):
        c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.bind(('127.0.0.1', 0))
        c.sendto(('flow%04d' % i).encode().ljust(120, b'.'), ('127.0.0.1', CP)); socks.append(c)
        if i % 20 == 19: time.sleep(0.05); fdmax = max(fdmax, nfd(srv.pid))
    t = time.time()
    while time.time() - t < 2:
        try: got.add(wg.recv(4096)[:8])
        except socket.timeout: pass
    fdmax = max(fdmax, nfd(srv.pid))
    txt = open(slog).read()
    check('no new_connected_socket failure', txt.count('new_connected_socket failed') == 0,
          f"count={txt.count('new_connected_socket failed')}")
    check('all 60 legitimate convs delivered', len(got) == 60, f'{len(got)}/60')
    check('FD stays below RLIMIT', 0 < fdmax < SOFT, f'fd_max={fdmax} soft={SOFT}')
    check('no decoy EMFILE', 'Too many open files' not in txt)
    for c in socks: c.close()
    stop(cli); stop(srv); sink.close(); wg.close()

def t6_relay_budget():
    print('\n[T6 relay FD budget]')
    lp, up = free_port(), free_port()
    p, log = start(['-r', '-l', f'127.0.0.1:{lp}', '--route', f'{KEY} 127.0.0.1:{up}',
                    '--decoy', '127.0.0.1:9'], soft=1024)
    m = re.search(r'\[relay\] FD budget: soft=(\d+) open=(\d+) reserve=(\d+) → client sockets (\d+), decoy (\d+)',
                  open(log).read())
    ok = bool(m) and int(m.group(4)) + int(m.group(5)) + int(m.group(2)) + int(m.group(3)) <= int(m.group(1))
    check('relay sessions + decoy + open + reserve ≤ soft', ok, m.group(0) if m else 'no budget line')
    stop(p)

try:
    t1_totp_oversize()
    t2_t3_accept_local_and_source()
    t4_totp_bind()
    t5_fd_mix()
    t6_relay_budget()
finally:
    stop_all()
print(f'\n{passed}/{passed + failed} passed')
sys.exit(1 if failed else 0)
