#!/bin/bash
# ab.sh <rounds> <labelA> "<argsA>" <labelB> "<argsB>" [<labelC> "<argsC>" ...]
# Interleaved start-up A/B(/C...) with startbench.py: A B [C] A B [C] ...; one summary line per run.
D=$(cd "$(dirname "$0")" && pwd)
N=$1; shift
labels=(); argss=()
while [ $# -ge 2 ]; do labels+=("$1"); argss+=("$2"); shift 2; done
for r in $(seq 1 "$N"); do
  for i in "${!labels[@]}"; do
    for try in 1 2 3; do
      # wait (max 3 min) for the 1-minute load average to drop below 9
      for w in $(seq 1 36); do l=$(sysctl -n vm.loadavg | awk '{print int($2)}'); [ "$l" -lt 9 ] && break; sleep 5; done
      # shellcheck disable=SC2086
      out=$(/usr/bin/python3 -I "$D/startbench.py" "${labels[$i]}" ${argss[$i]} 2>&1 | tail -1)
      echo "$out" | grep -q '"result": "SUCCESS"' && break
      echo "  (invalid run, retry $try: $(echo "$out" | cut -c1-160))"
      sleep 10
    done
    echo "$out" | /usr/bin/python3 -I -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print("%-14s %-8s main %6.2f wiz %5.2f net %6.2f load %4.1f" % (d["label"], d["result"], d["main_s"], d["wiz_s"], d["main_net_s"] or -1, d["load1"]))
except Exception as e:
    print("PARSE", e)'
    sleep 3
  done
done
