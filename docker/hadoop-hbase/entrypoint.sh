#!/usr/bin/env bash
# Entrypoint for the unified Hadoop+HBase image. Takes a role argument and
# starts the matching daemon in the foreground so Docker can supervise it.
#
# Roles:
#   namenode      — HDFS NameNode (formats on first run if dfs/name is empty)
#   datanode      — HDFS DataNode
#   hmaster       — HBase Master
#   regionserver  — HBase RegionServer
#   help          — print usage and exit
#
# The OTel Java agent is attached via *_OPTS environment variables that the
# Hadoop and HBase startup scripts honor. We *prepend* to whatever the user
# passed in the compose file so the agent always wins.

set -euo pipefail

ROLE="${1:-help}"

OTEL_AGENT="-javaagent:/opt/otel/opentelemetry-javaagent.jar"

# All daemons get sensible default OTel resource attributes if the operator
# didn't already set OTEL_SERVICE_NAME. The compose file sets these explicitly
# so this is just belt-and-braces.
: "${OTEL_EXPORTER_OTLP_ENDPOINT:=http://otel-collector:4317}"
: "${OTEL_EXPORTER_OTLP_PROTOCOL:=grpc}"
: "${OTEL_TRACES_EXPORTER:=otlp}"
: "${OTEL_METRICS_EXPORTER:=otlp}"
: "${OTEL_LOGS_EXPORTER:=otlp}"
export OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL \
       OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER

# Prepend the agent flag to the role-specific *_OPTS variable. Hadoop/HBase
# concatenate this onto java's command line for the daemon.
prepend_agent() {
  local var="$1"
  local current="${!var:-}"
  export "$var=$OTEL_AGENT $current"
}

case "$ROLE" in
  namenode)
    : "${OTEL_SERVICE_NAME:=hadoop-namenode}"
    export OTEL_SERVICE_NAME
    prepend_agent HDFS_NAMENODE_OPTS

    # Format the NameNode on first start. We detect "first start" by the
    # absence of the VERSION file in the configured name dir.
    NAME_DIR="/data/dfs/name"
    if [[ ! -f "$NAME_DIR/current/VERSION" ]]; then
        echo "[entrypoint] Formatting NameNode (first run)"
        mkdir -p "$NAME_DIR"
        $HADOOP_HOME/bin/hdfs namenode -format -nonInteractive -force cluster1 || true
    fi

    # Run the NameNode in the foreground.
    exec $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR namenode
    ;;

  datanode)
    : "${OTEL_SERVICE_NAME:=hadoop-datanode}"
    export OTEL_SERVICE_NAME
    prepend_agent HDFS_DATANODE_OPTS
    mkdir -p /data/dfs/data
    exec $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR datanode
    ;;

  hmaster)
    : "${OTEL_SERVICE_NAME:=hbase-master}"
    export OTEL_SERVICE_NAME
    prepend_agent HBASE_MASTER_OPTS

    # Wait for HDFS to be reachable so the Master doesn't crash-loop while
    # NameNode is still booting. We poll the NameNode RPC port.
    echo "[entrypoint] Waiting for HDFS NameNode (namenode:8020)..."
    for i in $(seq 1 60); do
        if (echo > /dev/tcp/namenode/8020) >/dev/null 2>&1; then
            echo "[entrypoint] HDFS reachable"
            break
        fi
        sleep 2
    done

    # Foreground mode requires --foreground.
    exec $HBASE_HOME/bin/hbase --config $HBASE_CONF_DIR master start
    ;;

  regionserver)
    : "${OTEL_SERVICE_NAME:=hbase-regionserver}"
    export OTEL_SERVICE_NAME
    prepend_agent HBASE_REGIONSERVER_OPTS

    echo "[entrypoint] Waiting for HBase Master (hbase-master:16000)..."
    for i in $(seq 1 60); do
        if (echo > /dev/tcp/hbase-master/16000) >/dev/null 2>&1; then
            echo "[entrypoint] HBase Master reachable"
            break
        fi
        sleep 2
    done

    exec $HBASE_HOME/bin/hbase --config $HBASE_CONF_DIR regionserver start
    ;;

  shell|hbase-shell)
    # Convenience: drop into the HBase shell against this cluster.
    exec $HBASE_HOME/bin/hbase --config $HBASE_CONF_DIR shell
    ;;

  help|*)
    cat <<EOF
Usage: entrypoint.sh <role>

Roles:
  namenode       Run HDFS NameNode (formats on first start)
  datanode       Run HDFS DataNode
  hmaster        Run HBase Master
  regionserver   Run HBase RegionServer
  shell          Drop into hbase shell

OTel agent is attached automatically. Override OTEL_SERVICE_NAME to rename.
EOF
    exit 0
    ;;
esac
