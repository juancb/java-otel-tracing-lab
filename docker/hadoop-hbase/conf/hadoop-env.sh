#!/usr/bin/env bash
# Hadoop environment overrides.

export JAVA_HOME=${JAVA_HOME:-/opt/java/openjdk}

# Java 11 module access tweaks Hadoop needs.
export HADOOP_OPTS="${HADOOP_OPTS:-} \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  --add-opens=java.base/java.io=ALL-UNNAMED \
  --add-opens=java.base/java.nio=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
  --add-opens=java.base/sun.nio.ch=ALL-UNNAMED"

# Allow root to run NN/DN. The compose containers run as root for simplicity.
export HDFS_NAMENODE_USER=root
export HDFS_DATANODE_USER=root
export HDFS_SECONDARYNAMENODE_USER=root
