#!/usr/bin/env python3
"""릴레이 세션 idle 만료가 실제로 60초인지 검증.

RELAY_SESSION_TIMEOUT_MS(60000)는 ms인데 비교식에서 다시 1000을 곱해
실효 만료가 약 16.7시간이었다. 릴레이는 클라이언트 (src_ip, src_port)마다
upstream UDP 소켓 + ev_watcher 를 잡으므로, 만료가 동작하지 않으면 소스 포트가
계속 바뀌는 환경에서 FD 가 고갈된다.

방법: 서로 다른 소스 포트 N개로 1패킷씩 보내 세션 N개를 만든 뒤,
/proc/<pid>/fd 개수가 만료 시간 이후 실제로 줄어드는지 본다.
16.7시간 버그가 있으면 FD 는 끝까지 줄지 않는다.

usage: python3 test_relay_session_expiry.py [--wait 75]
"""
import os, socket, subprocess, sys, time

BIN  = os.path.join(os.path.dirname(__file__) or ".", "multi-fec")
N    = 12
WAIT = 75          # 60s 만료 + cleanup 타이머(10s) 여유

def fd_count(pid):
    try:
        return len(os.listdir("/proc/%d/fd" % pid))
    except OSError:
        return -1

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def main():
    wait = WAIT
    if "--wait" in sys.argv:
        wait = int(sys.argv[sys.argv.index("--wait") + 1])

    up_port, relay_port = free_port(), free_port()
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    up.bind(("127.0.0.1", up_port)); up.setblocking(False)

    p = subprocess.Popen([BIN, "-r", "-l", "127.0.0.1:%d" % relay_port,
                          "--upstream", "127.0.0.1:%d" % up_port,
                          "--disable-obfs", "--log-level", "4"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    base = fd_count(p.pid)

    socks = []
    for _ in range(N):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        s.sendto(b"x" * 100, ("127.0.0.1", relay_port))
        socks.append(s)
    time.sleep(1.5)
    peak = fd_count(p.pid)

    print("  기준 FD=%d, 세션 %d개 생성 후 FD=%d (+%d)" % (base, N, peak, peak - base))
    ok_created = peak - base >= N // 2
    print("  %s 세션별 upstream 소켓 생성됨" % ("✓" if ok_created else "✗"))

    print("  %d초 대기(만료 60s + cleanup 10s 주기)..." % wait, flush=True)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(2)
        try:
            while True: up.recvfrom(65535)
        except BlockingIOError:
            pass

    after = fd_count(p.pid)
    alive = p.poll() is None
    p.terminate()
    try: p.wait(timeout=3)
    except subprocess.TimeoutExpired: p.kill()
    for s in socks: s.close()
    up.close()

    print("  대기 후 FD=%d (피크 %d)" % (after, peak))
    ok_expired = after <= base + 2
    ok = ok_created and ok_expired and alive
    print("  %s 릴레이 생존" % ("✓" if alive else "✗"))
    print("  %s idle 세션 만료로 FD 회수 (기준 %d 이하 복귀)"
          % ("✓" if ok_expired else "✗", base + 2))
    print("결과: %s" % ("통과 ✓" if ok else "실패 ✗ — 만료가 동작하지 않음"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
