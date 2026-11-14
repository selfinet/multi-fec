#!/usr/bin/env python3
"""test_relay_ports.py — relay route "ports" (upstream source-port pool) 검증, sv1 루프백 전용.

  BIN=./multi-fec python3 test_relay_ports.py

upstream 자리에 UDP 에코 sink 를 두고, sink 가 보는 relay 의 출발 포트로 판정한다.
  T1 파싱 거부(0·범위 초과·중복·두 번·65개 초과) / 두 route 같은 포트 → 기동 거부
  T2 첫 세션 = 목록 첫 포트, 왕복 정상
  T3 첫 세션이 살아 있을 때 둘째 세션 = 둘째 포트
  T4 두 포트 모두 살아 있는 세션 → 커널 포트로 대체 + 경고
  T5 client 가 3초 넘게 조용한 세션의 포트 회수 → 새 세션이 그 포트 (server probe 가 계속 와도)
  T6 relay 재시작 → 즉시 첫 포트
  T7 다른 프로세스가 첫 포트를 잡고 있으면 둘째 포트
  T8 ports 없음 → 커널 포트(기존 동작)
  T9 --check: ports 표시·임의 범위 경고·route 간 중복 오류
"""
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get('BIN', os.path.join(HERE, 'multi-fec'))
spec = importlib.util.spec_from_file_location('trr', os.path.join(HERE, 'test_relay_routing.py'))
trr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trr)

KEY = 'ports-test-key-A'
KEY2 = 'ports-test-key-B'
P1, P2 = 21017, 21004
LISTEN = ('127.0.0.1', 24561)
SINK = ('127.0.0.1', 24562)

results = []


def check(name, cond, detail=''):
    results.append((name, bool(cond)))
    print('  [%s] %s %s' % ('PASS' if cond else 'FAIL', name, detail))


class Sink:
    """upstream 자리. 받은 패킷의 출발 포트를 기록하고 그대로 돌려준다."""
    def __init__(self, addr):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.bind(addr)
        self.s.settimeout(0.2)
        self.seen = []           # (time, src_port, payload_tag)
        self.stop = False
        self.t = threading.Thread(target=self.run, daemon=True)
        self.t.start()
        # server 처럼 아는 상대에게 스스로 probe 를 계속 보낸다 — client 가 사라져도
        # relay 세션에 하향 패킷이 계속 온다(2026-11-15 mini 에서 회수 0회로 드러난 조건)
        self.peers = set()
        self.pt = threading.Thread(target=self.probe, daemon=True)
        self.pt.start()

    def probe(self):
        while not self.stop:
            for a in list(self.peers):
                try:
                    self.s.sendto(b'probe-from-server', a)
                except OSError:
                    pass
            time.sleep(0.1)

    def run(self):
        while not self.stop:
            try:
                d, a = self.s.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            self.seen.append((time.time(), a[1], d))
            self.peers.add(a)
            try:
                self.s.sendto(d, a)
            except OSError:
                pass

    def ports_for(self, tag):
        return {p for _, p, d in self.seen if tag in d}

    def close(self):
        self.stop = True
        self.t.join(1)
        self.pt.join(1)
        self.s.close()


class Client:
    """지사 client 대리. 고유 tag 를 실은 유효 HMAC 패킷을 보낸다."""
    def __init__(self, tag):
        self.tag = tag.encode().ljust(8, b'_')[:8]
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.bind(('127.0.0.1', 0))
        self.s.settimeout(0.5)
        self.keep = False
        self.t = None
        self.echo = 0

    def send(self, key=KEY):
        self.s.sendto(trr.make_obfs_quic_packet(key, b'x' * 40 + self.tag) , LISTEN)
        try:
            d, _ = self.s.recvfrom(4096)
            if self.tag in d:
                self.echo += 1
        except socket.timeout:
            pass

    def start_keepalive(self, interval=0.1):
        self.keep = True
        def loop():
            while self.keep:
                self.s.sendto(trr.make_obfs_quic_packet(KEY, b'x' * 40 + self.tag), LISTEN)
                time.sleep(interval)
        self.t = threading.Thread(target=loop, daemon=True)
        self.t.start()

    def stop_keepalive(self):
        self.keep = False
        if self.t:
            self.t.join(1)

    def close(self):
        self.stop_keepalive()
        self.s.close()


def start_relay(routes, log):
    args = [BIN, '-r', '-l', '%s:%d' % LISTEN, '--log-level', '4', '--report', '1']
    for r in routes:
        args += ['--route', r]
    p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    time.sleep(0.6)
    return p


