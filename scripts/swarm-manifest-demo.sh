#!/usr/bin/env bash
# Publishes scripts/manifest-demo/ (index.html + freedom-manifest.json)
# through the simulator's bee node (host port 1633) and prints the
# bzz:// URL to open in Freedom. Needs a usable postage stamp on the
# node (buy one in the app's Swarm sheet first).
#
#   scripts/swarm-manifest-demo.sh            # picks the first usable stamp
#   scripts/swarm-manifest-demo.sh <batchID>  # or name one
set -euo pipefail
cd "$(dirname "$0")/manifest-demo"
BEE=${BEE:-http://127.0.0.1:1633}
BATCH=${1:-}
if [ -z "$BATCH" ]; then
  BATCH=$(curl -sf "$BEE/stamps" | python3 -c 'import json,sys; s=[b for b in json.load(sys.stdin)["stamps"] if b.get("usable")]; print(s[0]["batchID"] if s else "")')
  [ -n "$BATCH" ] || { echo "no usable stamp on $BEE — buy one in Freedom → Swarm → Stamps"; exit 1; }
fi
TAR=$(mktemp -t manifest-demo).tar
tar -cf "$TAR" index.html freedom-manifest.json
REF=$(curl -sf -X POST "$BEE/bzz?name=manifest-demo" \
  -H "Content-Type: application/x-tar" \
  -H "Swarm-Collection: true" \
  -H "Swarm-Index-Document: index.html" \
  -H "Swarm-Postage-Batch-Id: $BATCH" \
  --data-binary "@$TAR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reference"])')
rm -f "$TAR"
echo "bzz://$REF/"
echo "manifest: bzz://$REF/freedom-manifest.json"
