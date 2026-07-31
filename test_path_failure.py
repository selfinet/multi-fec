#!/usr/bin/env python3
"""경로 장애 시 멀티패스 거동 검증 — 절단 / 열화 / 지연차 (격리 netns, root 필요).

죽은 경로가 배제되지 않아 aggregate 가 트래픽 절반을 무기한 잃던 결함(CLAUDE.md §21)의
회귀 방지용. 수정 전에는 절단 시나리오에서 aggregate 유실이 37.7% 였다.

주의: `ip netns`/`tc` 를 쓰므로 root 권한이 필요하고, 격리된 netns 안에서만 동작하므로
운영 서비스에 영향이 없다. 단, 호스트에 vA/vB 인터페이스와 mfd netns 를 만들고 지운다.

usage:
  sudo python3 test_path_failure.py                 # 시나리오 전체
  sudo BIN=./multi-fec python3 test_path_failure.py --single aggregate 0 0 10 5000 200000

토폴로지:
  root ns                            netns mfd
   vA 10.210.1.1 ─ veth ─ 10.210.1.2 vAp    ← 항상 정상
   vB 10.210.2.1 ─ veth ─ 10.210.2.2 vBp    ← 손실/지연 주입, 중간 절단 가능

FEC 를 켠 상태(-f 20:5 --mode 1)로 측정하므로, 결과는 "FEC 통과 후 WG 가 볼 손실"이다.
FEC 그룹이 실제로 차려면 4000pps 이상이 필요하다(--fec-timeout 5ms 기준). 저레이트에서는
그룹당 복구 비율이 과대해져 보호가 비현실적으로 좋게 나온다.

--single 인자: <mode> <bloss%> <skew_ms> <kill_at_sec|0> [rate_pps] [count]
환경변수 RESTORE=<초> 를 주면 그 시각에 절단한 경로를 되살린다(복구 검증용).
"""
import os, socket, subprocess, sys, time, signal, threading

BIN = os.environ.get("BIN", "./multi-fec")
NS  = "mfd"
KEY = "modefail-key"
SP, WG, LP = 34443, 34444, 34445

# --single 실행에서만 채워진다 (전체 실행은 run_all 이 자식 프로세스를 띄운다)
mode = bloss = skew = killat = restoreat = rate = count = None

def parse_args():
    global mode, bloss, skew, killat, restoreat, rate, count
    mode   = sys.argv[1]
    bloss  = float(sys.argv[2])
    skew   = int(sys.argv[3])
    killat = float(sys.argv[4])
    restoreat = float(os.environ.get("RESTORE", "0"))
    rate   = int(sys.argv[5]) if len(sys.argv) > 5 else 1000
    count  = int(sys.argv[6]) if len(sys.argv) > 6 else 6000

def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)

def setup():
    teardown()
    sh("ip netns add %s" % NS)
    sh("ip netns exec %s ip link set lo up" % NS)
    for n, net in (("vA", "10.210.1"), ("vB", "10.210.2")):
        p = n + "p"
        sh("ip link add %s type veth peer name %s" % (n, p))
        sh("ip link set %s netns %s" % (p, NS))
        sh("ip addr add %s.1/24 dev %s" % (net, n)); sh("ip link set %s up" % n)
        sh("ip netns exec %s ip addr add %s.2/24 dev %s" % (NS, net, p))
        sh("ip netns exec %s ip link set %s up" % (NS, p))
    q = []
    if skew:  q.append("delay %dms" % skew)
    if bloss: q.append("loss %.2f%%" % bloss)
    if q:
        sh("tc qdisc add dev vB root netem %s" % " ".join(q))
        sh("ip netns exec %s tc qdisc add dev vBp root netem %s" % (NS, " ".join(q)))

def teardown():
    sh("pkill -9 -f 'path 10.210.1.1:10.210.1.2' 2>/dev/null")
    sh("ip netns pids %s 2>/dev/null | xargs -r kill -9" % NS)
    sh("ip netns del %s" % NS)
    sh("ip link del vA"); sh("ip link del vB")

