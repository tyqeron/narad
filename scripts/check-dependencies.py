#!/usr/bin/env python3
"""Check public registry dependencies against OSV; requires Python 3.11+ and network."""
import json
from pathlib import Path
import sys
import tomllib
import urllib.request

lock = Path(__file__).resolve().parents[1] / "Cargo.lock"
with lock.open("rb") as stream:
    packages = [p for p in tomllib.load(stream)["package"] if p.get("source", "").startswith("registry+")]
queries = [{"package": {"name": p["name"], "ecosystem": "crates.io"}, "version": p["version"]} for p in packages]
request = urllib.request.Request(
    "https://api.osv.dev/v1/querybatch",
    data=json.dumps({"queries": queries}).encode(),
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if len(result["results"]) != len(packages):
        raise ValueError("incomplete advisory response")
    findings = [{"package": p["name"], "version": p["version"], "advisories": [v["id"] for v in r.get("vulns", [])]}
                for p, r in zip(packages, result["results"]) if r.get("vulns")]
except (OSError, ValueError, KeyError) as error:
    print(f"Dependency check failed: {error}", file=sys.stderr)
    sys.exit(2)
print(json.dumps({"checked": len(packages), "findings": findings}, indent=2))
sys.exit(1 if findings else 0)
