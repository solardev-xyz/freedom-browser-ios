#!/usr/bin/env python3
"""Refresh Freedom/Freedom/Resources/public_suffix_list.dat.

Scriptlet rules such as `google.*##+js(...)` name an *entity*: a site under
any public suffix. Matching them needs the public suffix list. Desktop's
@ghostery/adblocker uses tldts with ICANN suffixes only (private ones like
github.io's owners are off), so this keeps only the ICANN section, with
internationalised labels converted to punycode because WebKit hands us
punycoded hosts.

    scripts/adblock/update-public-suffix.py [--commit <sha>]

Without --commit it resolves the head of publicsuffix/list's main branch and
records the commit it used in the file's header.
"""
import argparse
import json
import os
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "../../Freedom/Freedom/Resources/public_suffix_list.dat")


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode("utf-8")


def to_ascii(rule):
    prefix = ""
    if rule.startswith("!"):
        prefix, rule = "!", rule[1:]
    labels = []
    for label in rule.split("."):
        if label == "*" or label.isascii():
            labels.append(label.lower())
        else:
            labels.append(label.encode("idna").decode("ascii"))
    return prefix + ".".join(labels)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit")
    args = ap.parse_args()
    commit = args.commit or json.loads(fetch("https://api.github.com/repos/publicsuffix/list/commits/main"))["sha"]
    text = fetch(f"https://raw.githubusercontent.com/publicsuffix/list/{commit}/public_suffix_list.dat")
    begin = text.index("// ===BEGIN ICANN DOMAINS===")
    end = text.index("// ===END ICANN DOMAINS===")
    rules = []
    for line in text[begin:end].splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        rules.append(to_ascii(line.split()[0]))
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("// Public Suffix List, ICANN section only, IDN labels as punycode.\n")
        f.write(f"// Source: https://github.com/publicsuffix/list/blob/{commit}/public_suffix_list.dat\n")
        f.write("// License: Mozilla Public License 2.0, https://mozilla.org/MPL/2.0/\n")
        f.write("// Regenerate with scripts/adblock/update-public-suffix.py.\n")
        f.write("\n".join(rules) + "\n")
    print(f"wrote {len(rules)} rules from {commit} to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
