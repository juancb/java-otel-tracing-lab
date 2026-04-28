# Kafka → HBase OTel Tracing Example

A self-contained Docker Compose environment for learning how OpenTelemetry's
Java agent auto-instruments JVM-based components in a realistic data pipeline.

## What's in the box

```
                                                       ┌─────────────┐
                                                       │   Grafana   │
                                                       └──────┬──────┘
                                                              │ queries
                                                              ▼
                                                       ┌─────────────┐
                                                       │    Tempo    │
                                                       └─────────────┘
                                                              ▲ OTLP
                                                              │
                                                       ┌─────────────┐
                                                       │OTel Collector│
                                                       └─────────────┘
                                                              ▲ OTLP
                                              ┌───────────────┼────────────────┐
                                              │               │                │
┌────────────┐   sensor    ┌────────┐   poll  │           ┌───┴────┐    ┌──────┴──────┐
│  producer  ├────────────▶│ Kafka  ├────────▶│ consumer  │ HBase  │    │   Hadoop    │
│  (Java)    │   topic     │ (KRaft)│   topic │  (Java)   ├───────▶│Master+RS│   NN+DN│
└────────────┘             └────────┘         └───────────┘└────────┘    └─────────────┘
   javaagent                javaagent           javaagent     javaagent      javaagent
```

Every JVM in the picture has the OpenTelemetry Java agent attached. They all
push OTLP to a single Collector, which fans out to Tempo. Grafana renders the
traces.

## Quick start

```bash
docker compose up --build -d
```

Then open Grafana at http://localhost:3000 (anonymous access enabled).
Pick the `Tempo` datasource and search by service name (`producer`,
`consumer`, `kafka`, `hbase-master`, `hbase-regionserver`, `hadoop-namenode`,
`hadoop-datanode`).

The producer starts emitting synthetic sensor telemetry to the
`sensor.readings` topic shortly after startup. The consumer auto-creates the
HBase table `sensor_readings` and writes rows keyed by `device_id|reverse_ts`.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design and component breakdown
- [docs/CHANGES.md](docs/CHANGES.md) — chronological change log

## Directory layout

```
.
├── apps/                 # Java producer + consumer (Maven multi-module)
├── docker/
│   ├── hadoop-hbase/     # Custom image bundling Hadoop + HBase
│   └── otel/             # OTel Java agent download
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
