# syntax=docker/dockerfile:1.6
#
# Producer container. Multi-stage:
#   1. Build the fat-jar with Maven.
#   2. Fetch the OTel Java agent.
#   3. Slim runtime image with just the JRE, the fat-jar, and the agent.

FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
# Copy parent POM first so Maven can resolve, then the producer module.
COPY pom.xml /src/pom.xml
COPY producer/pom.xml /src/producer/pom.xml
COPY consumer/pom.xml /src/consumer/pom.xml
# Pre-download dependencies to leverage the layer cache.
RUN mvn -B -q -pl producer -am dependency:go-offline || true
COPY producer/src /src/producer/src
RUN mvn -B -pl producer -am package -DskipTests

FROM curlimages/curl:8.10.1 AS agent
ARG OTEL_AGENT_VERSION=2.10.0
RUN curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    -o /tmp/opentelemetry-javaagent.jar

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/producer/target/producer.jar /app/app.jar
COPY --from=agent /tmp/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar

# Default OTel agent config; can be overridden in compose.
ENV OTEL_SERVICE_NAME=producer \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=otlp \
    JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/opentelemetry-javaagent.jar"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
