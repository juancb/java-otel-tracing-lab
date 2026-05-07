#!/usr/bin/env bash
# Prints service-graph edges observed by Tempo's metrics_generator.
# Queries Prometheus directly — run while the stack is up and traffic has
# flowed for at least 2 minutes (Tempo's service-graph flush interval).
#
# Requires: curl, python3
# Usage: ./prom_query.sh [http://localhost:9090]

set -euo pipefail

PROM="${1:-http://localhost:9090}"

python3 - "$PROM" <<'EOF'
import sys, json, urllib.request, urllib.parse

# Force UTF-8 stdout so the box-drawing separator and em-dashes render on
# Windows (Python 3.x defaults to cp1252 there and crashes with
# UnicodeEncodeError otherwise). No-op on Linux/Mac which already use UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except (AttributeError, OSError):
    pass

prom = sys.argv[1]

def pq(expr):
    url = f"{prom}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.loads(r.read())["data"]["result"]
    except Exception as e:
        print(f"ERROR querying Prometheus at {url}: {e}", file=sys.stderr)
        sys.exit(1)

totals   = {(r["metric"].get("client","?"), r["metric"].get("server","?")): float(r["value"][1])
            for r in pq("rate(traces_service_graph_request_total[2m])")}
failures = {(r["metric"].get("client","?"), r["metric"].get("server","?")): float(r["value"][1])
            for r in pq("rate(traces_service_graph_request_failed_total[2m])")}

edges = sorted(set(totals) | set(failures))

if not edges:
    print("\nNo service-graph edges found.")
    print("Make sure the stack is running and traffic has flowed for at least 2 minutes.")
    print(f"\nQuick checks:")
    print(f"  docker compose logs producer --tail 5")
    print(f"  docker compose logs consumer --tail 5")
    print(f"  curl -s '{prom}/api/v1/query?query=up' | python3 -m json.tool")
    sys.exit(0)

print(f"\nService-graph edges — {prom}  (2-minute rate window)\n")
W = 26
fmt = f"{{:<{W}}}  {{:<{W}}}  {{:>9}}  {{:>9}}  {{:>7}}"
print(fmt.format("CLIENT", "SERVER", "req/s", "err/s", "err%"))
print("─" * (W*2 + 34))
for (c, s) in edges:
    t = totals.get((c, s), 0.0)
    f = failures.get((c, s), 0.0)
    pct = f"{f/t*100:.1f}%" if t > 0 else "n/a"
    print(fmt.format(c[:W], s[:W], f"{t:.4f}", f"{f:.4f}", pct))

print(f"\nTotal edges: {len(edges)}")

# Cross-check against expected topology
expected = {
    ("producer",        "kafka"),
    ("kafka",           "consumer"),
    ("consumer",        "hbase-regionserver"),
    ("query-client",    "hbase-regionserver"),
    ("hbase-master",    "hbase-regionserver"),
    ("hbase-regionserver", "hbase-master"),
    ("user",            "hadoop-namenode"),
    ("user",            "hbase-master"),
    ("user",            "hbase-regionserver"),
}
observed = set(edges)
missing  = expected - observed
extra    = observed - expected

if missing:
    print("\nExpected but NOT YET observed:")
    for (c, s) in sorted(missing):
        print(f"  {c} -> {s}  (wait longer, or check that service is up)")
if extra:
    print("\nObserved but NOT in expected set (may be fine — document if intentional):")
    for (c, s) in sorted(extra):
        print(f"  {c} -> {s}")
if not missing and not extra:
    print("\nAll expected edges present. Topology matches.")
EOF
