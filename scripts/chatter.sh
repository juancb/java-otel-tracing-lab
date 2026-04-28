#!/usr/bin/env bash
# Drives synthetic admin + DML traffic against the HBase cluster so you have
# something to look at in Tempo's intra-cluster trace search and in the JMX
# dashboards. Each iteration cycles through:
#   - create a temp table
#   - put a few rows (master delegates region assignment, RS handles writes)
#   - flush (RS -> HDFS DataNode WAL/store file activity)
#   - scan the table back
#   - disable + drop the table (master does region close + meta updates)
#
# Run from the repo root:
#   bash scripts/chatter.sh
# Stop with Ctrl+C.

set -e

INTERVAL_SECS="${INTERVAL_SECS:-15}"

cycle=0
while true; do
  cycle=$((cycle + 1))
  TABLE="chatter_${cycle}"
  echo "[chatter] cycle $cycle  table=$TABLE  ts=$(date +%H:%M:%S)"

  docker compose exec -T hbase-master hbase shell -n <<HBSH 2>&1 | grep -vE '^$|deprecation|SLF4J' || true
create '$TABLE', 'cf'
put '$TABLE', 'r1', 'cf:c', 'v1'
put '$TABLE', 'r2', 'cf:c', 'v2'
put '$TABLE', 'r3', 'cf:c', 'v3'
flush '$TABLE'
scan '$TABLE'
disable '$TABLE'
drop '$TABLE'
HBSH

  # Occasionally do a heavier op
  if [ $((cycle % 5)) -eq 0 ]; then
    echo "[chatter] cycle $cycle  cluster status + balancer toggle"
    docker compose exec -T hbase-master hbase shell -n <<'HBSH' 2>&1 | grep -vE '^$|deprecation|SLF4J' || true
status 'detailed'
balance_switch true
balancer
HBSH
  fi

  sleep "$INTERVAL_SECS"
done
