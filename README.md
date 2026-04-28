# Kafka to HBase OTel Tracing Example

A self-contained Docker Compose environment for learning how OpenTelemetry's
Java agent auto-instruments JVM-based components in a realistic data pipeline.

## What's in the box

```
                          ┌─────────────┐
                          │   Grafana   │  http://localhost:3000
                          └──────┬──────┘
                                 │ queries
                                 ▼
                          ┌─────────────┐
                          │    Tempo    │  traces store
                          └─────────────┘
                                 ▲ OTLP gRPC
                                 │
                          ┌──────┴──────┐
                          │OTel Collector│  ◄── OTLP from every JVM
                          └──────▲──────┘      (gRPC :4317, HTTP :4318)
                                 │
   ┌─────────────────────────────┼──────────────────────────────────────┐
   │ OTLP from each agent        │                                      │
   │                             │                                      │
┌──┴──────┐  ┌────────┐  ┌───────┴───┐  ┌────────────┐  ┌──────────┐  ┌─┴────────┐
│ producer│  │ Kafka  │  │ consumer  │  │ hbase-     │  │ hadoop-  │  │ zoo-     │
│ (Java)  │─▶│ (KRaft)│─▶│ (Java)    │─▶│ master+rs  │─▶│ nn+dn    │  │ keeper   │
└─────────┘  └────────┘  └───────────┘  └────────────┘  └──────────┘  └──────────┘
 javaagent    javaagent    javaagent      javaagent      javaagent     javaagent
```

Every JVM in the picture has the OpenTelemetry Java agent attached. They all
push OTLP to a single Collector, which fans out to Tempo for traces and to a
debug exporter for metrics/logs (Tempo is traces-only). Grafana renders the
traces.

## What spans you'll actually see (and what you won't)

The OTel Java agent auto-instrumentation has uneven coverage across the
components in this lab. A quick map:

| JVM service           | Spans you'll see                                              |
|-----------------------|---------------------------------------------------------------|
| producer              | KafkaProducer.send (per record), JSON serialization           |
| consumer              | KafkaConsumer.poll, per-record consume span, HBase Put RPC    |
| hbase-master, -rs     | Some server-side spans for client RPCs (agent-version dep.)   |
| hadoop-namenode, -dn  | A handful of internal RPC / IPC spans, mostly sparse          |
| **kafka (broker)**    | **Almost nothing.** See note below.                           |
| **zookeeper**         | **Nothing useful.** ZK wire protocol is not instrumented.     |

The **Kafka broker** is configured to push OTLP — the agent loads, the
Collector receives — but the OTel Java agent's Kafka instrumentation
targets Kafka *clients* (`kafka-clients`, `kafka-streams`), not the broker
itself. The broker speaks a custom binary protocol the agent doesn't wrap,
so per-request "handle Produce / handle Fetch" spans never get created.
What it does emit: JVM metrics and logs, which land in the Collector's
debug exporter (visible via `docker compose logs otel-collector`) but
*not* in Tempo, because Tempo only stores traces.

The producer/consumer pair *does* propagate W3C Trace Context through
Kafka message headers, so you'll see a connected trace from
`producer.send` → `consumer.poll` → `consumer.processRecord` → HBase Put.
The broker hop is just opaque in the middle.

## Quick start

```bash
docker compose up --build -d
```

Then open Grafana at http://localhost:3000 (anonymous Editor access).
Pick the `Tempo` datasource and search by service name (`producer`,
`consumer`, `hbase-master`, `hbase-regionserver`, `hadoop-namenode`,
`hadoop-datanode`).

The producer starts emitting synthetic sensor telemetry to the
`sensor.readings` topic shortly after startup. The consumer auto-creates
the HBase table `sensor_readings` and writes rows keyed by
`device_id|reverse_ts`.

To verify the broker really *is* exporting (just non-trace data):

```bash
docker compose logs otel-collector | grep "service.name=kafka"
```

You should see metric/log batches tagged with that resource attribute.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design and component breakdown
- [docs/CHANGES.md](docs/CHANGES.md) — chronological change log

## Directory layout

```
.
├── apps/                 # Java producer + consumer (Maven multi-module)
├── docker/
│   ├── hadoop-hbase/     # Custom image bundling Hadoop + HBase
│   ├── kafka/            # Stock apache/kafka + OTel agent
│   └── zookeeper/        # Stock zookeeper + OTel agent
├── otel-collector/       # Collector pipeline config
├── tempo/                # Tempo storage + receiver config
├── grafana/              # Grafana provisioning (datasource + dashboards)
├── docs/                 # Architecture + change log
└── docker-compose.yml
```

## Tearing down

```bash
docker compose down -v
```

The `-v` removes the named volumes (HDFS data, Tempo blocks, Kafka logs).
