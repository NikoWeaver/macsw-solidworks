#!/usr/bin/python3 -I
"""startbench.py <label> [KEY=VALUE ...]

One timed SOLIDWORKS start in a clone bottle (STARTBENCH_PREFIX, default bottle-perf2; never the real bottle), with MacSW's
SOLIDWORKS launch environment (WineService.environment(solidWorks: true)), like
tools/sw_launch_experiment.sh, but polled every 0.25 s from macOS.

Special KEY=VALUE (not exported): RUNTIME=<wine tree> (default build.nosync/startup/rt-base),
HOLD=<s> after the main window (default 8), MAXWAIT=<s> (default 240), UNSET=<VAR> (repeatable),
SAMPLE=<s> (run /usr/bin/sample on SLDWORKS.exe for <s> s from its creation), NOCLOSE=1 (leave running).
Any other KEY=VALUE goes into the Wine environment.

The clone is not activated: the "SOLIDWORKS Product Activation" (swactwiz /expirycheck) dialog is
answered "activate later" with wtool after checking the radio states; the time it is on screen
(appear -> Finish posted) is recorded and subtracted as wiz_s.

Events: launch, proc (SLDWORKS.exe exists), splash, wiz, wiz_done, main (main frame window), and
cpu samples. Output: build.nosync/startup/runs/<label>-<hhmmss>/{events.tsv,cpu.tsv,wine.log,result.json}
and one line in build.nosync/startup/starts.tsv.
"""
import json, os, re, subprocess, sys, time

H = os.environ.get('MACSW_WORK')  # the folder that holds build.nosync; no default
if not H:
    sys.exit('set MACSW_WORK to the folder that holds build.nosync (no default)')
S = os.environ.get('STARTBENCH_DIR', H + '/build.nosync/startup')
PREFIX = os.environ.get('STARTBENCH_PREFIX', os.path.expanduser('~/Library/Application Support/MacSW/bottle-perf2'))
WINS = os.environ.get('STARTBENCH_WINS', H + '/build.nosync/firstrun/wins')      # CGWindowList lister (wins.swift)
WTOOL = os.environ.get('STARTBENCH_WTOOL', H + '/build.nosync/firstrun/wtool.exe')
# This script kills every Wine process of PREFIX; never point it at the user's bottle.
if os.path.realpath(PREFIX) == os.path.realpath(os.path.expanduser('~/Library/Application Support/MacSW/bottle')):
    sys.exit('refusing to run on the real MacSW bottle')
VC = 'concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids vcruntime140 vcruntime140_1 vcomp140 mfc140u'.split()
SWEXE = PREFIX + '/drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe'

if len(sys.argv) < 2 or '=' in sys.argv[1]:
    print(__doc__); sys.exit(2)
label = sys.argv[1]
opts = {'RUNTIME': S + '/rt-base', 'HOLD': '8', 'MAXWAIT': '240', 'SAMPLE': '0', 'NOCLOSE': '0', 'SINT': '10', 'SSERVER': '0'}
over, unsets = {}, []
for a in sys.argv[2:]:
    k, _, v = a.partition('=')
    if k in opts: opts[k] = v
    elif k == 'UNSET': unsets.append(v)
    else: over[k] = v
RT = opts['RUNTIME'].rstrip('/')
LOADER = RT + '/lib/wine/x86_64-unix/MacSW'
SERVER = RT + '/bin/wineserver'

env = dict(os.environ)
for k in ['WINEDLLPATH', 'CX_ROOT', 'CX_BOTTLE', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH',
          'WINEDLLOVERRIDES', 'MONO_ENV_OPTIONS', 'MACSW_WINELOADER', 'MACSW_APP_NAME', 'WINEMSYNC']:
    env.pop(k, None)
env.update({'WINEPREFIX': PREFIX, 'WINELOADER': LOADER, 'WINESERVER': SERVER,
            'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8', 'WINEDEBUG': '-all', 'WINE_MONO_AOT': 'none',
            'MACSW_CROSS_PROCESS_SURFACES': '1',
            'WINEDLLOVERRIDES': ';'.join(['atiadlxx=d'] + [l + '=n,b' for l in VC])})
