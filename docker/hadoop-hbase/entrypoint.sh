#!/usr/bin/env bash
# Entrypoint for the Hadoop+HBase image. Two javaagents are attached:
#   1. OpenTelemetry javaagent (OTLP traces/metrics/logs to the Collector)
#   2. JMX -> Prometheus exporter (Stage B)
# Each role binds the JMX exporter on a unique port so Prometheus can scrape
# all roles from the same lab network.

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

prepend_agents() {
  local jmx_port="$1"
  local jmx_config="$2"
  local opts_var="$3"
  local jmx_agent="-javaagent:${JMX_AGENT_JAR}=${jmx_port}:/etc/jmx-exporter/${jmx_config}"
  local current="${!opts_var:-}"
  export "$opts_var=$OTEL_AGENT $jmx_agent $current"
}

# Block until HDFS has at least one live DataNode. The healthcheck at the
# Compose layer should already gate this, but the entrypoint enforces it as
# a backstop in case the healthcheck races with the master startup.
wait_for_hdfs_writable() {
  echo "[entrypoint] Waiting for HDFS to have a live DataNode..."
  for i in $(seq 1 120); do
    local count
    count=$(curl -sf "http://namenode:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState" 2>/dev/null \
            | grep -oE '"NumLiveDataNodes"\s*:\s*[0-9]+' \
            | grep -oE '[0-9]+$' \
            || echo 0)
    if [ "${count:-0}" -ge 1 ]; then
      echo "[entrypoint] HDFS reports $count live DataNode(s)"
      return 0
    fi
    sleep 2
  done
  echo "[entrypoint] WARNING: HDFS still has no live DataNodes after 240s; starting anyway"
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
    wait_for_hdfs_writable
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
  hmaster        HBase Master (waits for live DN)              JMX :7072
  regionserver   HBase RegionServer                            JMX :7073
  shell          HBase shell

OTel agent + JMX-Prom exporter are attached automatically.
EOF
    exit 0
    ;;
esac
