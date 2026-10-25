#!/usr/bin/python3 -I
"""summ.py <label> [<label> ...] [--since HH:MM:SS] : per-label medians of the start-up runs in starts.tsv.

Columns: main_net_s (launch -> main frame, minus the time the activation wizard was on screen),
sw_cpu_s (SLDWORKS.exe CPU seconds at the main frame), srv_cpu_s (wineserver CPU seconds at the main frame:
a load-robust proxy for the number of server requests), load1 at launch.
"""
import statistics, sys

import os
S = os.environ.get('STARTBENCH_DIR')  # the folder that holds starts.tsv; no default
if not S:
    sys.exit('set STARTBENCH_DIR to the folder that holds starts.tsv (no default)')
args = sys.argv[1:]
since = None
if '--since' in args:
    i = args.index('--since'); since = args[i + 1]; del args[i:i + 2]
rows = [l.rstrip('\n').split('\t') for l in open(S + '/starts.tsv')][1:]
for label in args:
    vals = []
    for r in rows:
        if r[1] != label or r[2] != 'SUCCESS': continue
        if since and r[0] < since: continue
        out = r[11]
        sw = srv = None
        procs = []
        for l in open(out + '/events.tsv'):
            f = l.rstrip('\n').split('\t')
            if f[1] != 'cpu_at_main': continue
            pid, cpu, cmd = f[2].split(' ', 2)
            procs.append((int(pid), float(cpu), cmd))
        for pid, cpu, cmd in procs:
            if 'sldworks.exe' in cmd.lower() or '/drive_c/Program Files/SOLI' in cmd:
                sw = cpu
                # the wineserver is started right after the loader (pid + 2); older logs truncated its path
                srv = next((c for p2, c, m in procs if p2 == pid + 2 and not m.startswith('C:')), None)
            if cmd == 'wineserver': srv = cpu
        vals.append((float(r[5]), sw, srv, float(r[9]), r[0]))
    if not vals: print('%-12s no runs' % label); continue
    def st(i):
        xs = [v[i] for v in vals if v[i] is not None]
        return '%6.2f [%6.2f-%6.2f]' % (statistics.median(xs), min(xs), max(xs)) if xs else '   -'
    print('%-12s n=%d  main_net %s  sw_cpu %s  srv_cpu %s  load %s' % (label, len(vals), st(0), st(1), st(2), st(3)))
    for v in vals:
        print('    %s net %6.2f sw_cpu %s srv_cpu %s load %4.1f' % (v[4], v[0], v[1], v[2], v[3]))
