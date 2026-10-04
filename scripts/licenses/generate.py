#!/usr/bin/env python3
"""Regenerate Freedom/Freedom/Resources/licenses.json — the open-source
inventory the About screen shows (desktop NOTICES parity).

Sources, all read at generation time:
  - Swift packages: the Xcode workspace's Package.resolved + each
    checkout's LICENSE file under DerivedData (--checkouts).
  - Rust crates linked into FreedomMobile.xcframework: `cargo metadata`
    of the freedom-mobile-ffi aggregator (--ffi) at the tag the app pins,
    filtered to the iOS target, normal dependencies only.
  - Native components (ant, freedom-ipfs, libradicle + Heartwood,
    Myotis): LICENSE/NOTICE files fetched from GitHub at the pinned tags.
  - Filter lists, uBlock's scriptlets: Resources/adblock/metadata.json.
  - Public Suffix List: the header of Resources/public_suffix_list.dat.
  - SPDX licence texts for every id a crate names, from the SPDX list.

Run after a FreedomMobile pin bump or a Swift package change:
  scripts/licenses/generate.py --ffi ../freedom-mobile-ffi \
      --checkouts ~/Library/Developer/Xcode/DerivedData/Freedom-*/SourcePackages/checkouts
`LicensesTests` fails when the inventory drifts from the pins.
"""
import argparse, base64, glob, hashlib, json, os, re, subprocess, sys, urllib.request
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Freedom/Freedom/Resources/licenses.json")
RESOLVED = os.path.join(ROOT, "Freedom/Freedom.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
PACKAGE_SWIFT = os.path.join(ROOT, "Packages/SwarmKit/Package.swift")
ADBLOCK = os.path.join(ROOT, "Freedom/Freedom/Resources/adblock/metadata.json")
PSL = os.path.join(ROOT, "Freedom/Freedom/Resources/public_suffix_list.dat")
UBLOCK_COPYRIGHT = "Copyright (c) Raymond Hill and the uBlock Origin contributors"

COMPONENTS = [
    # name, cargo package (version source), repo, licence expression, copyright, files to fetch
    ("Ant (Swarm node)", "ant-ffi", "freedom-hq/ant", "MIT OR Apache-2.0",
     "Copyright (c) solardev-xyz contributors", ["LICENSE-MIT", "LICENSE-APACHE"], None),
    ("freedom-ipfs", "freedom-ipfs-mobile", "solardev-xyz/freedom-ipfs", "MIT OR Apache-2.0",
     "Copyright (c) 2026 Freedom IPFS contributors", ["LICENSE-MIT", "LICENSE-APACHE"], None),
    ("libradicle (Radicle node)", "libradicle", "solardev-xyz/libradicle", "MIT OR Apache-2.0",
     "Copyright (c) solardev-xyz contributors. Statically links Radicle Heartwood (MIT OR Apache-2.0), https://github.com/solardev-xyz/heartwood",
     [], "solardev-xyz/heartwood"),  # libradicle ships no LICENSE file; Heartwood's apply to the linked code
    ("Myotis (Ethereum light client)", "myotis-bls", "biafra23/myotis", "Apache-2.0",
     "Copyright 2026 Dirk Jäckel", ["LICENSE", "NOTICE"], None),
]

texts = {}  # id -> text

def text_id(text):
    tid = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    texts[tid] = text
    return tid

def gh_file(repo, path, ref=None):
    args = ["gh", "api", f"repos/{repo}/contents/{path}" + (f"?ref={ref}" if ref else ""), "-q", ".content"]
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return base64.b64decode(out).decode("utf-8")

def spdx_text(spdx_id):
    url = f"https://raw.githubusercontent.com/spdx/license-list-data/main/text/{spdx_id}.txt"
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")

def detect_spdx(text):
    head = text[:600]
    if "Apache License" in head and "2.0" in head: return "Apache-2.0"
    if "MIT License" in head or "Permission is hereby granted, free of charge" in text[:1500]: return "MIT"
    if "Mozilla Public License" in head: return "MPL-2.0"
    if "Redistribution and use in source and binary forms" in text and "Neither the name" in text: return "BSD-3-Clause"
    if "Redistribution and use in source and binary forms" in text: return "BSD-2-Clause"
    if "This software is provided 'as-is'" in text and "origin of this software must not be misrepresented" in text: return "Zlib"
    return None

def spdx_ids(expression):
    return sorted({t for t in re.split(r"[()\s/]+", expression or "") if t and t not in ("OR", "AND", "WITH")})

def swift_packages(checkouts):
    pins = json.load(open(RESOLVED))["pins"]
    out = []
    for pin in pins:
        location = pin["location"].rstrip("/")
        repo_name = location.rsplit("/", 1)[-1].removesuffix(".git")
        gh_repo = re.sub(r"^https://github.com/", "", location).removesuffix(".git")
        version = pin["state"].get("version") or pin["state"]["revision"][:12]
        text = None
        for d in glob.glob(os.path.join(checkouts, repo_name)):
            for name in sorted(os.listdir(d)):
                if re.match(r"(?i)^(licen[cs]e|copying)", name) and os.path.isfile(os.path.join(d, name)):
                    text = open(os.path.join(d, name), encoding="utf-8", errors="replace").read()
                    break
        note = None
        if text is None and pin["identity"] == "colibri-stateless-swift":
            # The Swift package ships no licence file; it wraps the Colibri C
            # library, whose LICENSE applies.
            text = gh_file("corpus-core/colibri-stateless", "LICENSE")
            note = "The Swift package carries no licence file; this is the licence of the Colibri library it wraps (corpus-core/colibri-stateless)."
        if text is None:
            sys.exit(f"no licence file for Swift package {pin['identity']} under {checkouts}")
        spdx = detect_spdx(text)
        if pin["identity"] == "cryptoswift" and spdx is None: spdx = "Zlib-style (CryptoSwift)"
        out.append({
            "id": f"swift:{pin['identity']}", "name": repo_name, "version": version,
            "url": f"https://github.com/{gh_repo}", "license": spdx or "see text",
            "textIDs": [text_id(text)], "note": note,
        })
    return out

def rust_crates(ffi):
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--filter-platform", "aarch64-apple-ios"],
        cwd=ffi, capture_output=True, text=True, check=True).stdout)
    ids = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    seen, stack = set(), [meta["resolve"]["root"]]
    while stack:
        i = stack.pop()
        if i in seen: continue
        seen.add(i)
        for d in nodes[i]["deps"]:
            if any((k.get("kind") or "normal") == "normal" for k in d["dep_kinds"]):
                stack.append(d["pkg"])
    out = []
    for i in sorted(seen, key=lambda i: (ids[i]["name"], ids[i]["version"])):
        p = ids[i]
        if p["name"] == "freedom-mobile-ffi":
            continue  # the aggregator itself: Freedom's own code
        lic = p.get("license")
        if not lic and p.get("license_file"):
            lic = "see repository"
        out.append({"id": f"rust:{p['name']}@{p['version']}", "name": p["name"], "version": p["version"],
                    "license": lic or "unknown", "url": p.get("repository") or p.get("homepage")})
    versions = {p["name"]: p["version"] for p in ids.values()}
    return out, versions

