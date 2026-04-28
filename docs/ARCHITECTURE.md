# Architecture

This project exists to make OpenTelemetry's Java agent auto-instrumentation
visible across a realistic JVM data pipeline. The goal is *understanding*,
not production fitness — so everything runs as a single-node, pseudo-distributed
cluster on a developer laptop.

## Goals

1. Every JVM-based component runs with the OTel Java agent attached so we can
   see what auto-instrumentation does without writing any tracing code.
2. A real data flow runs end-to-end: producer → Kafka → consumer → HBase
   (HBase in turn uses HDFS and ZooKeeper, so those JVMs show up in traces too).
3. Traces are queryable in Grafana through Tempo, so the developer experience
   matches what we'd encounter in a production observability stack.
4. As much as possible is encoded in version-controlled files (Dockerfiles,
   compose, site XMLs, agent config) so the environment is reproducible.

## Topology

```
   producer (Java)        Kafka (KRaft)        consumer (Java)        HBase                  HDFS
   ─────────────         ─────────────         ───────────────       ───────────────────    ──────────────
   javaagent ──┐         javaagent ──┐         javaagent ──┐         master + regionserver  namenode + datanode
               │                     │                     │         (each with javaagent)  (each with javaagent)
               │                     │                     │
               └────────┐    ┌───────┘    ┌────────────────┘
                        ▼    ▼            ▼                                         ▲
                   ┌─────────────────────────┐                                      │
                   │  OpenTelemetry Collector │◀──── OTLP from every JVM ───────────┘
                   └────────────┬─────────────┘
                                │ OTLP
                                ▼
                            ┌────────┐                ┌──────────┐
                            │ Tempo  │ ◀── queries ── │ Grafana  │
                            └────────┘                └──────────┘
```

ZooKeeper is included for HBase coordination (HBase still requires ZK; only
Kafka has moved off it via KRaft). ZK is a JVM, so it gets the agent too.

## Component choices

### HBase + Hadoop (single custom image)

A single Docker image (`docker/hadoop-hbase/`) bundles Hadoop and HBase
tarballs from the Apache mirrors. The image's entrypoint takes a role argument
(`namenode`, `datanode`, `hmaster`, `regionserver`, `zookeeper`) and starts the
right daemon in the foreground. This keeps the image build cached and avoids
maintaining five separate images that all need the same Java + agent + tarball
layout.

Pseudo-distributed means HBase talks to a real HDFS (one NameNode + one
DataNode), backed by an external ZooKeeper, with one HMaster and one
RegionServer. That's the smallest topology that exercises the full set of
HBase RPC paths you'd see in production.

The agent is baked into the image at `/opt/otel/opentelemetry-javaagent.jar`.
Each role's environment variable (`HBASE_MASTER_OPTS`, `HBASE_REGIONSERVER_OPTS`,
`HDFS_NAMENODE_OPTS`, `HDFS_DATANODE_OPTS`, `ZOO_CMD_OPTS`) prepends
`-javaagent:/opt/otel/opentelemetry-javaagent.jar` plus the resource attributes
that identify which service is reporting.

### Kafka

