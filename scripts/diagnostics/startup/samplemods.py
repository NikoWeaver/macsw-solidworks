#!/usr/bin/python3 -I
"""samplemods.py <sample.txt> <wine.log with +loaddll,+pid> [prefix] [runtime] [--threads N] [--top N]

Leaf-PC profile of a /usr/bin/sample report of a Wine process under Rosetta. The x86 unwinder cannot
walk PE frames (stacks loop in __wine_syscall_dispatcher), but the leaf of every sample is right, so
self counts (node count minus its children) are attributed to the module that holds the node's address:
PE modules from +loaddll lines of that process (size from the PE header on disk), Mach-O images from the
report's Binary Images list, "Rosetta Runtime Routines" / "Rosetta JIT" by name.
"""
import collections, os, re, struct, sys

args, opt, it = [], {}, iter(sys.argv[1:])
for a in it:
    if a.startswith('--'): opt[a] = next(it)
    else: args.append(a)
NT = int(opt.get('--threads', 12)); TOP = int(opt.get('--top', 25))
sample, wlog = args[0], args[1]
PREFIX = args[2] if len(args) > 2 else os.path.expanduser('~/Library/Application Support/MacSW/bottle-perf2')
if len(args) > 3:
    RT = args[3]
elif os.environ.get('STARTBENCH_DIR'):
    RT = os.environ['STARTBENCH_DIR'] + '/rt-base'
else:
    sys.exit('give the runtime as the 4th argument, or set STARTBENCH_DIR (no default)')

def pe_size(path):
    try:
        with open(path, 'rb') as f:
            d = f.read(4096)
        off = struct.unpack_from('<I', d, 0x3c)[0]
        magic = struct.unpack_from('<H', d, off + 24)[0]
        return struct.unpack_from('<I', d, off + 24 + 56)[0]
    except Exception:
        return None

def unix_path(wp):
    wp = wp.replace('\\\\', '\\')
    if wp.lower().startswith('c:\\'):
        p = PREFIX + '/drive_c/' + wp[3:].replace('\\', '/')
        if os.path.exists(p): return p
        # case-insensitive fallback
        cur = PREFIX + '/drive_c'
        for part in wp[3:].split('\\'):
            try:
                m = [e for e in os.listdir(cur) if e.lower() == part.lower()]
            except OSError:
                return None
            if not m: return None
            cur = cur + '/' + m[0]
        return cur
    return None

# --- which Windows pid is the sampled process? the one that loaded SLDWORKS.exe
mods = []  # (base, end, name)
lines = open(wlog, errors='replace').read().splitlines()
swpid = None
for l in lines:
    m = re.match(r'[\d.]+:([0-9a-f]{4}):[0-9a-f]{4}:trace:loaddll:\S+ Loaded L"(.*)" at ([0-9A-Fa-f]+): (\w+)', l)
    if m and m.group(2).lower().endswith('sldworks.exe'):
        swpid = m.group(1); break
for l in lines:
    m = re.match(r'[\d.]+:([0-9a-f]{4}):[0-9a-f]{4}:trace:loaddll:\S+ Loaded L"(.*)" at ([0-9A-Fa-f]+): (\w+)', l)
    if not m or m.group(1) != swpid: continue
    wp, base, kind = m.group(2), int(m.group(3), 16), m.group(4)
    name = wp.replace('\\\\', '\\').split('\\')[-1]
    size = None
    if kind == 'builtin':
        for sub in ('x86_64-windows',):
            p = '%s/lib/wine/%s/%s' % (RT, sub, name.lower())
            if os.path.exists(p): size = pe_size(p); break
    if size is None:
        up = unix_path(wp)
        if up: size = pe_size(up)
    mods.append((base, base + (size or 0x10000), name + ('' if kind == 'native' else '[b]')))
mods.sort()

# --- Mach-O images
txt = open(sample, errors='replace').read().splitlines()
imgs = []
inimg = False
for l in txt:
    if l.startswith('Binary Images:'): inimg = True; continue
    if inimg:
        m = re.match(r'\s+(0x[0-9a-f]+)\s+-\s+(0x[0-9a-f]+)\s+\+?(\S+)', l)
        if m: imgs.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3)))
imgs.sort()

def classify(addr, inname):
    if inname.startswith('Rosetta'): return '<' + inname + '>'
    for b, e, n in mods:
        if b <= addr < e: return n
    for b, e, n in imgs:
        if b <= addr < e: return n
    if inname and inname != '<unknown binary>': return inname
    if 0x7ff800000000 <= addr < 0x7fff00000000: return '<system x86 (shared cache)>'
    return '<unmapped: JIT/managed code?>'

# --- call graph per thread: self counts
threads = []  # (name, total, Counter(module), Counter(symbol))
cur = None; stack = []
node_re = re.compile(r'^(\s*)([+!:| ]*)(\d+) (.*?)  \(in (.*?)\)(?: \+ \d+)?  \[(0x[0-9a-f]+)\]')
node_re2 = re.compile(r'^(\s*)([+!:| ]*)(\d+) (\?\?\?)  \(in (.*?)\)  \[(0x[0-9a-f]+)\]')
def flush():
    pass
