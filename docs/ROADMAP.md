# Roadmap

The current lab gives you traces from the JVMs. That's enough to see *what
happened* when traffic flows, but not enough to debug *why* something is slow
or broken. The roadmap below extends the lab into a small but realistic
observability stack — dependency modeling, root-cause walks, and alerting.

Stages are ordered by leverage. Each one depends on the previous and is
designed to drop in without rewriting what's already there.

## Diagnostic flow we're aiming for

> Alert fires "consumer p99 > 500ms"
> → open the consumer dashboard, see the latency spike at 14:23
> → service-graph panel shows the `consumer → hbase-regionserver` edge red
> → click into RegionServer dashboard: RPC queue climbing, GC pause spiking
> → container-stats panel: RegionServer at 99% CPU, restarted twice
> → click "logs for this trace" on a slow consumer span: Loki shows the stack

Today's lab covers step 1 (alerts? no), step 2 (RED dashboard? no), step 3
(service graph? no), step 4 (server-side metrics? no), step 5 (container
stats? no), step 6 (logs? no). Each stage below adds one of those rungs.

## Stage A — Prometheus + service-map

The single highest-value addition. Everything else in the roadmap depends on
having a metrics store.

- Add `prom/prometheus` to `docker-compose.yml`.
- Tempo's `metrics_generator` is already enabled (`service-graphs`,
  `span-metrics`); point its `remote_write` at Prometheus.
- Add a `prometheusremotewrite` exporter to the OTel Collector's metrics
  pipeline.
- Provision the Prometheus datasource in `grafana/provisioning/`.
- Add an "OTel Lab — service map" dashboard:
  - Node Graph panel from service-graph metrics.
  - RED panels per service from span-metrics histograms.
  - JVM heap / GC pause panels from agent metrics.

**What this buys you:** dependency graph derived from observed traffic, and
per-service rate/error/latency you can pivot on.

## Stage B — JMX scrapers for Kafka, HBase, Hadoop

The Java agent doesn't trace the broker / RegionServer / NameNode. JMX is
the next-best signal — it's the components' own internal view.

- Add `jmxreceiver` blocks to the Collector config:
  - `target_system: kafka` → `kafka.network.RequestMetrics`,
    `kafka.server.BrokerTopicMetrics`.
  - HBase: scrape RegionServer / Master MBeans for RPC queue depth, GC,
    region count, store file size.
  - Hadoop: scrape NameNode / DataNode for RPC processing time, queue depth,
    capacity used.
- Per-component dashboards in Grafana (one each: kafka-broker,
  hbase-regionserver, hdfs-namenode).

**What this buys you:** server-side latency and queue-depth signals for the
parts of the trace that are otherwise opaque.

**Depends on:** Stage A (metrics need somewhere to land).

## Stage C — Loki + Alloy + trace-id correlation

Traces tell you what; logs tell you why. Linking them is the difference
between "consumer threw an exception" and "consumer threw
RegionTooBusyException because the RS heap was at 92%".

- Add `grafana/loki` to compose.
- Add `grafana/alloy` (or Promtail) tailing each container's Docker logs,
  attaching `container.name` + derived `service.name` labels.
- Update logback patterns in producer/consumer to include `%X{trace_id}`
  / `%X{span_id}` (the OTel Java agent's `logback-mdc` instrumentation
  populates the MDC automatically when active).
- Add Loki datasource. Configure the Tempo datasource's `tracesToLogsV2`
  so clicking a span jumps to a filtered Loki query at that timestamp +
  trace-id.

**What this buys you:** click a slow span → see that exact request's logs.

## Stage D — Container metrics + Grafana alerting

The two ingredients that turn the stack from a debugging viewer into a
proactive system.

- Add `dockerstatsreceiver` to the Collector. Pulls per-container CPU /
  memory / network / disk from the Docker daemon socket.
- Container-resources dashboard in Grafana, keyed by `container.name`.
- Configure Grafana Unified Alerting rules:
  - error rate per service > 0 for 1min
  - p99 latency per service > threshold (set per service)
  - JVM heap > 90% for 2min
  - container restart count in 5min > 0
  - Kafka `UnderReplicatedPartitions` > 0
  - HBase RegionServer count drops (live - dead delta)

**What this buys you:** something *tells* you the system is broken, and you
can distinguish "app is slow" from "container is throttled".

**Depends on:** Stages A + B (alerts query their metrics).

## Stage E — Synthetic probes + chaos drill

Validation. Without this, you don't know whether the dashboards and alerts
actually catch real failures.

- Add `httpcheckreceiver` for /ready endpoints (tempo, grafana, namenode UI,
  hbase-master UI) and `tcpcheckreceiver` for kafka:9092 and zookeeper:2181.
- Write `docs/RUNBOOK.md`: 3-4 deliberately-broken scenarios with expected
  symptoms in each dashboard / alert. Suggested scenarios:
  - `docker compose stop hbase-regionserver` — what fires?
  - `docker compose run --cpus=0.1 consumer` — does latency alert fire?
  - Pause GC on the producer (`-XX:+UseSerialGC -Xmx32m`) — does heap alert
    catch it before user-visible latency?
  - Block port between consumer and ZK with iptables — what dashboard
    surfaces the symptom first?

**What this buys you:** confidence that the observability stack pays off.

**Depends on:** Stage D.

## Out of scope (intentionally)

- A real metrics-long-term-storage backend (Mimir, Thanos). For a laptop
  lab Prometheus's local TSDB is fine.
- Multi-tenancy in any of the data stores.
- TLS / auth between any of the components. This is a sandbox.
- Production-grade Kafka or HBase tuning. This lab is about *seeing* the
  system, not running it well.
