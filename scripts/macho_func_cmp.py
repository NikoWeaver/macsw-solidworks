"""Which functions of two x86_64 Mach-O builds differ? (objdump -d, per symbol, hex numbers and ## comments normalised;
assert() line numbers are immediates, so a function with an assert below a patched line differs too)
A name can occur more than once (static functions with the same name in two source files, for example
macdrv_surface_flush in opengl.c and in surface.c). Each body is kept apart as name#1, name#2, ... in objdump
order, so a change in any one of them shows. A body added between two bodies of the same name shifts the
later numbers and shows as differences too: that is a stop, then look.
Copy of build.nosync/rc23/scripts/macho_func_cmp.py, which keys by name only and compares only the last body.
Usage: python3 -I macho_func_cmp.py <a> <b>"""
import re, subprocess, sys


def parse(out):
    fs, cur, seen = {}, None, {}
    for line in out.splitlines():
        m = re.match(r'^[0-9a-f]+ <(.+)>:$', line)
        if m:
            n = m.group(1); seen[n] = seen.get(n, 0) + 1
            cur = (n, seen[n]); fs[cur] = []; continue
        m = re.match(r'^\s*[0-9a-f]+:\s+(.*)$', line)
        if m and cur:
            fs[cur].append(re.sub(r'0x[0-9a-f]+|\b[0-9a-f]{6,}\b', 'N', re.sub(r'<[^>]*>', '<S>', m.group(1).split('##')[0])).strip())
    return fs


def funcs(path):
    out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', '--arch=x86_64', path],
                         capture_output=True, text=True, check=True).stdout
    return parse(out)


def report(a, b):
    diff = sorted(n for n in set(a) | set(b) if a.get(n) != b.get(n))
    lines = [f'functions: {len(a)} vs {len(b)}; differing: {len(diff)}']
    for n in diff:
        lines.append(f'  {n[0]}#{n[1]}: {len(a.get(n, []))} vs {len(b.get(n, []))} instructions'
                     + ('' if n in a and n in b else ' (only in one)'))
    return lines


if __name__ == '__main__':
    print('\n'.join(report(funcs(sys.argv[1]), funcs(sys.argv[2]))))