def main():
    parse_args()
    setup()
    logs = []
    def spawn(cmd, tag):
        f = open("/tmp/mf_%s.log" % tag, "w"); logs.append(f)
        return subprocess.Popen(cmd, shell=True, stdout=f, stderr=subprocess.STDOUT)

    sink = (
        "import socket\n"
        "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\n"
        "s.bind(('127.0.0.1',%d))\n" % WG +
        "s.settimeout(8)\n"
        "o=open('/tmp/mf_order.txt','w')\n"
        "while True:\n"
        "    try: d,_=s.recvfrom(65535)\n"
        "    except socket.timeout: break\n"
        "    if d[:3]==b'SEQ': o.write(d[3:12].decode()+'\\n')\n"
        "o.close()\n")
    sk = spawn("ip netns exec %s python3 -c \"%s\"" % (NS, sink.replace('"', '\\"')), "sink")
    time.sleep(0.4)
    fec = "-f 20:5 --mode 1 --fec-timeout 5 --mtu 1350"
    srv = spawn("ip netns exec %s %s -s -l 0.0.0.0:%d --wg 127.0.0.1:%d -k %s "
                "--multipath-mode %s %s --log-level 4" % (NS, BIN, SP, WG, KEY, mode, fec), "srv")
    time.sleep(0.7)
    cli = spawn("%s -c -l 127.0.0.1:%d --path 10.210.1.1:10.210.1.2:%d "
                "--path 10.210.2.1:10.210.2.2:%d -k %s --multipath-mode %s %s --log-level 4"
                % (BIN, LP, SP, SP, KEY, mode, fec), "cli")
    time.sleep(3.5)

    killed = [False]
    def killer():
        time.sleep(killat)
        sh("tc qdisc replace dev vB root netem loss 100%")
        sh("ip netns exec %s tc qdisc replace dev vBp root netem loss 100%%" % NS)
        killed[0] = True
        if restoreat > killat:
            time.sleep(restoreat - killat)
            sh("tc qdisc del dev vB root")
            sh("ip netns exec %s tc qdisc del dev vBp root" % NS)
    if killat > 0:
        threading.Thread(target=killer, daemon=True).start()

    b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    iv = 1.0 / rate; nxt = time.time()
    for i in range(1, count + 1):
        b.sendto(b"SEQ%09d" % i + b"x" * 200, ("127.0.0.1", LP))
        nxt += iv
        d = nxt - time.time()
        if d > 0: time.sleep(d)
    time.sleep(9)

    for p in (cli, srv, sk): p.send_signal(signal.SIGTERM)
    time.sleep(0.5)
    for p in (cli, srv, sk):
        if p.poll() is None: p.kill()
    b.close()
    for f in logs:
        try: f.close()
        except Exception: pass
    try: seqs = [int(x) for x in open("/tmp/mf_order.txt") if x.strip()]
    except OSError: seqs = []
    teardown()

    uniq = sorted(set(seqs))
    ooo = 0; depth = 0; hi = 0
    for s in seqs:
        if s < hi: ooo += 1; depth = max(depth, hi - s)
        else: hi = s
    # 절단 이후 구간만 따로
    print("mode=%-9s B손실=%-5.1f%% skew=%-4dms 절단=%ss rate=%dpps" %
          (mode, bloss, skew, killat if killat else "-", rate))
    print("   고유전달 %d/%d (%.2f%%)  유실 %d (%.2f%%)  중복 %d  재정렬 %d(깊이%d)" %
          (len(uniq), count, 100.0*len(uniq)/count, count-len(uniq),
           100.0*(count-len(uniq))/count, len(seqs)-len(uniq), ooo, depth))

SCENARIOS = [
    # (mode, B손실%, skew_ms, 절단초, rate, count, 유실 상한%)
    ("duplicate", 0,  0,  0, 5000,  40000, 1.0),
    ("aggregate", 0,  0,  0, 5000,  40000, 1.0),
    ("duplicate", 60, 0,  0, 5000,  40000, 2.0),
    ("aggregate", 60, 0,  0, 5000,  40000, 2.0),
    ("duplicate", 0,  30, 0, 5000,  40000, 1.0),
    ("aggregate", 0,  30, 0, 5000,  40000, 1.0),
    ("duplicate", 0,  0, 10, 5000, 200000, 1.0),
    ("aggregate", 0,  0, 10, 5000, 200000, 5.0),   # 검출 ~1s 분의 유실은 정상
]

def run_all():
    npass = nfail = 0
    print("=" * 74)
    print("경로 장애 시 멀티패스 거동 (기준: 각 시나리오 유실 상한 이하)")
    print("=" * 74)
    for mode_, bl, sk, ka, rt, cn, limit in SCENARIOS:
        r = subprocess.run([sys.executable, __file__, "--single",
                            mode_, str(bl), str(sk), str(ka), str(rt), str(cn)],
                           capture_output=True, text=True)
        lost = None
        for line in r.stdout.splitlines():
            if "유실" in line:
                try: lost = float(line.split("유실")[1].split("(")[1].split("%")[0])
                except Exception: pass
        ok = lost is not None and lost <= limit
        npass, nfail = npass + ok, nfail + (not ok)
        print("  %s %-10s B손실%-3d skew%-3d 절단%-3s → 유실 %s%% (상한 %.1f%%)"
              % ("✓" if ok else "✗", mode_, bl, sk, ka if ka else "-",
                 "%.2f" % lost if lost is not None else "?", limit))
    print("=" * 74)
    print("결과: %d 통과 / %d 실패" % (npass, nfail))
    return 0 if nfail == 0 else 1

if __name__ == "__main__":
    if "--single" in sys.argv:
        sys.argv.remove("--single")
        main()
    else:
        sys.exit(run_all())
