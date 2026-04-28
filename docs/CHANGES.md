# Changes

A chronological log of what was built and why. Newest entries first.

## 2026-04-28 - Stage A: Prometheus + service-map

Roadmap stage A is in. Tempo's service-graph and span-metrics generators
finally have somewhere to land, and JVM-agent metrics from Kafka, HBase,
producer, consumer, etc. are now queryable.

- New `prometheus/prometheus.yml`: no scrape jobs; Prometheus is purely a
  remote-write target.
- `docker-compose.yml`: added `prometheus` service (`prom/prometheus:v2.54.1`)
  with `--web.enable-remote-write-receiver`, exemplar storage, native
  histograms, and a 30m out-of-order window so Tempo's slightly-delayed
  metric_generator writes are accepted. Tempo, otel-collector, and grafana
  all `depends_on: prometheus`.
- `tempo/tempo.yaml`: `metrics_generator.storage.remote_write` now points at
  `http://prometheus:9090/api/v1/write` with `send_exemplars: true`.
- `otel-collector/config.yaml`: added `prometheusremotewrite` exporter; the
  `metrics` pipeline now fans out to both Prometheus and the debug exporter.
  Resource attributes (service.name, container, deployment.environment) are
  promoted to Prometheus labels via `resource_to_telemetry_conversion`.
- `grafana/provisioning/datasources/prometheus.yaml`: new datasource,
  exemplar trace-id link to the Tempo datasource.
- `grafana/provisioning/datasources/tempo.yaml`: turned on `serviceMap`
  and `tracesToMetrics` (request rate / error rate / p99 PromQL queries
  pre-filled per service).
- `grafana/provisioning/dashboards/service-map.json`: Node Graph from
  service-graph metrics + RED panels (rate, errors, p99) per service +
  JVM heap and GC pause panels per service.
- New host port: 9090 (Prometheus UI).

Diagnostic uplift: you can now see the dependency graph derived from
observed traffic, plus per-service rate/error/latency in one place. The
"is producer slow because of Kafka?" question becomes a side-by-side
chart comparison.

## 2026-04-28 - Fix: drop otel-collector healthcheck

The `otel/opentelemetry-collector-contrib` image is distroless (no shell,
no wget/curl/nc), so the original healthcheck command always failed and
blocked every dependent service. Removed the healthcheck; dependents now
use `condition: service_started`. Documented the rationale inline so
future-me doesn't try to add it back.

## 2026-04-27 - Verification + clean-up

- Wrote a `bash -n` syntax check pass over `entrypoint.sh`.
- YAML/XML/JSON parse pass over every config in `tempo/`, `otel-collector/`,
  `grafana/`, and `docker/hadoop-hbase/conf/`.
- Trimmed null-byte padding that the Write tool left on the Java sources
  (NTFS mount quirk that shows up only on `wc -c`, not on `Read`).
- Static review of Java code: balanced braces, complete record decls,
  cleaned imports.

## 2026-04-27 - Compose + Java apps + observability stack

- `docker/kafka/Dockerfile` and `docker/zookeeper/Dockerfile`: multi-stage
  builds that bake the OTel Java agent into the official `apache/kafka:3.8.0`
  and `zookeeper:3.9` images.
- `tempo/tempo.yaml`: monolithic mode, OTLP receivers, local-filesystem
  block storage, service-graph + span-metrics generators on by default.
- `otel-collector/config.yaml`: OTLP in, Tempo + debug exporter out, with
  `memory_limiter`, `batch`, and a `resource/lab` processor.
- `grafana/provisioning/`: Tempo datasource + starter trace-search dashboard.
- `apps/`: Maven multi-module project (parent + producer + consumer fat
  jars built via Shade plugin, Dockerfiles bake in agent + JAVA_TOOL_OPTIONS).
- `docker-compose.yml`: 11 services tied together with healthcheck-gated
  depends_on ordering and the shared `x-otel-env` anchor.

## 2026-04-27 - Hadoop+HBase image

- `docker/hadoop-hbase/Dockerfile`: Temurin 11 JDK base, Hadoop 3.3.6,
  HBase 2.5.8, OTel agent 2.10.0. Later switched primary mirror to
  `dlcdn.apache.org` for build speed (archive.apache.org is throttled).
- Role-based `entrypoint.sh` supports `namenode`, `datanode`, `hmaster`,
  `regionserver`, `shell`. Auto-formats the NameNode on first start.
- Site XMLs in `docker/hadoop-hbase/conf/`: distributed mode, HDFS root,
  ZK at `zookeeper:2181`, Java 11 module-access flags.
- OTel agent attached via daemon-specific `*_OPTS` env vars in entrypoint.

## 2026-04-27 - Initial scaffold

- Created repo structure: `apps/`, `docker/`, `otel-collector/`, `tempo/`,
  `grafana/`, `docs/`.
- Decisions captured in ARCHITECTURE.md:
  - Single custom image for Hadoop+HBase, role-based entrypoint.
  - Kafka in KRaft mode (single node).
  - OTel Java agent attached to *every* JVM container, OTLP to a shared
    Collector, Collector exports to Tempo, Grafana queries Tempo.
  - Synthetic IoT sensor telemetry as toy ingest data.
