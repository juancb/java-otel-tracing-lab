# syntax=docker/dockerfile:1.6
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml /src/pom.xml
COPY producer/pom.xml /src/producer/pom.xml
COPY consumer/pom.xml /src/consumer/pom.xml
RUN mvn -B -q -pl consumer -am dependency:go-offline || true
COPY consumer/src /src/consumer/src
RUN mvn -B -pl consumer -am package -DskipTests

FROM curlimages/curl:8.10.1 AS agent
ARG OTEL_AGENT_VERSION=2.10.0
RUN curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    -o /tmp/opentelemetry-javaagent.jar

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/consumer/target/consumer.jar /app/app.jar
COPY --from=agent /tmp/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar

ENV OTEL_SERVICE_NAME=consumer \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=otlp \
    JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/opentelemetry-javaagent.jar"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
