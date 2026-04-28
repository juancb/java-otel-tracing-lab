# Architecture

This project exists to make OpenTelemetry's Java agent auto-instrumentation
visible across a realistic JVM data pipeline. The goal is *understanding*,
not production fitness — so everything runs as a single-node, pseudo-distributed
cluster on a developer laptop.

## Goals

1. Every JVM-based component runs with the OTel Java agent attached so we can
   see what auto-instrumentation does without writing any tracing code.
2. A real data flow runs end-to-end: producer -> Kafka -> consumer -> HBase
   (HBase in turn uses HDFS and ZooKeeper, so those JVMs show up in traces too).
3. Traces are queryable in Grafana through Tempo, so the developer experience
   matches what we'd encounter in a production observability stack.
4. As much as possible is encoded in version-controlled files (Dockerfiles,
   compose, site XMLs, agent config) so the environment is reproducible.

## Topology

```
                          ┌─────────────┐
                          │   Grafana   │
                          └──────┬──────┘
                                 │ queries
                                 ▼
                          ┌─────────────┐
                          │    Tempo    │
                          └─────────────┘
                                 ▲ OTLP gRPC
                                 │
                          ┌──────┴──────┐
                          │OTel Collector│
                          └──────▲──────┘
                                 │
   ┌─────────────────────────────┼──────────────────────────────────────┐
   │ OTLP from each agent        │                                      │
┌──┴──────┐  ┌────────┐  ┌───────┴───┐  ┌────────────┐  ┌──────────┐  ┌─┴────────┐
│ producer│─▶│ Kafka  │─▶│ consumer  │─▶│ hbase-     │─▶│ hadoop-  │  │ zoo-     │
│ (Java)  │  │ (KRaft)│  │ (Java)    │  │ master+rs  │  │ nn+dn    │  │ keeper   │
└─────────┘  └────────┘  └───────────┘  └────────────┘  └──────────┘  └──────────┘
 javaagent    javaagent    javaagent      javaagent      javaagent     javaagent
```

ZooKeeper is included for HBase coordination (HBase still requires ZK; only
Kafka has moved off it via KRaft). ZK is a JVM, so it gets the agent too.

## What auto-instrumentation actually covers (and doesn't)

Loading the OTel Java agent is necessary but not sufficient for spans to
appear. The agent only emits a span when it has an instrumentation module
that wraps a code path the program actually executes. Coverage in this lab:

| JVM service          | What the agent emits                                            |
|----------------------|-----------------------------------------------------------------|
| producer             | One `KafkaProducer.send` span per record, with W3C trace context written into Kafka headers. |
| consumer             | `KafkaConsumer.poll` span per poll, per-record process span, and an HBase client span for each `Put` (which itself wraps the underlying RPC). The trace links back to the producer's send via the propagated headers. |
| hbase-master, -rs    | Sparse server-side spans for incoming client RPCs, depending on which agent version you run. The HBase server instrumentation in the OTel Java agent is partial. |
| hadoop-namenode, -dn | A few RPC/IPC spans, mostly sparse. |
| **kafka (broker)**   | **Almost no spans.** The agent loads, JVM metrics flow to the Collector, but the Kafka *broker* protocol is not auto-instrumented (the agent's Kafka modules target `kafka-clients` and `kafka-streams` — i.e. *clients*, not the broker). |
| **zookeeper**        | JVM metrics only. The ZK wire protocol is not instrumented. |

Tempo stores traces only. JVM metrics and log records that the agent emits
flow to the Collector, are stamped with the right service.name resource
attribute, and end up in the Collector's `debug` exporter — visible via
`docker compose logs otel-collector` — but they don't appear in Grafana
because we don't run a metrics or logs backend in this lab.

So the trace picture you'll actually see in Grafana:

```
producer.send  ─┐
                │  W3C trace context in Kafka headers
                │  (broker hop is opaque)
                ▼
consumer.poll → consumer.processRecord → hbase.client.put → (server-side spans, partial)
```

If you want to see broker-side request handling, you need a different
instrumentation path — the JVM agent isn't going to give you that today.
The closest options are: (a) Kafka's own JMX metrics (`kafka.network`,
`RequestMetrics`), scraped through the OTel Collector's `jmxreceiver`;
(b) Strimzi's experimental Kafka tracing patches; (c) a service-mesh
sidecar that traces TCP-level connections.

## Component choices

### HBase + Hadoop (single custom image)

A single Docker image (`docker/hadoop-hbase/`) bundles Hadoop and HBase
tarballs. The image's entrypoint takes a role argument (`namenode`,
`datanode`, `hmaster`, `regionserver`) and starts the right daemon in the
foreground. This keeps the image build cached and avoids maintaining four
separate images that all need the same Java + agent + tarball layout.

Pseudo-distributed means HBase talks to a real HDFS (one NameNode + one
DataNode), backed by an external ZooKeeper, with one HMaster and one
RegionServer. That's the smallest topology that exercises the full set of
HBase RPC paths you'd see in production.

