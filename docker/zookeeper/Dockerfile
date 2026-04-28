# syntax=docker/dockerfile:1.6
#
# Stock Apache ZooKeeper with the OpenTelemetry Java agent baked in. ZK is
# included so HBase has somewhere to coordinate, and so we can see the
# JVM-level resource attributes flow through the agent for a third type of
# Apache JVM daemon (Hadoop, HBase, ZooKeeper).

FROM curlimages/curl:8.10.1 AS agent
ARG OTEL_AGENT_VERSION=2.10.0
RUN curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    -o /tmp/opentelemetry-javaagent.jar

FROM zookeeper:3.9
USER root
COPY --from=agent /tmp/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar
RUN chmod 644 /opt/otel/opentelemetry-javaagent.jar
USER zookeeper