started = False
for l in txt:
    if l.startswith('Call graph:'): started = True; continue
    if not started: continue
    if l.startswith('Total number in stack') or l.startswith('Sort by top of stack'): break
    m = re.match(r'^    (\d+) (Thread_\d+.*)$', l)
    if m:
        cur = [m.group(2), int(m.group(1)), collections.Counter(), collections.Counter()]
        threads.append(cur); stack = []
        continue
    if cur is None: continue
    m = re.match(r'^(\s*[+!:| ]*)(\d+) (.*)$', l)
    if not m: continue
    depth = len(m.group(1))
    cnt = int(m.group(2)); rest = m.group(3)
    a = re.search(r'\[(0x[0-9a-f]+)\]\s*$', rest)
    addr = int(a.group(1), 16) if a else 0
    inn = re.search(r'\(in (.*?)\)', rest)
    inname = inn.group(1) if inn else ''
    sym = rest.split('  (in ')[0]
    # pop deeper/equal
    while stack and stack[-1][0] >= depth:
        stack.pop()
    if stack:
        stack[-1][3] -= cnt  # parent's self loses child's count
    node = [depth, cnt, (addr, inname, sym), cnt]
    stack.append(node)
    # self count is finalised lazily: record node; we add self at pop time
    cur.append(node)

def summarize(th):
    name, total, modc, symc = th[0], th[1], th[2], th[3]
    for node in th[4:]:
        selfc = node[3]
        if selfc <= 0: continue
        addr, inname, sym = node[2]
        mod = classify(addr, inname)
        modc[mod] += selfc
        symc[(mod, sym if sym != '???' else hex(addr))] += selfc
    return modc, symc

allm = collections.Counter()
rows = []
for th in threads:
    modc, symc = summarize(th)
    rows.append((th[0], th[1], modc, symc))
    allm.update(modc)
WAIT = ('<system x86 (shared cache)>', 'libsystem_kernel.dylib')
def busy(modc): return sum(v for k, v in modc.items() if k not in WAIT)
rows.sort(key=lambda r: -busy(r[2]))
print('SW windows pid %s, %d PE modules mapped, %d Mach-O images' % (swpid, len(mods), len(imgs)))
print('\n== all threads: self samples by module (top %d)' % TOP)
tot = sum(allm.values()); tb = busy(allm)
print('total %d, not-in-system (busy-ish) %d' % (tot, tb))
for k, v in allm.most_common(TOP): print('%8d %5.1f%%  %s' % (v, 100.0 * v / max(tb, 1), k))
for r in rows[:NT]:
    print('\n== %s total %d busy %d' % (r[0], r[1], busy(r[2])))
    b = busy(r[2])
    for k, v in r[2].most_common(12):
        print('%8d %5.1f%%  %s' % (v, 100.0 * v / max(b, 1), k))
    print('   top symbols:')
    for (mod, s), v in r[3].most_common(10):
        print('%8d  %s  %s' % (v, mod, s[:80]))

# --- syscall view: for every leaf sample, the unix-side entry function below __wine_syscall_dispatcher
def syscall_view(th, top=25):
    nodes = th[4:]
    # rebuild parents from depth order
    parents = []
    stack = []
    for n in nodes:
        while stack and stack[-1][0] >= n[0]: stack.pop()
        parents.append(stack[-1] if stack else None)
        stack.append(n)
    idx = {id(n): i for i, n in enumerate(nodes)}
    agg = collections.Counter(); srv = 0; tot = 0
    for i, n in enumerate(nodes):
        if n[3] <= 0: continue
        tot += n[3]
        chain = []
        p = n
        while p is not None:
            chain.append(p[2][2]); p = parents[idx[id(p)]]
        # chain: leaf ... root ; find deepest-from-root dispatcher
        entry = None
        for j, s in enumerate(chain):
            if s.startswith('__wine_syscall_dispatcher'):
                entry = chain[j - 1] if j > 0 else s
                break
        if entry is None:
            entry = 'user: ' + classify(n[2][0], n[2][1])
        if any(s.startswith('server_call_unlocked') or s.startswith('wait_select_reply') for s in chain): srv += n[3]
        agg[entry.split('  (in')[0]] += n[3]
    print('\n== syscall view of %s: %d leaf samples, %d (%.0f%%) waiting in a wineserver round trip' % (th[0], tot, srv, 100.0 * srv / max(tot, 1)))
    for k, v in agg.most_common(top): print('%8d %5.1f%%  %s' % (v, 100.0 * v / max(tot, 1), k))

want = opt.get('--syscalls')
if want:
    for th in threads:
        if th[0].startswith(want) or want == 'all':
            syscall_view(th)