The agent is baked into the image at `/opt/otel/opentelemetry-javaagent.jar`.
Each role's environment variable (`HBASE_MASTER_OPTS`, `HBASE_REGIONSERVER_OPTS`,
`HDFS_NAMENODE_OPTS`, `HDFS_DATANODE_OPTS`) prepends `-javaagent:...` plus
the resource attributes that identify which service is reporting.

### Kafka

`apache/kafka` image in KRaft single-node mode, with the OTel agent layered
in via a small multi-stage Dockerfile (`docker/kafka/Dockerfile`).
`KAFKA_OPTS` adds the `-javaagent:` flag and OTel resource attributes. The
agent loads and connects to the Collector — but as noted above, the broker
itself doesn't produce useful traces.

### ZooKeeper

`zookeeper:3.9` image with the agent layered in the same way. The agent's
JVM auto-instrumentation produces a couple of resource-tagged metric
batches; nothing useful at the protocol level.

### Producer / Consumer

Two Maven modules under `apps/`. Each builds a fat JAR via the Maven Shade
plugin so the Dockerfile can stay trivial: copy the fat JAR, copy the
agent JAR, set `JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/agent.jar`. The
agent picks up these environment variables from compose:

- `OTEL_SERVICE_NAME=producer` (or `consumer`, etc.)
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317`
- `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
- `OTEL_TRACES_EXPORTER=otlp`
- `OTEL_METRICS_EXPORTER=otlp`
- `OTEL_LOGS_EXPORTER=otlp`
- `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local-otel-lab`

### OpenTelemetry Collector

`otel/opentelemetry-collector-contrib` with two OTLP receivers (gRPC on
4317, HTTP on 4318) and a `otlp` exporter pointed at Tempo's OTLP receiver.
A `debug` exporter logs every span/metric/log batch to stdout at `basic`
verbosity, so the developer can verify *everything* is flowing — including
the metric/log streams from Kafka and ZK that wouldn't appear in Tempo.
A `batch` processor and `memory_limiter` sit between receiver and exporter.

### Tempo

`grafana/tempo` running in monolithic mode (single binary, all components in
one process), backed by local-filesystem block storage. Receives OTLP gRPC on
4317 and serves Tempo's HTTP API on 3200 for Grafana. The Tempo JVM is *not*
in scope for tracing (it's the trace store).

### Grafana

`grafana/grafana` with anonymous access enabled (Editor role). The Tempo
datasource is provisioned at startup via a YAML in `grafana/provisioning/`.
A starter dashboard with TraceQL panels per service is also provisioned.

## Network and ports

All containers share a single Docker network. Only a few ports are forwarded
to the host:

| Service   | Host port | Container port | Purpose                |
|-----------|-----------|----------------|------------------------|
| Grafana   | 3000      | 3000           | UI                     |
| Tempo     | 3200      | 3200           | HTTP API (debug)       |
| Kafka     | 29092     | 29092          | Bootstrap (host tools) |
| HBase UI  | 16010     | 16010          | HBase Master UI        |
| HDFS UI   | 9870      | 9870           | NameNode UI            |
| Collector | 4317/4318 | 4317/4318      | OTLP (host tools)      |

## Why an OTel Collector and not direct-to-Tempo?

It mirrors what most production environments look like, and it gives a single
choke point for adding processors (sampling, attribute scrubbing, batching)
without touching application code. It also lets us flip the destination from
Tempo to something else (Jaeger, an APM vendor, stdout) by editing one file.

## Java agent: which version and how it's wired

The agent JAR is fetched at image build time from the
`opentelemetry-java-instrumentation` GitHub releases (pinned via build arg
in each Dockerfile). It lives at `/opt/otel/opentelemetry-javaagent.jar`
inside every JVM container.

For our own Java apps we attach it via `JAVA_TOOL_OPTIONS`. For Kafka, HBase,
Hadoop, and ZooKeeper we attach it via the `*_OPTS` env vars those daemons
honor on startup. The wiring is declarative and visible in `docker-compose.yml`
plus the per-service Dockerfile — no shell-script glue.

## Service graph notes

The Stage A Service Graph (Grafana Explore -> Tempo -> Service Graph) splits
into two disconnected clusters because two different sources of spans don't
overlap: healthcheck-driven Jetty server spans (top cluster, attributed to a
synthetic `user` client) and HBase client spans (bottom cluster, dangling
into a phantom `hbase` node because HBase's built-in tracing hard-codes
`peer.service=hbase`). [docs/SERVICE_GRAPH.md](SERVICE_GRAPH.md) walks
through what each piece means and what Stage B will do to merge them.

## Known limitations

- Single-node setup. Replication, region splitting, and cross-broker
  scenarios won't appear.
- Kafka broker, ZooKeeper, HBase server, and Hadoop daemon traces are
  sparse-to-empty for the reasons described in "What auto-instrumentation
  actually covers" above. The agent loads everywhere, but auto-instrumentation
  isn't magic — it only emits spans where it has matching modules.
- The metrics and logs streams flow into the Collector but stop at the
  debug exporter. To see them in Grafana you'd need to add a
  Prometheus/Loki backend (or remote-write to whatever you use elsewhere).
