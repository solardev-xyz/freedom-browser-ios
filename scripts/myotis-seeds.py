#!/usr/bin/env python3
"""Regenerate a Myotis seed-pin list from warm peer caches.

    scripts/myotis-seeds.py --network mainnet <peers.cache>... [--no-probe]

Reads the engine's `peers[-net].cache` files (one peer per line:
ip \t port \t pubkey \t snap [\t snapok|snapbad] [\t fails=N]), keeps the
peers tagged `snapok` (they have served a verified read), drops IPv6 and
duplicate addresses, TCP-probes the rest (3 s) and writes
Freedom/Freedom/Resources/myotis/seeds-<network>.json, sorted. Run it at
release time against a long-lived profile; the app pushes a random subset
of 20 per start (MyotisSeedPins).
"""
import argparse, json, re, socket, sys, pathlib

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--network", required=True, choices=["mainnet", "gnosis"])
    ap.add_argument("caches", nargs="+")
    ap.add_argument("--no-probe", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    out = pathlib.Path(a.out or f"Freedom/Freedom/Resources/myotis/seeds-{a.network}.json")
    seen, entries = set(), []
    for path in a.caches:
        for line in open(path, encoding="utf-8", errors="replace"):
            f = line.rstrip("\n").split("\t")
            if len(f) < 4 or "snapok" not in f[4:]:
                continue
            ip, port, key = f[0].removeprefix("::ffff:"), f[1], f[2].removeprefix("0x").lower()
            if ":" in ip or not re.fullmatch(r"[0-9a-f]{128}", key) or not port.isdigit():
                continue
            addr = f"{ip}:{port}"
            if addr in seen:
                continue
            seen.add(addr)
            entries.append((addr, f"enode://{key}@{addr}"))
    kept = []
    for addr, enode in entries:
        if not a.no_probe:
            ip, port = addr.rsplit(":", 1)
            try:
                with socket.create_connection((ip, int(port)), timeout=3):
                    pass
            except OSError:
                print(f"unreachable {addr}", file=sys.stderr)
                continue
        kept.append(enode)
    kept.sort(key=lambda e: e.split("@", 1)[1])
    if len(kept) > 64:
        kept = kept[:64]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(kept, indent=1) + "\n")
    print(f"{len(kept)} seeds -> {out}")

if __name__ == "__main__":
    main()
