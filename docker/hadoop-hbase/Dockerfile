# syntax=docker/dockerfile:1.6
#
# Hadoop + HBase image. Role-based entrypoint (namenode | datanode | hmaster
# | regionserver). Two JVM agents are baked in:
#   /opt/otel/opentelemetry-javaagent.jar       (traces/metrics/logs to OTLP)
#   /opt/jmx-exporter/jmx_prometheus_javaagent.jar  (JMX → Prom; Stage B)

FROM eclipse-temurin:11-jdk-jammy

ARG HADOOP_VERSION=3.3.6
ARG HBASE_VERSION=2.5.8
ARG OTEL_AGENT_VERSION=2.10.0
ARG JMX_EXPORTER_VERSION=1.0.1

ENV HADOOP_HOME=/opt/hadoop
ENV HBASE_HOME=/opt/hbase
ENV PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HBASE_HOME/bin:$PATH
ENV HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
ENV HBASE_CONF_DIR=$HBASE_HOME/conf
ENV JAVA_HOME=/opt/java/openjdk

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg procps net-tools \
        bash less vim-tiny tini \
 && rm -rf /var/lib/apt/lists/*

# --- Hadoop ----------------------------------------------------------------
RUN ( curl -fsSL "https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz" \
       -o /tmp/hadoop.tgz \
   || curl -fsSL "https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz" \
       -o /tmp/hadoop.tgz ) \
 && mkdir -p /opt && tar -xzf /tmp/hadoop.tgz -C /opt \
 && mv /opt/hadoop-${HADOOP_VERSION} ${HADOOP_HOME} && rm /tmp/hadoop.tgz

# --- HBase -----------------------------------------------------------------
RUN ( curl -fsSL "https://dlcdn.apache.org/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
       -o /tmp/hbase.tgz \
   || curl -fsSL "https://archive.apache.org/dist/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
       -o /tmp/hbase.tgz ) \
 && tar -xzf /tmp/hbase.tgz -C /opt \
 && mv /opt/hbase-${HBASE_VERSION} ${HBASE_HOME} && rm /tmp/hbase.tgz

# --- OTel Java agent --------------------------------------------------------
RUN mkdir -p /opt/otel \
 && curl -fsSL "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
        -o /opt/otel/opentelemetry-javaagent.jar

# --- Prometheus JMX exporter (Stage B) -------------------------------------
RUN mkdir -p /opt/jmx-exporter \
 && curl -fsSL "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar" \
        -o /opt/jmx-exporter/jmx_prometheus_javaagent.jar

# --- Site XMLs and env scripts ---------------------------------------------
COPY conf/core-site.xml      ${HADOOP_CONF_DIR}/core-site.xml
COPY conf/hdfs-site.xml      ${HADOOP_CONF_DIR}/hdfs-site.xml
COPY conf/hbase-site.xml     ${HBASE_CONF_DIR}/hbase-site.xml
COPY conf/hbase-env.sh       ${HBASE_CONF_DIR}/hbase-env.sh
COPY conf/hadoop-env.sh      ${HADOOP_CONF_DIR}/hadoop-env.sh
COPY conf/log4j.properties   ${HBASE_CONF_DIR}/log4j.properties

RUN echo "localhost" > ${HBASE_CONF_DIR}/regionservers \
 && echo "localhost" > ${HADOOP_CONF_DIR}/workers

ENV HBASE_ROOT_LOGGER=INFO,console
ENV HDFS_NAMENODE_USER=root
ENV HDFS_DATANODE_USER=root
ENV HDFS_SECONDARYNAMENODE_USER=root
ENV HBASE_MANAGES_ZK=false

# --- Entrypoint ------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["help"]
