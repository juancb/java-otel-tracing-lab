# syntax=docker/dockerfile:1.6
#
# Apache Kafka in KRaft mode with two javaagents baked in:
#   /opt/otel/opentelemetry-javaagent.jar           (OTLP traces/metrics/logs)
#   /opt/jmx-exporter/jmx_prometheus_javaagent.jar  (JMX -> Prom; Stage B)

FROM curlimages/curl:8.10.1 AS agents
ARG OTEL_AGENT_VERSION=2.10.0
ARG JMX_EXPORTER_VERSION=1.0.1
RUN curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    -o /tmp/opentelemetry-javaagent.jar \
 && curl -fsSL \
    "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar" \
    -o /tmp/jmx_prometheus_javaagent.jar

FROM apache/kafka:3.8.0
USER root
COPY --from=agents /tmp/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar
COPY --from=agents /tmp/jmx_prometheus_javaagent.jar /opt/jmx-exporter/jmx_prometheus_javaagent.jar
RUN chmod 644 /opt/otel/opentelemetry-javaagent.jar /opt/jmx-exporter/jmx_prometheus_javaagent.jar
USER appuser
