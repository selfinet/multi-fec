#!/usr/bin/env python3
"""
test_probe_hardening.py — builtin probe reply hardening (v1.4.2, CLAUDE.md §32)

Loopback only. Starts its own server/relay processes on random ports and stops
them by PID (never pkill — see the harness pitfalls note).

  TC1  small datagram (< 1200 B) gets no reply                (server, relay)
  TC2  1200 B unauthenticated datagram gets a Server Initial whose DCID is
       not a valid auth token, and whose size stays within 3x the request
  TC3  a packet forged from the reply's DCID does not authenticate
       (server: no "new session", relay: no "new session")
  TC4  per-source rate limit caps a burst of probes from one IP
  TC5  TLS mode: close_notify only for requests >= 7 B
  TC6  --decoy session table is capped (FD count bounded)

BIN=./multi-fec-v141 python3 test_probe_hardening.py   → A/B against an older build
"""
import os, socket, struct, subprocess, sys, tempfile, time, random

BIN = os.environ.get('BIN', './multi-fec')
KEY = 'probe-hardening-test-key'
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
def valid_tokens(k):
    slot = int(time.time()) // AUTH_INTERVAL
    return {struct.pack('<Q', siphash24(struct.pack('<Q', s), psk(k)))
            for s in (slot - 1, slot, slot + 1)}

passed = failed = 0
def check(name, ok, extra=''):
    global passed, failed
    if ok: passed += 1
    else: failed += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  ' + extra) if extra else ''}")

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]; s.close(); return p

procs = []
def start(args):
    log = tempfile.NamedTemporaryFile(prefix='probe_', suffix='.log', delete=False)
    p = subprocess.Popen([BIN] + args + ['--log-level', '4'], stdout=log, stderr=subprocess.STDOUT)
    procs.append(p); time.sleep(0.6)
    return p, log.name

def stop_all():
    for p in procs:
        if p.poll() is None: p.terminate()
    for p in procs:
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill()

def probe(port, data, timeout=0.5, sock=None):
    s = sock or socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(data, ('127.0.0.1', port))
    try: r, _ = s.recvfrom(4096)
    except socket.timeout: r = None
    if sock is None: s.close()
    return r

def bad_quic(n):   # wrong token, QUIC short header form
    return bytes([0x40]) + bytes(random.getrandbits(8) for _ in range(n - 1))

def forge(dcid, sid=b'FORGED!!'):
    hdr = bytes([0x40 | (dcid[0] & 0x3f)]) + dcid[1:8] + bytes([dcid[0], 0])
    t = int(time.time() * 1e6) & ((1 << 48) - 2)
    return hdr + t.to_bytes(6, 'little') + sid + b'\x00' * 40

def fd_count(pid):
    return len(os.listdir(f'/proc/{pid}/fd'))

def run():
    sp = free_port(); rp = free_port(); up = free_port()
    _, slog = start(['-s', '-l', f'127.0.0.1:{sp}', '--wg', '127.0.0.1:9', '-k', KEY])
    _, rlog = start(['-r', '-l', f'127.0.0.1:{rp}', '--route', f'{KEY} 127.0.0.1:{up}'])
    toks = valid_tokens(KEY)

    for name, port in (('server', sp), ('relay', rp)):
        print(f'\n[{name}]')
        r = probe(port, bad_quic(10))
        check('TC1 10 B probe → no reply', r is None, f'got {len(r)} B' if r else '')
        r = probe(port, bad_quic(1199))
        check('TC1 1199 B probe → no reply', r is None, f'got {len(r)} B' if r else '')

        r = probe(port, bad_quic(1200))
        ok = r is not None and r[0] == 0xC1 and r[15] == 0xFF and 1200 <= len(r) <= 3600
        check('TC2 1200 B probe → Server Initial ≤ 3x', ok, f'{len(r)} B' if r else 'no reply')
        dcid = r[6:14] if r else b'\0' * 8
        check('TC2 DCID is not an auth token', r is not None and dcid not in toks)

        before = open(slog if name == 'server' else rlog).read().count('new session')
        for _ in range(5):
            probe(port, forge(dcid), timeout=0.05)
        time.sleep(0.5)
        after = open(slog if name == 'server' else rlog).read().count('new session')
        check('TC3 packet forged from reply DCID → no session', after == before,
              f'new sessions {after - before}')

    print('\n[rate limit — server]')
    time.sleep(3)                                 # let the source bucket refill
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(0.3)
    for _ in range(30): s.sendto(bad_quic(1200), ('127.0.0.1', sp))
    got = 0
    try:
        while True: s.recvfrom(4096); got += 1
    except socket.timeout: pass
    s.close()
    check('TC4 30-probe burst from one IP → ≤ 6 replies', got <= 6, f'{got} replies')

    print('\n[TLS mode — server]')
    tp = free_port()
    start(['-s', '-l', f'127.0.0.1:{tp}', '--wg', '127.0.0.1:9', '-k', KEY, '--obfs-mode', 'tls'])
    r = probe(tp, bytes([0x17, 3, 3]))
    check('TC5 3 B → no reply', r is None)
    r = probe(tp, bytes([0x17, 3, 3, 0, 9]) + b'\x00' * 9)
    check('TC5 14 B → close_notify 7 B', r is not None and len(r) == 7 and r[0] == 0x15)

    print('\n[decoy cap]')
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sink.bind(('127.0.0.1', 0))
    dport = sink.getsockname()[1]
    for mode in ('server', 'relay'):
        lp = free_port()
        if mode == 'server':
            p, _ = start(['-s', '-l', f'127.0.0.1:{lp}', '--wg', '127.0.0.1:9', '-k', KEY,
                          '--decoy', f'127.0.0.1:{dport}'])
        else:
            p, _ = start(['-r', '-l', f'127.0.0.1:{lp}', '--route', f'{KEY} 127.0.0.1:{up}',
                          '--decoy', f'127.0.0.1:{dport}'])
        base = fd_count(p.pid)
        socks = []
        for i in range(400):
            c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            c.sendto(bad_quic(50), ('127.0.0.1', lp)); socks.append(c)
            if i % 50 == 49: time.sleep(0.05)
        time.sleep(0.8)
        grown = fd_count(p.pid) - base
        for c in socks: c.close()
        check(f'TC6 {mode}: 400 probers → decoy FDs ≤ 256', grown <= 256, f'+{grown} FD')
    sink.close()

try:
    run()
finally:
    stop_all()
print(f'\n{passed}/{passed + failed} passed')
sys.exit(1 if failed else 0)