def stop(p):
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(3)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def run_rc(routes, extra=None, timeout=3):
    args = [BIN, '-r', '-l', '%s:%d' % LISTEN] + (extra or [])
    for r in routes:
        args += ['--route', r]
    try:
        cp = subprocess.run(args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return cp.returncode, cp.stdout + cp.stderr
    except subprocess.TimeoutExpired as e:
        return None, (e.stdout or b'').decode(errors='replace') if isinstance(e.stdout, bytes) else (e.stdout or '')


def main():
    if not os.path.exists(BIN):
        print('BIN not found:', BIN)
        return 2
    print('BIN =', BIN)
    up = '%s:%d' % SINK
    tmp = tempfile.mkdtemp(prefix='mfports-')   # TMPDIR 을 따른다

    print('T1 파싱 거부 / route 간 중복')
    for spec_, why in [('ports 0', '0'), ('ports 70000', '범위 초과'), ('ports 21001,21001', '중복'),
                       ('ports 21001 ports 21002', '두 번'), ('ports 21000-21064', '65개'),
                       ('ports 21005-21001x', '숫자 아님'), ('ports ,21001', '빈 항목')]:
        rc, out = run_rc(['%s %s %s' % (KEY, up, spec_)])
        check('거부: %s' % why, rc not in (0, None), 'rc=%s %s' % (rc, out.strip().splitlines()[-1][:90] if out.strip() else ''))
    rc, out = run_rc(['%s %s ports 21000-21063' % (KEY, up)], timeout=1.5)
    check('64개는 허용(기동 유지)', rc is None, 'rc=%s' % rc)
    rc, out = run_rc(['%s %s ports %d,%d' % (KEY, up, P1, P2), '%s %s ports 21050,%d' % (KEY2, up, P2)])
    check('두 route 같은 포트 → 기동 거부 rc=1', rc == 1, 'rc=%s %s' % (rc, [l for l in out.splitlines() if 'route[' in l and 'source port' in l][:1]))

    sink = Sink(SINK)
    log = open(os.path.join(tmp, 'relay.log'), 'w+')
    relay = start_relay(['%s %s ports %d,%d' % (KEY, up, P1, P2)], log)
    try:
        print('T2 첫 세션 = 첫 포트')
        a = Client('A')
        a.send()
        a.send()
        check('A 출발 포트 = %d' % P1, sink.ports_for(a.tag) == {P1}, str(sink.ports_for(a.tag)))
        check('A 왕복', a.echo >= 1, 'echo=%d' % a.echo)
        a.start_keepalive()

        print('T3 둘째 세션 = 둘째 포트')
        b = Client('B')
        b.send()
        check('B 출발 포트 = %d' % P2, sink.ports_for(b.tag) == {P2}, str(sink.ports_for(b.tag)))
        b.start_keepalive()

        print('T4 풀 소진 → 커널 포트 + 경고')
        c = Client('C')
        c.send()
        pc = sink.ports_for(c.tag)
        check('C 는 커널 포트(풀 밖)', len(pc) == 1 and not (pc & {P1, P2}), str(pc))
        check('C 왕복', c.echo >= 1, 'echo=%d' % c.echo)
        time.sleep(1.2)
        log.flush(); log.seek(0); txt = log.read()
        check('경고 로그 "all in use"', 'all in use' in txt)
        check('보고 줄 fallback', 'fallback(kernel port)=1' in txt)

        print('T5 3초 무수신 세션 회수')
        a.stop_keepalive()
        time.sleep(3.5)
        d = Client('D')
        d.send()
        check('D 가 A 의 포트 %d 회수' % P1, sink.ports_for(d.tag) == {P1}, str(sink.ports_for(d.tag)))
        log.flush(); log.seek(0); txt = log.read()
        check('회수 로그', 'source port %d reclaimed' % P1 in txt)
        n_b_before = len([1 for _, p, dd in sink.seen if b.tag in dd])
        time.sleep(0.5)
        n_b_after = len([1 for _, p, dd in sink.seen if b.tag in dd])
        check('살아 있는 B 는 그대로 %d' % P2, n_b_after > n_b_before and sink.ports_for(b.tag) == {P2})
        b.stop_keepalive()

        print('T6 relay 재시작 → 즉시 첫 포트')
        stop(relay)
        relay = start_relay(['%s %s ports %d,%d' % (KEY, up, P1, P2)], log)
        e = Client('E')
        t0 = time.time()
        e.send()
        check('E 출발 포트 = %d (재시작 직후)' % P1, sink.ports_for(e.tag) == {P1},
              '%s %.2fs' % (sink.ports_for(e.tag), time.time() - t0))
        check('E 왕복', e.echo >= 1)
        stop(relay)

        print('T7 다른 프로세스가 첫 포트 점유 → 둘째 포트')
        hog = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        hog.bind(('127.0.0.1', P1))
        relay = start_relay(['%s %s ports %d,%d' % (KEY, up, P1, P2)], log)
        f = Client('F')
        f.send()
        check('F 출발 포트 = %d' % P2, sink.ports_for(f.tag) == {P2}, str(sink.ports_for(f.tag)))
        hog.close()
        stop(relay)

        print('T8 ports 없음 → 커널 포트')
        relay = start_relay(['%s %s' % (KEY, up)], log)
        g = Client('G')
        g.send()
        pg = sink.ports_for(g.tag)
        check('G 커널 포트', len(pg) == 1 and not (pg & {P1, P2}), str(pg))
        check('G 왕복', g.echo >= 1)
        stop(relay)
        relay = None
        for cl in (a, b, c, d, e, f, g):
            cl.close()
    finally:
        stop(relay)
        sink.close()

    print('T9 --check')
    conf = os.path.join(tmp, 'relay.conf')
    with open(conf, 'w') as fh:
        fh.write('mode = relay\nlisten = %s:%d\nroute = %s %s ports %d,40000\nroute = %s %s ports 21060,%d\n'
                 % (LISTEN[0], LISTEN[1], KEY, up, P1, KEY2, up, P1))
    os.chmod(conf, 0o600)
    cp = subprocess.run([BIN, '--config', conf, '--check'], capture_output=True, text=True, timeout=10)
    out = cp.stdout
    check('--check 표시 "ports %d,40000"' % P1, 'ports %d,40000' % P1 in out)
    check('--check 임의 범위 경고(40000)', 'port 40000 is in the kernel ephemeral range' in out)
    check('--check route 간 중복 오류', 'port %d is also in route' % P1 in out)
    check('--check rc=1', cp.returncode == 1, 'rc=%d' % cp.returncode)
    check('--check 출력에 키 평문 없음', KEY not in out and KEY2 not in out)

    npass = sum(1 for _, ok in results if ok)
    print('\n%d/%d 통과  (relay 로그 %s)' % (npass, len(results), os.path.join(tmp, 'relay.log')))
    return 0 if npass == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