env.update(over)
for u in unsets: env.pop(u, None)
# helper processes (wtool) must not inherit trace channels
henv = dict(env); henv['WINEDEBUG'] = '-all'

OUT = '%s/runs/%s-%s' % (S, label, time.strftime('%H%M%S'))
os.makedirs(OUT, exist_ok=True)
with open(OUT + '/env.txt', 'w') as f:
    f.write('# runtime %s\n' % RT)
    for k in sorted(set(over) | {'WINEPREFIX', 'WINELOADER', 'WINEDEBUG', 'WINE_MONO_AOT', 'WINEDLLOVERRIDES'}):
        f.write('%s=%s\n' % (k, env.get(k, '<unset>')))
    for u in unsets: f.write('UNSET %s\n' % u)

T0 = None
ev = open(OUT + '/events.tsv', 'w')
def el(): return time.time() - T0
def event(name, detail=''):
    ev.write('%.2f\t%s\t%s\n' % (el(), name, detail)); ev.flush()

_member = {}
_st = os.stat(PREFIX)
SERVER_DIR = '/server-%x-%x/' % (_st.st_dev, _st.st_ino)

def _is_mine(pid, c, line):
    if re.match(r'^\S*/bin/wineserver', c) or re.match(r'^\S*/lib/wine/x86_64-unix/MacSW( |$)', c):
        return ('WINEPREFIX=' + PREFIX + ' ') in line + ' '
    if c.startswith(PREFIX + '/drive_c/'): return True
    if re.match(r'^[A-Za-z]:\\', c):
        r = subprocess.run(['lsof', '-p', str(pid), '-Fn'], capture_output=True, text=True).stdout
        return (SERVER_DIR in r) or ('\nn' + PREFIX + '/') in r
    return False

def bottle_procs():
    """[(pid, cputime_s, command)] of the Wine processes of PREFIX (wineserver/loader by their exact
    WINEPREFIX; Windows processes by their open files: the prefix's server directory or files in it)."""
    r = subprocess.run(['ps', '-axwwE', '-o', 'pid=,time=,command='], capture_output=True, text=True).stdout
    out = []
    for line in r.splitlines():
        m = re.match(r'\s*(\d+)\s+(\S+)\s+(.*)', line)
        if not m: continue
        pid, t, c = int(m.group(1)), m.group(2), m.group(3)
        if pid == os.getpid(): continue
        if not (re.match(r'^\S*/bin/wineserver', c) or re.match(r'^\S*/lib/wine/x86_64-unix/MacSW( |$)', c)
                or re.match(r'^[A-Za-z]:\\', c) or c.startswith(PREFIX + '/drive_c/')):
            continue
        key = (pid, c[:200])
        if key not in _member: _member[key] = _is_mine(pid, c, line)
        if not _member[key]: continue
        secs = 0.0
        for p in t.split(':'): secs = secs * 60 + float(p)
        out.append((pid, secs, c))
    return out

def is_sw(c): return re.search(r'[\\/]sldworks\.exe(\s|$)', c.lower()) is not None

def wins():
    r = subprocess.run([WINS], capture_output=True, text=True).stdout
    res = []
    for line in r.splitlines():
        m = re.match(r'id=(\d+) pid=(\d+) layer=(-?\d+) owner="([^"]*)" name="(.*)" bounds=[0-9.-]+,[0-9.-]+,([0-9.]+),([0-9.]+)', line)
        if m: res.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(5), float(m.group(6)), float(m.group(7))))
    return res

def wtool(*args, timeout=40):
    try:
        r = subprocess.run([LOADER, WTOOL] + list(args), capture_output=True, text=True, env=henv, timeout=timeout,
                           cwd=S)
        return r.stdout.replace('\r', '')
    except subprocess.TimeoutExpired:
        return ''

