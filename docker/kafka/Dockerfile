# syntax=docker/dockerfile:1.6
#
# Apache Kafka in KRaft mode with the OpenTelemetry Java agent baked in.
# We use a multi-stage build so we can fetch the agent without adding curl
# to the slim Kafka runtime image.

FROM curlimages/curl:8.10.1 AS agent
ARG OTEL_AGENT_VERSION=2.10.0
RUN curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    -o /tmp/opentelemetry-javaagent.jar

FROM apache/kafka:3.8.0
USER root
COPY --from=agent /tmp/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar
RUN chmod 644 /opt/otel/opentelemetry-javaagent.jar
USER appuser
