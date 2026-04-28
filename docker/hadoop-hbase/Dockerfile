# syntax=docker/dockerfile:1.6
#
# Custom image bundling Apache Hadoop and Apache HBase, configured for
# pseudo-distributed operation. The image's entrypoint takes a role argument
# (namenode | datanode | hmaster | regionserver) and starts the corresponding
# daemon in the foreground. The OpenTelemetry Java agent is baked in at
# /opt/otel/opentelemetry-javaagent.jar.

FROM eclipse-temurin:11-jdk-jammy

ARG HADOOP_VERSION=3.3.6
ARG HBASE_VERSION=2.5.8
ARG OTEL_AGENT_VERSION=2.10.0

ENV HADOOP_HOME=/opt/hadoop
ENV HBASE_HOME=/opt/hbase
ENV PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HBASE_HOME/bin:$PATH
ENV HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
ENV HBASE_CONF_DIR=$HBASE_HOME/conf
ENV JAVA_HOME=/opt/java/openjdk

# OS deps. `procps` provides ps which Hadoop scripts use, `net-tools` provides
# netstat for the daemon scripts, `gnupg` and `ca-certificates` for downloads,
# `curl` for fetching tarballs.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg procps net-tools \
        bash less vim-tiny tini \
 && rm -rf /var/lib/apt/lists/*

# --- Download Hadoop --------------------------------------------------------
# Try the fast CDN mirror first; fall back to the slow long-term archive only
# if the CDN drops the version (which happens once a release ages out).
RUN ( curl -fsSL "https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz" \
       -o /tmp/hadoop.tgz \
   || curl -fsSL "https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz" \
       -o /tmp/hadoop.tgz ) \
 && mkdir -p /opt \
 && tar -xzf /tmp/hadoop.tgz -C /opt \
 && mv /opt/hadoop-${HADOOP_VERSION} ${HADOOP_HOME} \
 && rm /tmp/hadoop.tgz

# --- Download HBase ---------------------------------------------------------
# The "-bin" tarball contains the compiled binaries (vs. the source tarball).
RUN ( curl -fsSL "https://dlcdn.apache.org/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
       -o /tmp/hbase.tgz \
   || curl -fsSL "https://archive.apache.org/dist/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
       -o /tmp/hbase.tgz ) \
 && tar -xzf /tmp/hbase.tgz -C /opt \
 && mv /opt/hbase-${HBASE_VERSION} ${HBASE_HOME} \
 && rm /tmp/hbase.tgz

# --- Download OpenTelemetry Java agent --------------------------------------
RUN mkdir -p /opt/otel \
 && curl -fsSL "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
        -o /opt/otel/opentelemetry-javaagent.jar

# --- Configuration ----------------------------------------------------------
# Site XMLs and env scripts. These are mounted/baked at known paths so that
# changing a config doesn't require a rebuild - but we also COPY them into the
# image so a `docker run` with no volumes still works.
COPY conf/core-site.xml      ${HADOOP_CONF_DIR}/core-site.xml
COPY conf/hdfs-site.xml      ${HADOOP_CONF_DIR}/hdfs-site.xml
COPY conf/hbase-site.xml     ${HBASE_CONF_DIR}/hbase-site.xml
COPY conf/hbase-env.sh       ${HBASE_CONF_DIR}/hbase-env.sh
COPY conf/hadoop-env.sh      ${HADOOP_CONF_DIR}/hadoop-env.sh
COPY conf/log4j.properties   ${HBASE_CONF_DIR}/log4j.properties

# HBase ships with a regionservers file listing slave RegionServers. In
# pseudo-distributed mode there's just one (this same host).
RUN echo "localhost" > ${HBASE_CONF_DIR}/regionservers

# Hadoop expects this file (workers replaces slaves in 3.x) to list DataNodes.
RUN echo "localhost" > ${HADOOP_CONF_DIR}/workers

# Disable HBase's "fail fast if you're root" check so we can run as root inside
# the container without juggling user creation.
ENV HBASE_ROOT_LOGGER=INFO,console
ENV HDFS_NAMENODE_USER=root
ENV HDFS_DATANODE_USER=root
ENV HDFS_SECONDARYNAMENODE_USER=root
ENV HBASE_MANAGES_ZK=false

# --- Entrypoint --------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Use tini as PID 1 so signals propagate cleanly to the foreground daemon.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["help"]