def parse_wnd(line):
    m = re.match(r'\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]+) pid=(\d+) id=(-?\d+) vis=(\d) en=(\d) cls="([^"]*)" text="(.*)" rect=', line)
    if not m: return None
    ck = re.search(r' check=(-?\d+)', line)
    return {'h': m.group(1), 'pid': int(m.group(2)), 'vis': m.group(4) == '1', 'cls': m.group(6), 'text': m.group(7),
            'check': int(ck.group(1)) if ck else None}

def answer_wizard():
    """Select 'activate later' and post Finish. Returns a note; never chooses 'now'."""
    top = None
    for _ in range(20):
        for line in wtool('list').splitlines():
            w = parse_wnd(line)
            if w and w['text'] == 'SOLIDWORKS Product Activation' and w['vis']: top = w; break
        if top: break
        time.sleep(0.5)
    if not top: return 'wizard hwnd not found'
    kids = [parse_wnd(l) for l in wtool('dump', top['h']).splitlines()]
    kids = [k for k in kids if k]
    now = [k for k in kids if k['cls'].lower() == 'button' and 'activate my SOLIDWORKS product now' in k['text']]
    later = [k for k in kids if k['cls'].lower() == 'button' and 'activate my SOLIDWORKS product later' in k['text']]
    if len(now) != 1 or len(later) != 1: return 'radios not found (now=%d later=%d)' % (len(now), len(later))
    if later[0]['check'] != 1:
        wtool('click', later[0]['h'])
    cn = wtool('check', now[0]['h']).strip(); cl = wtool('check', later[0]['h']).strip()
    if cn != 'check=0' or cl != 'check=1': return 'radio state wrong after click: now %s later %s' % (cn, cl)
    kids = [parse_wnd(l) for l in wtool('dump', top['h']).splitlines()]
    fin = [k for k in kids if k and k['cls'].lower() == 'button' and k['text'].replace('&', '') == 'Finish' and k['vis']]
    if len(fin) != 1: return 'Finish button not found'
    wtool('pclick', fin[0]['h'])
    return 'later+finish'

def kill_bottle():
    for _ in range(2):
        subprocess.run([SERVER, '-k'], env=henv, capture_output=True, timeout=30)
        for _ in range(30):
            if not bottle_procs(): return True
            time.sleep(0.5)
    left = [p for p, _, _ in bottle_procs()]
    for p in left:
        try: os.kill(p, 9)
        except OSError: pass
    time.sleep(1)
    return not bottle_procs()

# ---- start ----
if bottle_procs():
    if not kill_bottle(): print('bottle busy'); sys.exit(4)