`apache/kafka` image in KRaft single-node mode. The agent is mounted into the
container at `/opt/otel/opentelemetry-javaagent.jar` (instead of being baked
into the image, since we don't control that image). `KAFKA_OPTS` adds the
`-javaagent:` flag and OTel resource attributes.

### Producer / Consumer

Two Maven modules under `apps/`:

- `producer` — emits synthetic sensor readings (`device_id`, `metric`,
  `value`, `timestamp`) as JSON to the `sensor.readings` topic at a configurable
  rate.
- `consumer` — polls `sensor.readings`, deserializes, and writes Puts to the
  HBase table `sensor_readings`. Auto-creates the table on startup.

Each app builds to a fat JAR via the Maven Shade plugin so the Dockerfile is
trivial: `FROM eclipse-temurin:17-jre`, copy fat JAR, copy agent JAR,
`ENTRYPOINT java -javaagent:/opt/otel/agent.jar -jar /app/app.jar`.

The agent picks up these environment variables from compose:

- `OTEL_SERVICE_NAME=producer` (or `consumer`, etc.)
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317`
- `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
- `OTEL_TRACES_EXPORTER=otlp`
- `OTEL_METRICS_EXPORTER=otlp`
- `OTEL_LOGS_EXPORTER=otlp`
- `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local`

### OpenTelemetry Collector

`otel/opentelemetry-collector-contrib` running with two OTLP receivers (gRPC on
4317, HTTP on 4318) and a `otlp` exporter pointed at Tempo's OTLP receiver
(port 4317). A `debug` exporter logs every span to stdout at `basic` verbosity
so the user can `docker compose logs otel-collector` to see traces flowing.

A `batch` processor and `memory_limiter` sit between receiver and exporter.

### Tempo

`grafana/tempo` running in monolithic mode (single binary, all components in
one process), backed by local-filesystem block storage. Receives OTLP gRPC on
4317 and serves Tempo's HTTP API on 3200 for Grafana. The Tempo JVM is *not*
in scope for tracing (it's the trace store; tracing it would be circular).

### Grafana

`grafana/grafana` with anonymous access enabled (Editor role). The Tempo
datasource is provisioned at startup via a YAML in `grafana/provisioning/`.
A starter dashboard is provisioned that shows recent traces by service name.

## Network and ports

All containers share a single Docker network. Only a few ports are forwarded
to the host:

| Service   | Host port | Container port | Purpose                |
|-----------|-----------|----------------|------------------------|
| Grafana   | 3000      | 3000           | UI                     |
| Tempo     | 3200      | 3200           | HTTP API (debug)       |
| Kafka     | 9092      | 9092           | Bootstrap (host tools) |
| HBase UI  | 16010     | 16010          | HBase Master UI        |
| HDFS UI   | 9870      | 9870           | NameNode UI            |
| Collector | 4317/4318 | 4317/4318      | OTLP (host tools)      |

## Why the OTel Collector and not direct-to-Tempo?

It mirrors what most production environments look like, and it gives a single
choke point for adding processors (sampling, attribute scrubbing, batching)
without touching application code. It also lets us flip the destination from
Tempo to something else (Jaeger, an APM vendor, stdout) by editing one file.

## Java agent: which version and how it's wired

The agent JAR is fetched at image build time from the
`opentelemetry-java-instrumentation` GitHub releases (pinned via build arg in
each Dockerfile and re-fetched if the version changes). It lives at
`/opt/otel/opentelemetry-javaagent.jar` inside every JVM container.

For our own Java apps we attach it via `ENTRYPOINT`. For Kafka, HBase, and
Hadoop we attach it via the `*_OPTS` environment variables those daemons honor
on startup. This means the entire wiring is declarative and visible in
`docker-compose.yml` — no shell-script glue.

## What you'll see in Tempo

A typical trace from one producer message looks like:

```
producer  send → Kafka producer.send  ──┐
                                        │
kafka     handle Produce request  ◀─────┘
kafka     handle Fetch request    ◀──────────┐
                                             │
consumer  poll → kafka.poll       ───────────┘
consumer  process record (manual span)
consumer  HBase Put              ───────┐
                                        ▼
hbase-rs  handle Put RPC
hbase-rs  WAL append    ───────────────┐
                                       ▼
hadoop-dn write block
```

The exact span layout depends on what the agent's instrumentation modules
cover; see the [OTel Java instrumentation supported libraries list](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/main/docs/supported-libraries.md).

## Known limitations

- This is a single-node setup. Replication, region splitting, and
  cross-broker traces will not appear.
- HBase's RPC instrumentation comes through Hadoop's IPC layer and may surface
  as generic `rpc.system=hadoop-rpc` spans rather than HBase-specific ones,
  depending on agent version.
- ZooKeeper instrumentation is shallow — the agent reports JVM metrics but the
  ZK protocol itself is not auto-instrumented. We include it primarily to show
  the JVM resource attributes flow through.
