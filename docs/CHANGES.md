# Changes

A chronological log of what was built and why. Newest entries first.

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
  and `zookeeper:3.9` images. Agent landed at
  `/opt/otel/opentelemetry-javaagent.jar` in both.
- `tempo/tempo.yaml`: monolithic mode, OTLP receivers on 4317 (gRPC) and
  4318 (HTTP), local-filesystem block storage, service-graph + span-metrics
  generators on by default.
- `otel-collector/config.yaml`: OTLP in, Tempo + debug exporter out, with
  `memory_limiter`, `batch`, and a `resource/lab` processor that stamps
  `deployment.environment=local-otel-lab`.
- `grafana/provisioning/datasources/tempo.yaml`: Tempo datasource auto-loaded.
- `grafana/provisioning/dashboards/`: starter dashboard with TraceQL panels
  per service (producer/consumer/kafka/hbase+hadoop).
- `apps/` Maven multi-module project:
  - `apps/pom.xml`: parent POM, Java 17, dependency-managed Kafka 3.8.0,
    HBase 2.5.8, Hadoop 3.3.6, Jackson 2.17.2, SLF4J + Logback.
  - `apps/producer/`: synthetic IoT sensor producer, Shade-built fat JAR,
    Dockerfile that bakes in the agent and sets `JAVA_TOOL_OPTIONS`.
  - `apps/consumer/`: Kafka -> HBase consumer with auto-create table,
    batched Puts, manual offset commit, same Dockerfile pattern.
- `docker-compose.yml`: 11 services (tempo, otel-collector, grafana,
  zookeeper, namenode, datanode, hbase-master, hbase-regionserver, kafka,
  producer, consumer). Healthchecks gate `depends_on` ordering. Shared
  `x-otel-env` anchor injects OTLP endpoint + protocol everywhere.
- Host-exposed ports: 3000 (Grafana), 3200 (Tempo), 4317/4318 (Collector),
  9092/29092 (Kafka), 9870 (HDFS UI), 16010 (HBase UI), 2181 (ZK).

## 2026-04-27 - Hadoop+HBase image

- `docker/hadoop-hbase/Dockerfile`: Temurin 11 JDK base, Hadoop 3.3.6,
  HBase 2.5.8, OTel agent 2.10.0.
- Role-based `entrypoint.sh` supports `namenode`, `datanode`, `hmaster`,
  `regionserver`, `shell`. Auto-formats the NameNode on first start;
  HBase Master and RegionServer wait for their dependencies to come up
  by polling the parent's RPC port over `/dev/tcp`.
- Site XMLs in `docker/hadoop-hbase/conf/`:
  - `core-site.xml`: `fs.defaultFS=hdfs://namenode:8020`.
  - `hdfs-site.xml`: replication=1, hostname-mode DataNode, permission
    checks off.
  - `hbase-site.xml`: distributed mode, root in HDFS, ZK at
    `zookeeper:2181`, master/regionserver bound on all interfaces.
  - `hbase-env.sh`/`hadoop-env.sh`: `JAVA_HOME` plus Java 11
    `--add-opens` flags so HBase doesn't trip module access checks.
  - `log4j.properties`: console INFO with HBase, ZK, metrics tuning.
- OTel agent attached via the daemon-specific `*_OPTS` env vars
  (`HDFS_NAMENODE_OPTS`, `HDFS_DATANODE_OPTS`, `HBASE_MASTER_OPTS`,
  `HBASE_REGIONSERVER_OPTS`) prepended in the entrypoint.

## 2026-04-27 - Initial scaffold

- Created repo structure: `apps/`, `docker/`, `otel-collector/`, `tempo/`,
  `grafana/`, `docs/`.
- Added `README.md`, `.gitignore`, `docs/ARCHITECTURE.md`, `docs/CHANGES.md`.
- Decisions captured in ARCHITECTURE.md:
  - Single custom image for Hadoop+HBase, role-based entrypoint.
  - Kafka in KRaft mode (single node).
  - OTel Java agent attached to *every* JVM container, OTLP to a shared
    Collector, Collector exports to Tempo, Grafana queries Tempo.
  - Synthetic IoT sensor telemetry as toy ingest data.
