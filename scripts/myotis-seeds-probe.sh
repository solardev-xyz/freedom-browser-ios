#!/bin/zsh
# Engine-probe a Myotis seed candidate list one peer at a time (mainnet).
#
#   scripts/myotis-seeds-probe.sh <simulator-udid> <candidates.json> [name.eth]
#
# For each enode: cold EL peer cache, that peer as the ONLY host pin
# (FREEDOM_MYOTIS_BOOT_ENODES_MAINNET), FREEDOM_DEBUG_RESOLVE on, ~40 s.
# Prints one line per peer: whether the Universal Resolver eth_call was
# served through it and how fast. Keep the peers with a served time —
# they are what a cold client needs. Requires a DEBUG build of Freedom
# installed on the simulator (com.browser.Freedom). Do not run it on the
# simulator you smoke-test with: it wipes that app's peer cache per run.
set -u
U=${1:?simulator udid}; LIST=${2:?candidates json}; NAME=${3:-vitalik.eth}
xcrun simctl boot "$U" 2>/dev/null; xcrun simctl bootstatus "$U" -b >/dev/null 2>&1
C=$(xcrun simctl get_app_container "$U" com.browser.Freedom data)
python3 -c "import json,sys;[print(e) for e in json.load(open(sys.argv[1]))]" "$LIST" | while read -r enode; do
  addr=${enode#*@}
  xcrun simctl terminate "$U" com.browser.Freedom 2>/dev/null; sleep 1
  for f in "$C"/Documents/myotis/mainnet/verified-sync/*/peers.cache(N); do mv "$f" "$f.probe-aside"; done
  T0=$(date '+%Y-%m-%d %H:%M:%S')
  SIMCTL_CHILD_FREEDOM_MYOTIS_BOOT_ENODES_MAINNET="[\"$enode\"]" SIMCTL_CHILD_FREEDOM_DEBUG_RESOLVE="$NAME" \
    xcrun simctl launch "$U" com.browser.Freedom >/dev/null 2>&1
  L=""
  for i in $(seq 1 15); do
    sleep 5
    L=$(xcrun simctl spawn "$U" log show --start "$T0" --info --debug --style compact \
        --predicate 'subsystem == "com.browser.Freedom"' 2>/dev/null \
        | grep "debug-resolve\] attempt\|\[myotis\] read")
    echo "$L" | grep -q "attempt 2 " && break
  done
  served=$(echo "$L" | grep -o "read served in [0-9]*ms" | sed 's/read served in //' | paste -sd, -)
  failed=$(echo "$L" | grep -c "read failed")
  echo "$addr | served=[${served:-none}] failed=$failed"
done
xcrun simctl terminate "$U" com.browser.Freedom 2>/dev/null
echo "PROBE DONE"