load0 = os.getloadavg()[0]
T0 = time.time()
log = open(OUT + '/wine.log', 'w')
if over.get('TSPIPE') == '1':
    import threading
    proc = subprocess.Popen([LOADER, SWEXE], env=env, cwd=os.path.dirname(SWEXE), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    def _pump(src, dst, t0):
        for line in iter(src.readline, b''):
            dst.write('%.4f %s' % (time.time() - t0, line.decode('utf-8', 'replace')))
        dst.flush()
    pump = threading.Thread(target=_pump, args=(proc.stdout, log, T0), daemon=True); pump.start()
else:
    proc = subprocess.Popen([LOADER, SWEXE], env=env, cwd=os.path.dirname(SWEXE), stdout=log, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL)
event('launch', 'pid=%d load1=%.1f' % (proc.pid, load0))
cpu = open(OUT + '/cpu.tsv', 'w'); cpu.write('t\tsw_cpu\tall_cpu\tnprocs\n')
thr = open(OUT + '/threads.tsv', 'w')
def poll_threads():
    if not swpid: return
    r = subprocess.run(['ps', '-M', '-p', str(swpid)], capture_output=True, text=True).stdout.splitlines()[1:]
    row = []
    for i, line in enumerate(r):
        f = line.split()
        # first line has USER PID TT %CPU STAT PRI STIME UTIME CMD; others: PID %CPU STAT PRI STIME UTIME
        if i == 0: f = f[3:9]
        else: f = f[1:6]
        if len(f) < 5: continue
        pri, st, ut = f[2], f[3], f[4]
        def secs(x):
            v = 0.0
            for q in x.split(':'): v = v * 60 + float(q)
            return v
        try: row.append('%d:%s:%s:%.2f' % (i, f[1], pri, secs(st) + secs(ut)))
        except ValueError: pass
    thr.write('%.2f\t%s\n' % (el(), ' '.join(row))); thr.flush()
t = {}; swpid = None; wiz_note = ''; wiz_s = 0.0; main = None; sampler = None
seen = set(); maxwait = float(opts['MAXWAIT']); result = 'TIMEOUT'
while el() < maxwait:
    time.sleep(0.25)
    ps = bottle_procs()
    sw = [p for p in ps if is_sw(p[2])]
    if sw and swpid is None:
        swpid = sw[0][0]; t['proc'] = el(); event('proc', 'pid=%d' % swpid)
        if float(opts['SAMPLE']) > 0:
            sampler = subprocess.Popen(['/usr/bin/sample', str(swpid), opts['SAMPLE'], opts['SINT'], '-mayDie', '-file',
                                        OUT + '/sample.txt'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if opts['SSERVER'] == '1':
                srv = [p[0] for p in ps if re.match(r'^\S*/bin/wineserver', p[2])]
                if srv:
                    sampler2 = subprocess.Popen(['/usr/bin/sample', str(srv[0]), opts['SAMPLE'], opts['SINT'], '-mayDie',
                                                 '-file', OUT + '/sample-server.txt'], stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL)
    poll_threads()
    swcpu = sum(p[1] for p in ps if swpid and p[0] == swpid)
    cpu.write('%.2f\t%.2f\t%.2f\t%d\n' % (el(), swcpu, sum(p[1] for p in ps), len(ps)))
    for c in ps:
        if c[0] not in seen:
            seen.add(c[0]); event('newproc', '%d %s' % (c[0], c[2][:120]))
    if swpid and not any(p[0] == swpid for p in ps):
        event('sw_exited'); result = 'EXITED'; break
    mine = {p[0] for p in ps}
    for (wid, pid, layer, name, w, h) in wins():
        if layer != 0 or pid not in mine: continue
        if ('w', wid) not in seen:
            seen.add(('w', wid)); event('window', 'id=%d pid=%d %dx%d "%s"' % (wid, pid, w, h, name))
            if name not in ('splash', 'SOLIDWORKS Product Activation') and not (name.startswith('SOLIDWORKS') and len(name) > 30):
                subprocess.run(['screencapture', '-x', '-l', str(wid), OUT + '/window-%d.png' % wid])
        if name == 'splash' and 'splash' not in t: t['splash'] = el(); event('splash')
        if name == 'SOLIDWORKS Design Error Report':
            result = 'CRASH'; event('crash_reporter', 'pid=%d' % pid)
        if name == 'SOLIDWORKS Product Activation' and 'wiz' not in t:
            t['wiz'] = el(); event('wiz')
            wiz_note = answer_wizard(); t['wiz_done'] = el(); wiz_s = t['wiz_done'] - t['wiz']
            event('wiz_done', wiz_note)
            if wiz_note != 'later+finish':
                subprocess.run(['screencapture', '-x', '-l', str(wid), OUT + '/wizard-%d.png' % wid])
            if wiz_note != 'later+finish': result = 'WIZARD'; break
        # main frame: the long product title (window bounds can be scaled by the window server)
        if (pid == swpid and name.startswith('SOLIDWORKS') and name != 'SOLIDWORKS Product Activation'
                and len(name) > 30 and 'main' not in t):
            t['main'] = el(); main = name; main_wid = wid; event('main', name)
            # which images does Rosetta serve from its ahead-of-time cache?
            lo = subprocess.run(['lsof', '-p', str(swpid), '-Fn'], capture_output=True, text=True).stdout
            with open(OUT + '/aot.txt', 'w') as f:
                f.write('\n'.join(l[1:] for l in lo.splitlines() if l.startswith('n') and l.endswith('.aot')) + '\n')
            for q in ps:
                kind = 'SLDWORKS.exe' if is_sw(q[2]) else ('wineserver' if re.match(r'^\S*/bin/wineserver', q[2]) else q[2][:90])
                event('cpu_at_main', '%d %.2f %s' % (q[0], q[1], kind))
    if result in ('CRASH', 'WIZARD'): break
    if 'main' in t:
        result = 'SUCCESS'; break
hold = float(opts['HOLD'])
if result == 'SUCCESS':
    end = el() + hold
    while el() < end:
        time.sleep(0.5)
        ps = bottle_procs()
        cpu.write('%.2f\t%.2f\t%.2f\t%d\n' % (el(), sum(p[1] for p in ps if p[0] == swpid), sum(p[1] for p in ps), len(ps)))
if result == 'SUCCESS':
    subprocess.run(['screencapture', '-x', '-l', str(main_wid), OUT + '/main.png'])
ps = bottle_procs()
sw_cpu_main = None
if sampler:
    try: sampler.wait(timeout=float(opts['SAMPLE']) + 30)
    except subprocess.TimeoutExpired: sampler.kill()
# ---- stop ----
note = ''
if opts['NOCLOSE'] != '1':
    if result == 'SUCCESS':
        frame = None
        for line in wtool('list').splitlines():
            w = parse_wnd(line)
            if w and w['text'] == main and w['cls'].startswith('Afx:'): frame = w
        if frame:
            wtool('close', frame['h']); t0 = el()
            while el() - t0 < 60 and any(is_sw(p[2]) for p in bottle_procs()): time.sleep(0.5)
            note += 'exit %.1fs; ' % (el() - t0)
        else:
            note += 'frame hwnd not found; '
    note += 'bottle clean; ' if kill_bottle() else 'WARNING bottle not clean; '
    try: proc.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
# SOLIDWORKS's own session log (add-in load times, UI state); the serial-number line (and anything
# shaped like a serial number) is not copied
perf = PREFIX + '/drive_c/users/' + os.environ.get('USER', '') + '/AppData/Roaming/SolidWorks/SOLIDWORKS 2026/SolidWorksPerformance.log'
try:
    with open(perf, 'rb') as f:
        lines = f.read().decode('utf-8', 'replace').splitlines()
    with open(OUT + '/SolidWorksPerformance.log', 'w') as f:
        f.write('\n'.join(l for l in lines if 'SERIAL' not in l.upper()
                           and not re.search(r'([0-9A-Z]{4}[ -]){5}[0-9A-Z]{4}', l)) + '\n')
except OSError:
    pass
r = {'label': label, 'result': result, 'load1': round(load0, 1),
     'proc_s': round(t.get('proc', -1), 2), 'splash_s': round(t.get('splash', -1), 2),
     'wiz_s': round(wiz_s, 2), 'wiz_at': round(t.get('wiz', -1), 2), 'main_s': round(t.get('main', -1), 2),
     'main_net_s': round(t['main'] - wiz_s, 2) if 'main' in t else None, 'wiz_note': wiz_note,
     'env': ' '.join('%s=%s' % kv for kv in over.items()) + (' RUNTIME=' + RT if RT != S + '/rt-base' else ''),
     'out': OUT, 'note': note}
json.dump(r, open(OUT + '/result.json', 'w'))
tsv = S + '/starts.tsv'
new = not os.path.exists(tsv)
with open(tsv, 'a') as f:
    if new: f.write('time\tlabel\tresult\tmain_s\twiz_s\tmain_net_s\tproc_s\tsplash_s\twiz_at\tload1\tenv\tout\n')
    f.write('%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (time.strftime('%H:%M:%S'), label, result, r['main_s'],
            r['wiz_s'], r['main_net_s'], r['proc_s'], r['splash_s'], r['wiz_at'], r['load1'], r['env'], OUT))
print(json.dumps(r))
