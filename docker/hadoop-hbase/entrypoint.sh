#!/usr/bin/env bash
# Entrypoint for the Hadoop+HBase image. Two javaagents are attached to the
# daemon JVM:
#   1. OpenTelemetry javaagent  (OTLP traces/metrics/logs to the Collector)
#   2. JMX -> Prometheus exporter  (Stage B: scraped directly by Prometheus)
#
# Each role binds the JMX exporter on a unique port so Prometheus can scrape
# all four roles from the same lab network.

set -euo pipefail

ROLE="${1:-help}"

OTEL_AGENT="-javaagent:/opt/otel/opentelemetry-javaagent.jar"
JMX_AGENT_JAR="/opt/jmx-exporter/jmx_prometheus_javaagent.jar"

: "${OTEL_EXPORTER_OTLP_ENDPOINT:=http://otel-collector:4317}"
: "${OTEL_EXPORTER_OTLP_PROTOCOL:=grpc}"
: "${OTEL_TRACES_EXPORTER:=otlp}"
: "${OTEL_METRICS_EXPORTER:=otlp}"
: "${OTEL_LOGS_EXPORTER:=otlp}"
export OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL \
       OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER

# Build the agent flags string for a given role and prepend to *_OPTS.
# Args: role-specific JMX port, JMX config filename, *_OPTS env var name.
prepend_agents() {
  local jmx_port="$1"
  local jmx_config="$2"
  local opts_var="$3"
  local jmx_agent="-javaagent:${JMX_AGENT_JAR}=${jmx_port}:/etc/jmx-exporter/${jmx_config}"
  local current="${!opts_var:-}"
  export "$opts_var=$OTEL_AGENT $jmx_agent $current"
}

case "$ROLE" in
  namenode)
    : "${OTEL_SERVICE_NAME:=hadoop-namenode}"
    export OTEL_SERVICE_NAME
    prepend_agents 7074 hadoop.yaml HDFS_NAMENODE_OPTS

    NAME_DIR="/data/dfs/name"
    if [[ ! -f "$NAME_DIR/current/VERSION" ]]; then
        echo "[entrypoint] Formatting NameNode (first run)"
        mkdir -p "$NAME_DIR"
        $HADOOP_HOME/bin/hdfs namenode -format -clusterId otel-lab -nonInteractive -force
    fi
    exec $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR namenode
    ;;

  datanode)
    : "${OTEL_SERVICE_NAME:=hadoop-datanode}"
    export OTEL_SERVICE_NAME
    prepend_agents 7075 hadoop.yaml HDFS_DATANODE_OPTS
    mkdir -p /data/dfs/data
    exec $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR datanode
    ;;

  hmaster)
    : "${OTEL_SERVICE_NAME:=hbase-master}"
    export OTEL_SERVICE_NAME
    prepend_agents 7072 hbase.yaml HBASE_MASTER_OPTS

    echo "[entrypoint] Waiting for HDFS NameNode (namenode:8020)..."
    for i in $(seq 1 60); do
        if (echo > /dev/tcp/namenode/8020) >/dev/null 2>&1; then
            echo "[entrypoint] HDFS reachable"
            break
        fi
        sleep 2
    done
    exec $HBASE_HOME/bin/hbase --config $HBASE_CONF_DIR master start
    ;;

  regionserver)
    : "${OTEL_SERVICE_NAME:=hbase-regionserver}"
    export OTEL_SERVICE_NAME
    prepend_agents 7073 hbase.yaml HBASE_REGIONSERVER_OPTS

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
    exec $HBASE_HOME/bin/hbase --config $HBASE_CONF_DIR shell
    ;;

  help|*)
    cat <<EOF
Usage: entrypoint.sh <role>

Roles:
  namenode       HDFS NameNode (formats on first start)        JMX :7074
  datanode       HDFS DataNode                                 JMX :7075
  hmaster        HBase Master                                  JMX :7072
  regionserver   HBase RegionServer                            JMX :7073
  shell          HBase shell

OTel agent + JMX-Prom exporter are attached automatically.
EOF
    exit 0
    ;;
esac