def components(versions):
    out = []
    for name, pkg, repo, lic, copyright_, files, fallback_repo in COMPONENTS:
        version = versions[pkg]
        tag = f"v{version}"
        tids, notice = [], None
        for f in files:
            body = gh_file(repo, f, tag)
            if f.upper().startswith("NOTICE"):
                notice = body
            else:
                tids.append(text_id(body))
        note = None
        if fallback_repo:
            for f in ["LICENSE-MIT", "LICENSE-APACHE"]:
                tids.append(text_id(gh_file(fallback_repo, f)))
            note = f"{repo} publishes no licence file at {tag}; its crate declares {lic}. The texts shown are Radicle Heartwood's, which libradicle statically links."
        out.append({"id": f"component:{pkg}", "name": name, "version": version, "url": f"https://github.com/{repo}",
                    "license": lic, "copyright": copyright_, "notice": notice, "textIDs": tids, "note": note})
    return out

def filter_lists():
    meta = json.load(open(ADBLOCK))
    out = []
    gpl = None
    for c in meta["categories"]:
        if c["id"] == "ublock":
            # uBlock's own lists are GPL-3.0-only (no CC BY-SA option).
            gpl = gpl or text_id(spdx_text("GPL-3.0-only"))
            commit = c.get("source", {}).get("commit", "")
            out.append({"id": "list:ublock", "name": c["list_title"], "version": commit[:12] or meta["version"],
                        "url": c["list_homepage"], "sourceURL": c["source_url"], "license": "GPL-3.0-only",
                        "copyright": UBLOCK_COPYRIGHT, "textIDs": [gpl],
                        "note": f"uBlock filters and Quick fixes, uBlockOrigin/uAssets at {commit}. Bundled as data; "
                                "compiled to WebKit content-blocker rules and a scriptlet index by freedom-adblock-service."})
            continue
        out.append({"id": f"list:{c['id']}", "name": c["list_title"], "version": meta["version"],
                    "url": c["list_homepage"], "sourceURL": c["source_url"],
                    "license": "GPL-3.0-or-later OR CC-BY-SA-3.0 (redistributed under CC BY-SA)",
                    "copyright": "Copyright (c) The EasyList authors",
                    "note": "Bundled as data, compiled to WebKit content-blocker rules by adblock-rs at build time."})
    res = meta.get("resources")
    if res:
        gpl = gpl or text_id(spdx_text("GPL-3.0-only"))
        upstream = res.get("upstream", {}).get("ublockOrigin", {})
        out.append({"id": "list:ublock-resources", "name": "uBlock Origin scriptlets",
                    "version": f"{res['tag']} (uBlock Origin {upstream.get('tag', '?')})",
                    "url": "https://github.com/gorhill/uBlock", "sourceURL": res["source_url"],
                    "license": res.get("license", "GPL-3.0-only"), "copyright": UBLOCK_COPYRIGHT, "textIDs": [gpl],
                    "note": f"Ghostery's build of uBlock Origin's scriptlets and redirect resources (resources.json, "
                            f"sha256 {res['sha256']}), injected into web pages unmodified. Corresponding source: "
                            f"{upstream.get('sourceUrl', 'https://github.com/gorhill/uBlock')}."})
    header = open(PSL, encoding="utf-8").read().splitlines()[:4]
    source = next(l.split("Source: ", 1)[1] for l in header if "Source: " in l)
    commit = re.search(r"/blob/([0-9a-f]{40})/", source).group(1)
    out.append({"id": "data:public-suffix-list", "name": "Public Suffix List", "version": commit[:12],
                "url": "https://publicsuffix.org", "sourceURL": source, "license": "MPL-2.0",
                "copyright": "Copyright (c) Mozilla Foundation and the Public Suffix List contributors",
                "textIDs": [text_id(spdx_text("MPL-2.0"))],
                "note": "ICANN section, IDN labels as punycode. Used to match ad-blocking scriptlet rules that name a site under any public suffix."})
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffi", required=True, help="freedom-mobile-ffi checkout at the pinned tag")
    ap.add_argument("--checkouts", required=True, help="DerivedData .../SourcePackages/checkouts")
    args = ap.parse_args()
    ffi_tag = re.search(r"releases/download/(v[0-9.]+)/FreedomMobile", open(PACKAGE_SWIFT).read()).group(1)
    crates, versions = rust_crates(args.ffi)
    comps = components(versions)
    swift = swift_packages(args.checkouts)
    lists = filter_lists()
    spdx_needed = set()
    for c in crates: spdx_needed.update(spdx_ids(c["license"]))
    spdx_texts = {}
    for sid in sorted(spdx_needed):
        try:
            spdx_texts[sid] = text_id(spdx_text(sid))
        except Exception as e:  # noqa: BLE001
            print(f"warning: no SPDX text for {sid}: {e}", file=sys.stderr)
    doc = {
        "generated": date.today().isoformat(), "ffiTag": ffi_tag,
        "app": {"name": "Freedom", "url": "https://github.com/solardev-xyz/freedom-browser-ios",
                "license": "Not yet chosen (README: TBD)"},
        "components": comps, "swiftPackages": swift, "rustCrates": crates, "filterLists": lists,
        "spdxTexts": spdx_texts, "texts": texts,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"wrote {OUT}: {len(comps)} components, {len(swift)} Swift packages, {len(crates)} Rust crates, "
          f"{len(lists)} filter lists, {len(texts)} texts ({os.path.getsize(OUT)//1024} KB)")

if __name__ == "__main__":
    main()
