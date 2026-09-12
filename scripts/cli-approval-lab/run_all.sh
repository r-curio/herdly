#!/bin/sh
# Sequential lab cases; each swaps the lab hooks.json, so they must not overlap.
cd "$(dirname "$0")"
python3 resolution_run.py native-deny STEER10-NATIVE-DENY-1 --standin receipt --answers esc --wait 90 > runs/native-deny.out 2>&1
python3 resolution_run.py native-allow STEER10-NATIVE-ALLOW-1 --standin receipt --answers y --wait 90 > runs/native-allow.out 2>&1
python3 resolution_run.py companion-killed STEER10-KILL-1 --standin receipt --kill-standin-after 3 --answers y --wait 90 > runs/companion-killed.out 2>&1
python3 resolution_run.py open-in-codex STEER10-OPEN-1 --standin handoff --standin-delay 2 --answers esc --wait 60 > runs/open-in-codex.out 2>&1
python3 resolution_run.py parallel STEER10-PARALLEL --standin handoff --standin-delay 2 --answers y,esc --wait 90 --prompt-file parallel-prompt.txt > runs/parallel.out 2>&1
echo ALL-DONE > runs/ALL-DONE
