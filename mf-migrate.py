#!/usr/bin/env python3
"""mf-migrate.py — 1.3.x 식 유닛(인자 펼침 + EnvironmentFile)을 1.4.0 --config 형식으로 변환한다 (2026-10-19)

  mf-migrate.py multi-fec-server-dj08                 # systemctl cat 으로 유닛을 읽는다
  mf-migrate.py multi-fec-relay --instance relay-sk   # 인스턴스 이름 지정 (기본: 유닛 이름에서 multi-fec- 를 뗀 것)
  mf-migrate.py --unit-file ./x.service --env-dir ./  # 파일에서 직접 (오프라인 시험)

만드는 것 (기본 /etc/multi-fec/instances/, 전부 600, 이미 있으면 --force 없이는 덮어쓰지 않는다):
  <instance>.conf     --config 형식. 기존 인자를 전부 명시값으로 옮긴다(기본값에 기대지 않는다)
  <instance>.routes   relay 의 --route 들 (route-file). 원래 환경변수 이름과 주석을 주석으로 남긴다

그다음 1.4.0 바이너리로 `--config <instance>.conf --check` 를 돌리고, 새 설정의 키 지문(kf:)을
실행 중인 유닛 로그의 지문과 대조한다(1.4.0 은 `key kf:…`, relay 는 1.3.x 부터 `route[n] key=kf:…`).

기존 유닛·환경변수 파일은 건드리지 않는다 — 전환(disable/enable)은 사람이 한다. 키는 어디에도 출력하지 않는다.
해석 규칙은 systemd 와 같게: `${VAR}` 는 한 단어 그대로, 단독 `$VAR` 는 공백으로 쪼갠다, EnvironmentFile 은
줄 끝 주석을 값에 남긴다(→ path/route 값에서만 1.4.0 과 같게 `#` 이후를 버린다).
"""
import argparse, os, re, shlex, subprocess, sys

OUT_DIR = '/etc/multi-fec/instances'

# CLI 옵션 → 설정 이름. kind: v=값, r=반복, f=플래그
OPTS = {
    '-l': ('listen', 'v'), '-k': ('key', 'v'), '--key': ('key', 'v'), '--key-file': ('key-file', 'v'),
    '-f': ('fec', 'v'), '--mode': ('fec-mode', 'v'), '--fec-mode': ('fec-mode', 'v'),
    '--path': ('path', 'r'), '--route': ('route', 'r'), '--route-file': ('route-file', 'v'),
    '--accept-local': ('accept-local', 'r'), '--wg': ('wg', 'v'), '--upstream': ('upstream', 'v'),
    '--upstream-local': ('upstream-local', 'v'), '--multipath-mode': ('multipath-mode', 'v'),
    '--dup-factor': ('dup-factor', 'v'), '--fec-timeout': ('fec-timeout', 'v'), '--mtu': ('mtu', 'v'),
    '-q': ('queue-len', 'v'), '--queue-len': ('queue-len', 'v'), '--decode-buf': ('decode-buf', 'v'),
    '--disable-fec': ('disable-fec', 'f'), '--sock-buf': ('sock-buf', 'v'), '-j': ('jitter', 'v'),
    '--jitter': ('jitter', 'v'), '--random-drop': ('random-drop', 'v'),
    '--disable-checksum': ('disable-checksum', 'f'), '--fifo': ('fifo', 'v'), '--report': ('report', 'v'),
    '--log-level': ('log-level', 'v'), '--log-position': ('log-position', 'f'),
    '--disable-color': ('disable-color', 'f'), '--enable-color': ('enable-color', 'f'),
    '--obfs-mode': ('obfs-mode', 'v'), '--decoy': ('decoy', 'v'), '--disable-obfs': ('disable-obfs', 'f'),
    '--port-hop-interval': ('port-hop-interval', 'v'), '--auth-interval': ('auth-interval', 'v'),
}
MODES = {'-c': 'client', '-s': 'server', '-r': 'relay'}


def die(msg):
    sys.exit('mf-migrate: ' + msg)


def strip_comment(v):
    """1.4.0 의 path/route 처리와 같게: 공백 뒤 '#' 부터 버린다."""
    m = re.search(r'\s#', v)
    return v[:m.start()].rstrip() if m else v


