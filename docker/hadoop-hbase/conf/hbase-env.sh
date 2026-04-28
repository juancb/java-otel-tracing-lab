#!/usr/bin/env bash
# HBase environment overrides. The compose file injects OTel-related vars at
# runtime; this file only sets things that aren't role-specific.

# Force HBase to find Java even when JAVA_HOME isn't exported in some shell.
export JAVA_HOME=${JAVA_HOME:-/opt/java/openjdk}

# We run an external ZooKeeper (the `zookeeper` compose service), not HBase's
# bundled one.
export HBASE_MANAGES_ZK=false

# Quiet down some noisy Hadoop warnings about reflective access on Java 11+.
HBASE_OPTS_BASE="--add-opens=java.base/java.lang=ALL-UNNAMED \
                 --add-opens=java.base/java.io=ALL-UNNAMED \
                 --add-opens=java.base/java.nio=ALL-UNNAMED \
                 --add-opens=java.base/java.util=ALL-UNNAMED \
                 --add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
                 --add-opens=java.base/sun.nio.ch=ALL-UNNAMED"

export HBASE_MASTER_OPTS="${HBASE_MASTER_OPTS:-} ${HBASE_OPTS_BASE}"
export HBASE_REGIONSERVER_OPTS="${HBASE_REGIONSERVER_OPTS:-} ${HBASE_OPTS_BASE}"
