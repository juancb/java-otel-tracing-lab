# Changes

A chronological log of what was built and why. Newest entries first.

## 2026-04-27 — Initial scaffold

- Created repo structure: `apps/`, `docker/`, `otel-collector/`, `tempo/`,
  `grafana/`, `docs/`.
- Added `README.md`, `.gitignore`, `docs/ARCHITECTURE.md`, `docs/CHANGES.md`.
- Decisions captured in ARCHITECTURE.md:
  - Single custom image for Hadoop+HBase, role-based entrypoint.
  - Kafka in KRaft mode (single node).
  - OTel Java agent attached to *every* JVM container, OTLP to a shared
    Collector, Collector exports to Tempo, Grafana queries Tempo.
  - Synthetic IoT sensor telemetry as toy ingest data.
