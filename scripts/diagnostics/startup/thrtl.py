#!/usr/bin/python3 -I
"""thrtl.py <run dir> <thread idx,...>: CPU seconds of the given threads per 1 s step (ps -M polls)."""
import sys
want = [int(x) for x in sys.argv[2].split(',')]
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1] + '/threads.tsv')]
nxt = 0.0; prev = {}
print('t     ' + ' '.join('T%-6d' % w for w in want))
for t, r in rows:
    t = float(t)
    cur = {}
    for x in r.split():
        i, st, p, c = x.split(':'); cur[int(i)] = (float(c), p, st)
    if t >= nxt:
        print('%5.1f ' % t + ' '.join('%5.2f%-2s' % (cur[w][0] - prev.get(w, (0,))[0], cur[w][2][:1]) if w in cur else '   -   ' for w in want))
        prev = cur; nxt = t + 1.0