def read_env(path, env, notes, missing_ok):
    """systemd EnvironmentFile 해석. 직전 주석 줄을 변수별로 기억한다(routes 파일 주석용)."""
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        if missing_ok:
            return
        die(f'{path}: {e.strerror}')
    pending = []
    for raw in lines:
        s = raw.strip()
        if not s:
            pending = []
            continue
        if s[0] in '#;':
            c = s.lstrip('#; ').strip()
            if c:
                pending.append(c)
            continue
        if '=' not in s:
            continue
        k, v = s.split('=', 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
            v = v[1:-1]
        env[k] = v
        notes[k] = pending
        pending = []


def unit_text(args):
    if args.unit_file:
        return open(args.unit_file).read()
    r = subprocess.run(['systemctl', 'cat', args.unit], capture_output=True, text=True)
    if r.returncode != 0:
        die(f'systemctl cat {args.unit}: {r.stderr.strip()}')
    return r.stdout


def parse_unit(text):
    """마지막으로 유효한 ExecStart (drop-in 의 빈 ExecStart= 리셋 반영) 와 환경."""
    joined = re.sub(r'\\\n', ' ', text)
    exec_start, env_files, env_inline = None, [], []
    for line in joined.splitlines():
        s = line.strip()
        if s.startswith('ExecStart='):
            v = s[len('ExecStart='):].strip()
            exec_start = v or None
        elif s.startswith('EnvironmentFile='):
            env_files.append(s[len('EnvironmentFile='):].strip())
        elif s.startswith('Environment='):
            env_inline.append(s[len('Environment='):].strip())
    if not exec_start:
        die('ExecStart 를 찾지 못했다')
    return exec_start.lstrip('@-:+!'), env_files, env_inline


def expand(cmd, env, warn):
    """systemd 식 단어 분리·치환: 단독 $VAR 는 쪼개고, ${VAR} 는 그대로 한 단어 안에 넣는다."""
    out = []
    for word in shlex.split(cmd, posix=True):
        m = re.fullmatch(r'\$([A-Za-z_][A-Za-z0-9_]*)', word)
        if m:
            if m.group(1) not in env:
                warn.append(f'${m.group(1)} 미정의 — 빈 값')
            out.extend(env.get(m.group(1), '').split())
            continue

        def sub(mm):
            n = mm.group(1) or mm.group(2)
            if n not in env:
                warn.append(f'${{{n}}} 미정의 — 빈 값')
            return env.get(n, '')
        out.append(re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', sub, word))
    return out


def to_settings(argv):
    mode, items = None, []
    i = 1
    while i < len(argv):
        a = argv[i]
        name_val = a.split('=', 1) if a.startswith('--') and '=' in a else (a, None)
        a0 = name_val[0]
        if a0 in MODES:
            mode = MODES[a0]; i += 1; continue
        if a0 not in OPTS:
            die(f'변환할 수 없는 인자: {a0} (손으로 옮길 것)')
        name, kind = OPTS[a0]
        if kind == 'f':
            items.append((name, 'yes')); i += 1; continue
        if name_val[1] is not None:
            val = name_val[1]; i += 1
        else:
            if i + 1 >= len(argv):
                die(f'{a0} 에 값이 없다')
            val = argv[i + 1]; i += 2
        items.append((name, val))
    if not mode:
        die('-c/-s/-r 이 없다')
    return mode, items


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('unit', nargs='?', help='systemd 유닛 이름 (예: multi-fec-server-dj08)')
    ap.add_argument('--unit-file', help='유닛 파일을 직접 읽는다 (오프라인)')
    ap.add_argument('--env-dir', help='EnvironmentFile 경로의 디렉터리를 이것으로 바꿔 읽는다 (오프라인 시험)')
    ap.add_argument('--instance', help='인스턴스 이름 (기본: 유닛 이름에서 multi-fec- 를 뗀 것)')
    ap.add_argument('--out', default=OUT_DIR)
    ap.add_argument('--bin', help='--check 에 쓸 1.4.0 바이너리 (기본: ExecStart 바이너리, 1.4 미만이면 그 옆 .v1.4.0)')
    ap.add_argument('--force', action='store_true', help='출력 파일이 있으면 덮어쓴다')
    args = ap.parse_args()
    if not args.unit and not args.unit_file:
        ap.error('유닛 이름 또는 --unit-file')

    uname = args.unit or os.path.basename(args.unit_file)
    uname = re.sub(r'\.service$', '', uname)
    inst = args.instance or re.sub(r'^multi-fec-', '', uname)
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+', inst):
        die(f'인스턴스 이름이 이상하다: {inst}')

    cmd, env_files, env_inline = parse_unit(unit_text(args))
    env, notes, warn = {}, {}, []
    for ef in env_files:
        miss = ef.startswith('-')
        p = ef.lstrip('-')
        if args.env_dir:
            p = os.path.join(args.env_dir, os.path.basename(p))
        read_env(p, env, notes, miss)
    for e in env_inline:
        for kv in shlex.split(e):
            if '=' in kv:
                k, v = kv.split('=', 1); env[k] = v
    argv = expand(cmd, env, warn)
    binpath = argv[0]
    mode, items = to_settings(argv)

    conf_path = os.path.join(args.out, inst + '.conf')
    routes_path = os.path.join(args.out, inst + '.routes')
    for p in (conf_path, routes_path):
        if os.path.exists(p) and not args.force:
            die(f'{p} 가 이미 있다 — 덮어쓰려면 --force')

    lines = [f'# mf-migrate.py — {uname}.service 에서 변환 (원본 유닛·환경변수 파일은 그대로 둔다)',
             f'mode = {mode}']
    routes, notes_out = [], []
    for name, val in items:
        if name in ('path', 'route'):
            val = strip_comment(val)
        if name == 'route':
            routes.append(val); continue
        if name == 'fifo' and mode == 'relay':
            notes_out.append('relay 의 --fifo 는 쓰이지 않아(1.3.6+ 경고) 옮기지 않았다'); continue
        if name == 'listen' and mode == 'client':
            name = 'wg'          # client 의 -l = WireGuard 쪽 로컬 리슨 (설정 파일에서는 wg)
        lines.append(f'{name} = {val}')
    if routes:
        lines.insert(2, f'route-file = {routes_path}')
    if any(n == 'fifo' for n, _ in items) and mode != 'relay':
        notes_out.append('fifo 는 원래 경로를 그대로 옮겼다(1.4.0 기본은 /run/multi-fec/<instance>.fifo)')

    # 주석 달린 routes 파일: 원래 환경변수 이름과 그 위 주석 줄을 남긴다
    route_lines = []
    raw_routes = re.findall(r'--route\s+"([^"]*)"|--route\s+(\S+)', cmd)
    for (q, u), val in zip(raw_routes, routes):
        tmpl = q or u
        names = re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', tmpl)
        for n in names:
            for c in notes.get(n, []):
                route_lines.append('# ' + c)
        route_lines.append(f'# ({" ".join(names) or "직접 값"})')
        route_lines.append(val)
    if routes and len(raw_routes) != len(routes):
        route_lines = [r for r in routes]   # 짝을 못 맞추면 주석 없이

    os.makedirs(args.out, mode=0o700, exist_ok=True)
    old = os.umask(0o077)
    try:
        with open(conf_path, 'w') as f:
            f.write('\n'.join(lines) + '\n')
        if routes:
            with open(routes_path, 'w') as f:
                f.write('# mf-migrate.py — <키> <upstream>  (키가 들어 있다: 600)\n' + '\n'.join(route_lines) + '\n')
    finally:
        os.umask(old)

    print(f'== {uname}.service → 인스턴스 {inst}  (mode {mode})')
    print(f'   {conf_path}' + (f'\n   {routes_path}  ({len(routes)} routes)' if routes else ''))
    for w in warn + notes_out:
        print('   참고:', w)
    print('--- 생성된 설정 (키 가림)')
    for l in lines:
        print('   ' + (re.sub(r'^(key\s*=\s*).*', r'\1<키>', l)))

    # --check (1.4.0 바이너리)
    cands = [args.bin] if args.bin else [binpath, binpath + '.v1.4.0', '/usr/sbin/multi-fec-dist.v1.4.0']
    chk = None
    for b in cands:
        if b and os.path.exists(b):
            v = subprocess.run([b, '--version'], capture_output=True, text=True).stdout
            if re.search(r'multi-fec 1\.(4|[5-9])|multi-fec [2-9]\.', v):
                chk = b; break
    if not chk:
        print('--- --check 생략: 1.4.0 바이너리를 못 찾았다 (--bin 으로 지정)')
        return
    r = subprocess.run([chk, '--config', conf_path, '--check'], capture_output=True, text=True)
    out = r.stdout
    print(f'--- {chk} --config … --check')
    for l in out.splitlines():
        if l.startswith(('  [', 'result')):
            # --check 는 포트를 쥔 프로세스의 명령줄을 보여 준다. 그 프로세스가 1.3.x 면 키가 가려져 있지 않다
            # (1.4.0 은 argv 를 * 로 덮는다) — 여기서 다시 가린다.
            l = re.sub(r'(-k|--key|--route)\s+"?[^\s"*]+', r'\1 <키>', l)
            print(' ' + l)
    new_kf = re.findall(r'kf:[0-9a-f]{8}', out)

    # 실행 중인 유닛 로그의 지문과 대조
    if args.unit:
        j = subprocess.run(['journalctl', '-u', args.unit, '-o', 'cat', '--no-pager', '-n', '400'],
                           capture_output=True, text=True).stdout
        j = re.sub(r'\x1b\[[0-9;]*m', '', j)
        if mode == 'relay' and routes:
            run_kf = re.findall(r'route\[\d+\] key=(kf:[0-9a-f]{8})', j)
            run_kf = run_kf[-len(routes):] if routes else []
            new_routes_kf = [k for k in new_kf][:len(routes)]
            ok = bool(run_kf) and sorted(run_kf) == sorted(new_routes_kf)
            print(f'--- 지문 대조 (route): 실행 중 {run_kf or "로그에 없음"}  /  새 설정 {new_routes_kf}  →  '
                  + ('일치' if ok else '확인 필요'))
        else:
            run_kf = re.findall(r'key (kf:[0-9a-f]{8}) from', j)   # 1.4.0 이 남긴다 (relay 단일 키 포함)
            want = run_kf[-1] if run_kf else None
            got = new_kf[0] if new_kf else None
            print(f'--- 지문 대조 (key): 실행 중 {want or "로그에 없음 (1.3.x 는 key 지문을 남기지 않는다 — relay route[n] 지문과 대조)"}'
                  f'  /  새 설정 {got}  →  ' + ('일치' if want and want == got else '확인 필요'))
    print('--- 다음 단계: 위 [ERR] 가 "실행 중 기존 유닛의 포트 점유" 하나뿐인지 확인 →'
          f' systemctl disable --now {uname} && systemctl enable --now multi-fec@{inst}')


if __name__ == '__main__':
    main()
