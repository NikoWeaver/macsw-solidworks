#!/usr/bin/python3 -I
"""thr.py <run dir>: per-thread priority / CPU timeline from threads.tsv (ps -M polls)."""
import sys, collections
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1] + '/threads.tsv')]
pri = {}; hist = collections.defaultdict(list)
for t, r in rows:
    t = float(t)
    for x in r.split():
        i, st, p, c = x.split(':'); i = int(i); c = float(c)
        pri.setdefault(i, []).append(p)
        hist[i].append((t, c, st))
for i in sorted(hist):
    ps = pri[i]; h = hist[i]
    low = [p for p in set(ps) if not (p.startswith('20') or p.startswith('31') or p.startswith('4'))]
    if low or i < 3:
        start = None
        for k in range(1, len(h)):
            if h[k][1] > h[k - 1][1] + 0.005: start = h[k][0]; break
        chg = [(round(h[k][0], 1), ps[k]) for k in range(len(h)) if k == 0 or ps[k] != ps[k - 1]]
        print('thread %2d pri %s cpu_end %.2f first_cpu_at %s first_seen %.1f' % (i, chg[:6], h[-1][1], start, h[0][0]))
