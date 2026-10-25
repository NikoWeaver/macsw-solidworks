#!/usr/bin/python3 -I
"""srvtrace.py <wine.log from TSPIPE=1 WINEDEBUG=+server> [tid=0024] [bucket_s=2]

Summarises a timestamped wineserver request trace: requests per type for one thread, per time bucket,
and the key names / handles behind the registry and read_process_memory storms.
"""
import collections, re, sys

path = sys.argv[1]
TID = sys.argv[2] if len(sys.argv) > 2 else '0024'
B = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
req_re = re.compile(r'^(\d+\.\d+) ([0-9a-f]{4}): ([a-z_]+)\((.*)$')
rep_re = re.compile(r'^(\d+\.\d+) ([0-9a-f]{4}): ([a-z_]+)\(\) = (\w+)(.*)$')
types = collections.Counter(); buckets = collections.defaultdict(collections.Counter)
openkeys = collections.Counter(); enum_hkeys = collections.Counter(); rpm = collections.Counter()
rpm_sizes = collections.Counter(); handle_name = {}
pending = None
last_open_name = None
first = last = None
gaps = []  # client time between reply and next request
prev_reply_t = None
waits = []  # (t_req, dur, handles, timeout)
sel_t = None; sel_args = ''
for line in open(path, errors='replace'):
    m = rep_re.match(line)
    if m and m.group(2) == TID:
        t = float(m.group(1)); name = m.group(3)
        if name == 'open_key' or name == 'create_key':
            h = re.search(r'hkey=([0-9a-f]+)', m.group(5))
            if h and last_open_name: handle_name[h.group(1)] = last_open_name
        if name == 'select' and m.group(4) != 'PENDING' and sel_t is not None:
            waits.append((sel_t, t - sel_t, sel_args)); sel_t = None
        prev_reply_t = t
        continue
    if line[7:].startswith(TID + ': *wakeup*') or (' %s: *wakeup*' % TID) in line[:30]:
        t = float(line.split()[0])
        if sel_t is not None:
            waits.append((sel_t, t - sel_t, sel_args)); sel_t = None
        prev_reply_t = t
        continue
    m = req_re.match(line)
    if not m or m.group(2) != TID: continue
    t = float(m.group(1)); name = m.group(3); args = m.group(4)
    if first is None: first = t
    last = t
    types[name] += 1
    buckets[int(t // B)][name] += 1
    if prev_reply_t is not None: gaps.append(t - prev_reply_t)
    if name in ('open_key', 'create_key'):
        n = re.search(r'name=L"([^"]*)"', args)
        r = re.search(r'rootdir=([0-9a-f]+)', args)
        last_open_name = (handle_name.get(r.group(1), r.group(1)) if r else '?') + '\\' + (n.group(1) if n else '')
        openkeys[last_open_name] += 1
    elif name in ('enum_key', 'enum_key_value', 'get_key_value'):
        h = re.search(r'hkey=([0-9a-f]+)', args)
        hk = h.group(1) if h else '?'
        enum_hkeys[(name, handle_name.get(hk, hk))] += 1
    elif name == 'read_process_memory':
        h = re.search(r'handle=([0-9a-f]+)', args); a = re.search(r'addr=([0-9a-f]+)', args)
        rpm[(h.group(1) if h else '?')] += 1
        if a: rpm_sizes[a.group(1)[:-3]] += 1  # 4K page of the address
    elif name == 'select':
        sel_t = t; sel_args = args[:200]

tot = sum(types.values())
print('thread %s: %d requests from %.1f to %.1f s' % (TID, tot, first, last))
for k, v in types.most_common(25): print('%9d  %s' % (v, k))
print('\nrequests per %.0f s bucket (top 4 types):' % B)
for b in sorted(buckets):
    c = buckets[b]
    print('%6.0f s %7d  %s' % (b * B, sum(c.values()), ', '.join('%s %d' % kv for kv in c.most_common(4))))
print('\nmost opened keys:')
for k, v in openkeys.most_common(20): print('%8d  %s' % (v, k[:150]))
print('\nenum/get by key:')
for k, v in enum_hkeys.most_common(20): print('%8d  %s  %s' % (v, k[0], k[1][:150]))
print('\nread_process_memory by process handle:', rpm.most_common(5))
print('read_process_memory by address page (top 15):')
for k, v in rpm_sizes.most_common(15): print('%8d  %s000' % (v, k))
waits.sort(key=lambda w: -w[1])
print('\nlongest waits (select) of the thread:')
for w in waits[:25]: print('%8.3f s at %7.2f  %s' % (w[1], w[0], w[2][:170]))
print('total select wait %.1f s in %d selects' % (sum(w[1] for w in waits), len(waits)))
gaps.sort()
if gaps:
    print('client gap between reply and next request: median %.1f us, p90 %.1f us, sum %.1f s' %
          (gaps[len(gaps)//2] * 1e6, gaps[int(len(gaps)*.9)] * 1e6, sum(gaps)))
