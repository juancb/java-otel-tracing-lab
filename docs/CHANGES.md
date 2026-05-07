# Changes

A chronological log of what was built and why. Newest entries first.

## 2026-05-06 - Consumer: per-record HBase puts (fix consumer→RS trace gap)

A Tempo screenshot exposed a propagation gap: producer→consumer was linking
correctly via Kafka W3C `traceparent` headers, but the consumer's HBase puts
were appearing as separate root traces. The Tempo service graph confirmed it
with a missing `consumer → hbase-regionserver` edge (`query-client → RS`
showed up fine).

**Root cause** in `apps/consumer/src/main/java/com/example/lab/consumer/Consumer.java`:
the consumer accumulated `Put`s into a `List<Put>` inside the
`for (ConsumerRecord rec : batch)` loop and called `table.put(puts)` *after*
the loop ended. The OTel agent's kafka-clients instrumentation activates a
`sensor.readings process` span only for the duration of each iteration body —
by the time the batched `table.put(puts)` ran, no `Context.current()` span
was active, so the HBase client span started a brand-new root trace. HBase
2.5's native server-side OTel still produced its `RpcServer.process` etc.
spans, but they descended from that orphan root.

**Fix:** move `table.put(rec)` inside the for-loop. Each record's put now
runs while that record's process span is `Context.current()`, so the HBase
client span attaches as its child and HBase 2.5's RPC tracing continues the
trace into the RegionServer. The full waterfall is now in one trace ID:

```
producer: sensor.readings publish
  consumer: sensor.readings process
    consumer: hbase.client.put
      hbase-regionserver: RpcServer.process
        hbase.pb.ClientService/Mutate
          WAL.append
```

**Tradeoffs:**

- HBase RPCs go from ~0.3-1/sec (batched) to ~5/sec (per-record) at default
  `RATE_PER_SEC=5`. Negligible for a lab; not the right pattern for a high-
  throughput production consumer (in production, the right answer is a manual
  span wrapping the batched put with span links to each record's context).
- Chaos break semantics shift slightly: previously a `ChaosException` skipped
  the entire batch (no records written). Now records written before the break
  stay; on Kafka redelivery they get written again. Row keys
  (`deviceId|reverseTs`) make the cell-level overwrite idempotent for our
  synthetic data, so this is safe.

The `apps/consumer/.../Consumer.java` Javadoc and inline comment now explain
the per-record design choice and reference this changelog entry.

## 2026-04-29 - Removed Kubernetes + Cilium production track

Tried, learned, removed. The `cilium/` directory, `docs/K8S_PROJECTION.md`,
`docs/ROADMAP2.md`, `grafana/provisioning/dashboards/hubble-l7.json`, and the
"Production Track" section of `docs/ROADMAP.md` are gone. Full implementation
is preserved in commits `37e9261`, `54b7e98`, and earlier — accessible via
`git log` if needed.

**What we built (commits 37e9261, 54b7e98):**
- kind cluster with Cilium 1.19.1 + Hubble; 19 pods (observability +
  data plane) running; HTTP L7 policies on Jetty UIs working; gRPC L7
  policy on OTLP collector working at L4.

**Why we removed it:**
- Cilium's Kafka L7 support relies on **proxylib**, which is removed in
  Cilium 1.20 ([PR #43557](https://github.com/cilium/cilium/pull/43557),
  [#45644](https://github.com/cilium/cilium/pull/45644)). The `role: produce` /
  `role: consume` rules in CiliumNetworkPolicy were already broken in 1.19
  (DROPPED Kafka 3.8 protocol v9+ Produce requests; topic always rendered
  as `''`). The headline reason for trying Cilium L7 — broker-side Kafka
  topic visibility — is no longer feasible upstream.
- HTTP L7 visibility on Jetty UIs and gRPC L7 on OTLP do work, but they
  duplicate signals the OTel Java agent already captures as SERVER spans.
  No new information, additional infrastructure to maintain.
- Future production deployments needing broker-side Kafka enforcement
  should use `CiliumEnvoyConfig` with Envoy's native Kafka filter, not
  the deprecated `CiliumNetworkPolicy` Kafka rules.

**What stays:**
- Compose-based lab (Stages A-E) is the supported development environment.
- OTel Java agent for application-level Kafka observability — topic names
  are in span attributes, surface in Tempo/Grafana via span-metrics.

**Infrastructure side-effects from the experiment that benefit the host:**
- Docker Desktop auto-upgraded from 20.10.17 (2022) to 29.4.1 during the
  WSL restart needed to enable cgroup v2.
- `~/.wslconfig` now forces cgroup v2 (harmless to Compose, helpful for
  future kind/k3d work).
- kind, helm, cilium-cli, hubble-cli installed via winget (idle, no impact).

## 2026-04-28 - service-map dashboard: dropdown + drill-in panel

Workaround for a Grafana 11 quirk: when Node Graph is fed by Tempo's
`serviceMap` query type, Tempo injects its own click menu (Request rate
/ Histogram / Failed rate / View traces) and overrides any custom data
links from `fieldConfig.defaults.links`. Result: the "Open service
detail for ${service}" link we'd configured silently never rendered.

Fix without giving up the Node Graph:

- Added a `service` template variable to `service-map.json`, populated
  from `label_values(traces_spanmetrics_calls_total, service)`. Picks
  up new services (like query-client) automatically.
- New stat panel above the Node Graph showing the selected service
  with a clickable data link straight to the service-detail dashboard.
  No mystery click affordance — the entire panel is the link.
- New markdown panel next to it with explicit URLs to the detail
  dashboard, Loki Explore for the same service, and the JMX
  dashboards. Useful even if the user prefers a typed approach.
- Existing Node Graph + RED + JVM panels pushed down 3 rows; their
  per-field data links remain in place for the time-series panels
  (those still work fine, only the Node Graph was the broken case).

## 2026-04-28 - Stage E (partial): query-client + in-app chaos

Adds read-side traffic and a probabilistic chaos hook so the dashboards
and traces can be exercised independently of the steady producer/consumer
flow. Closes the read/write asymmetry in the service map.

- New `apps/query-client/` Java module. Round-robins three modes per tick
  (interval = `QUERY_INTERVAL_MS`, default 2s):
  1. **scan** — Scan latest N rows from `sensor_readings`, capped by
     `SCAN_LIMIT` (default 20).
  2. **get** — Prefix scan limited to 1 for a randomly-picked
     `device-####`, returning the newest reading. Demonstrates point
     lookup latency and the BlockCache.
  3. **increment** — atomic Increment on a counter cell on a shared row
     in `sensor_counters` (table created on first run), then a Get to
     read it back. Exercises the WAL + memstore path and gives a clean
     read-after-write span pair in Tempo.

  OTel agent attached at runtime, so each operation shows up as a
  hbase-client span and its log lines carry the trace_id MDC injected
  by `logback-mdc-1.0`.

- New shared `Chaos.java` (one copy per module's package — small enough
  not to warrant a separate Maven module). Two dice per call to
  `Chaos.maybe(tag)`:
  1. With probability `CHAOS_LATENCY_PROB`, sleep a uniform-random
     duration in `[CHAOS_LATENCY_MS_MIN, CHAOS_LATENCY_MS_MAX]`.
  2. With probability `CHAOS_ERROR_PROB`, throw `ChaosException`.
  Sleep happens *first* so the latency lands inside the OTel-instrumented
  span. Errors are caught at the call site:
  - producer.send → skip the iteration, sleep, continue.
  - consumer.put → skip the batch *and* skip Kafka commit, so the broker
    redelivers next poll. Exercises the rebalance path.
  - query.{scan,get,increment} → log + skip the tick.

  All probabilities default to 0, so the lab is a no-op until you turn
  chaos on.

- `docker-compose.yml`: new `query-client` service with chaos env vars.
  Producer + consumer get the same chaos vars (defaulted to 0) so you
  can target chaos at any single layer.

- `apps/pom.xml`: added `query-client` module. Existing producer +
  consumer Dockerfiles updated to `COPY query-client/pom.xml` because
  the parent pom now references it (Maven's reactor wants every module
  pom on disk even with `-pl`).

How to drive it once it's up:
  # Make the consumer dashboard light up:
  docker compose stop consumer
  CHAOS_LATENCY_PROB=0.2 CHAOS_LATENCY_MS_MAX=800 \
    docker compose up -d consumer
  # ...wait 2 minutes, watch p99 climb in service-map dashboard...
  CHAOS_LATENCY_PROB=0 docker compose up -d consumer

  # Or hit the read path:
  docker compose stop query-client
  CHAOS_ERROR_PROB=0.1 docker compose up -d query-client
  # ...look for ChaosException entries in Loki for service=query-client...

## 2026-04-28 - Healthcheck and volume fixes (kafka, loki)

Stage C uncovered two boot-ordering bugs that only surfaced after the
producer/consumer were stable enough to consistently exercise the
dependency graph.

- `docker-compose.yml` (kafka healthcheck): replaced
  `kafka-topics.sh --list` with a bash `/dev/tcp/localhost/9092` probe.
  The CLI inherits `KAFKA_OPTS` (which chains the OTel + JMX exporter
  agents), so every healthcheck did class transformation on a fresh JVM
  and timed out. Producer/consumer were stuck in `Created` state because
  their `depends_on: kafka: service_healthy` never resolved.

- `loki/config.yaml` + `docker-compose.yml` (loki volume): moved Loki's
  data path from `/var/loki` to `/loki`. The Loki 3.x image runs as uid
  10001 and pre-creates `/loki` with that ownership. A named volume
  mounted at `/loki` inherits the perms; mounted at `/var/loki` (which
  doesn't exist in the image), Docker creates the dir root-owned and
  Loki crashes with EACCES on `mkdir /var/loki/chunks`.

Migration note: existing `loki-data` named volumes were initialized
under the old path and stay root-owned even after the config change.
Drop and recreate:
  docker compose stop loki
  docker volume rm <project>_loki-data
  docker compose up -d loki

## 2026-04-28 - Switch HBase to log4j2 (HBASE-26802)

Closes the last gap in trace<->log correlation: HBase RegionServer / Master
log lines now carry the `traceId=` of the span they were emitted under.

The OTel Java agent ships two MDC instrumentations: `logback-mdc-1.0` (used
by producer/consumer) and `log4j-mdc-1.0`. The latter only hooks log4j 2.x
APIs, not log4j 1.x / reload4j. Our HBase daemons were running on log4j 1.x
via the existing `log4j.properties`, so `%X{trace_id}` always rendered
empty. HBASE-26802 (landed in 2.5.0) migrates HBase to log4j2; the 2.5.8
distribution already ships the log4j2 jars in
`lib/client-facing-thirdparty/`. We just needed to feed it a config file.

Changes:

- New `docker/hadoop-hbase/conf/log4j2.properties`: log4j2 syntax (root
  logger, console appender, per-package levels). Pattern preserves the
  Stage C layout: `traceId=%X{trace_id} spanId=%X{span_id}`.
- `docker/hadoop-hbase/Dockerfile`: copy `log4j2.properties` into HBase's
  `conf/` dir. The old `log4j.properties` is still copied (Hadoop daemons
  consume it) and is also placed in `HADOOP_CONF_DIR` explicitly.
- `docker/hadoop-hbase/entrypoint.sh`: defines `HBASE_LOG4J2_OPT` =
  `-Dlog4j2.configurationFile=file:$HBASE_CONF_DIR/log4j2.properties` and
  prepends it to `HBASE_MASTER_OPTS` / `HBASE_REGIONSERVER_OPTS`. Hadoop
  daemons are unchanged.

Scope decision: Hadoop NameNode/DataNode stay on log4j 1.x. Switching
Hadoop to log4j2 means fighting the Hadoop classpath (reload4j is pulled
in transitively), and the spans we care about for this lab live in HBase
RegionServers, not Hadoop daemons. NN/DN log lines will still show empty
`traceId=` — acceptable trade for not destabilizing the build.

Verify after `docker compose up -d --build hbase-master hbase-regionserver`:
- `docker compose logs hbase-regionserver | grep traceId=` should now show
  non-empty trace IDs on lines emitted while servicing client RPCs.
- In Grafana Loki Explore, `{service="hbase-regionserver"}` lines should
  carry traceId values that link (via `derivedFields`) to Tempo traces.

## 2026-04-28 - Stage C: Loki + Alloy + trace-id correlation

Closes the trace<->logs gap. Click a slow span in Tempo Explore -> jump to
the exact log lines that produced it.

- New `loki/config.yaml`: single-binary Loki with TSDB indexes, local
  filesystem chunks, 72h retention, structured-metadata enabled.
- New `alloy/config.alloy`: Grafana Alloy discovers all containers via the
  Docker socket, scrapes stdout/stderr, ships log lines to Loki labelled
  by `service` (compose service name) and `container` (container name).
- `docker-compose.yml`: added `loki` (port 3100) and `alloy` (port 12345)
  services. Grafana now `depends_on: loki: service_healthy` so the Loki
  datasource provisions cleanly on first start. Two new volumes:
  `loki-data`, `alloy-data`.
- `apps/{producer,consumer}/src/main/resources/logback.xml`: log pattern
  now prefixes every line with `traceId=%X{trace_id:-} spanId=%X{span_id:-}`.
  The OTel Java agent's logback-mdc-1.0 instrumentation populates these
  MDC keys whenever the calling thread is inside a span.
- `docker/hadoop-hbase/conf/log4j.properties`: matching change for HBase
  and Hadoop daemons (log4j 1.x equivalent of the logback pattern).
- `grafana/provisioning/datasources/loki.yaml`: new datasource. Configured
  `derivedFields` so any `traceId=<id>` matched in a log line renders as a
  clickable link to the Tempo datasource for that trace.
- `grafana/provisioning/datasources/tempo.yaml`: added `tracesToLogsV2`
  config. In Tempo Explore, every span now offers a "Logs for this span"
  button that pivots into Loki, filtered to `{service="<name>"} |= "<traceId>"`.
- New dashboard `grafana/provisioning/dashboards/logs.json`: live log tail
  across all services with a `service` template variable.
- Service-detail dashboard now has a "Logs for ${service}" link in its
  header.

Operator workflow this enables:
1. Service map / RED dashboard shows consumer p99 spike at 14:23.
2. Click the consumer node -> service-detail dashboard, "Recent traces" panel.
3. Click a slow trace -> Tempo Explore opens that trace.
4. Click "Logs for this span" on the consumer's HBase Put span ->
   filtered Loki query showing the consumer's log lines for *that* trace.
5. Bingo: the actual stack trace / message that explains the latency.

## 2026-04-28 - Stage B: JMX scrapers + service-graph join

Adds the metrics that the Java agent's auto-instrumentation can't produce
on its own: server-side broker, RegionServer, NameNode, DataNode internal
metrics. Plus the Collector-level rewrite that finally joins the
disconnected service graph from Stage A.

- `jmx-exporter/`: three YAML rule sets (kafka, hbase, hadoop) for the
  jmx_prometheus_javaagent. Capture request rates, queue depths, JVM, and
  HBase WAL/region activity with tidy Prometheus naming.
- Both Dockerfiles (`docker/hadoop-hbase`, `docker/kafka`) bake in
  `jmx_prometheus_javaagent-1.0.1.jar` at `/opt/jmx-exporter/`. The
  agent JAR sits next to the OTel agent; both attach as separate
  `-javaagent:` flags.
- `docker/hadoop-hbase/entrypoint.sh`: each role chains both javaagents,
  with role-specific JMX exporter port + config:
  - hbase-master       :7072 -> hbase.yaml
  - hbase-regionserver :7073 -> hbase.yaml
  - hadoop-namenode    :7074 -> hadoop.yaml
  - hadoop-datanode    :7075 -> hadoop.yaml
- Kafka's `KAFKA_OPTS` chains both agents; JMX exporter on :7071 ->
  kafka.yaml. compose exposes the host-side port.
- `prometheus/prometheus.yml`: five new `scrape_configs` (kafka,
  hbase-master, hbase-regionserver, hadoop-namenode, hadoop-datanode).
- `otel-collector/config.yaml`: new `transform/peer_service` processor on
  the traces pipeline. Rewrites HBase 2.5+'s hard-coded
  `peer.service=hbase` to `hbase-regionserver`, which collapses the
  disjoint `consumer -> hbase` cluster in the service graph onto the
  real `hbase-regionserver` node.
- `grafana/provisioning/dashboards/jmx-services.json`: new dashboard with
  rows for Kafka broker, HBase RegionServer, HDFS NN/DN.
- New host ports: 7071-7075 (JMX exporter scrape ports, also reachable
  by Prometheus from inside the lab network on the same numbers).
- `docs/DEV_NOTES.md`: written-down workflow for the NTFS lockfile +
  Write-truncation quirks so future sessions don't re-discover them.

After rebuild and restart you should see:
- Five new green scrape jobs at http://localhost:9090/targets
- Per-component panels populating in the new "JMX" dashboard
- Service Graph in Tempo showing `consumer -> hbase-regionserver`
  (single connected component, not disjoint anymore) once a few minutes
  of producer traffic have flowed through

## 2026-04-28 - Stage A verified working + service-graph documentation

The end-to-end pipeline is up: producer -> Kafka -> consumer -> HBase ->
HDFS, with traces flowing through the Collector and into Tempo. The Stage
A service graph in Grafana renders, with the expected caveats:

- Two disconnected clusters in the graph: the top cluster
  (user -> hadoop-namenode/datanode/hbase-master/regionserver) is from
  Docker healthcheck curl traffic hitting Jetty; the bottom cluster
  (consumer -> hbase) is from HBase's built-in OTel client-side spans.
- The bottom cluster's `hbase` is a phantom node because HBase 2.4+ hard-
  codes `peer.service=hbase` in its tracing, which doesn't match the
  per-role service.name (`hbase-regionserver`, `hbase-master`).
- New `docs/SERVICE_GRAPH.md` documents this and explains what Stage B
  will fix.

Mid-flight fixes that were needed to get here:

- Switched consumer from `hbase-client` to `hbase-shaded-client` to
  resolve a Hadoop split-classpath NoSuchMethodError on
  HadoopKerberosName.setRuleMechanism (3.2.4 hadoop-auth vs 3.3.6
  hadoop-common transitive versions).
- Removed the otel-collector healthcheck (the contrib image is distroless
  - no shell/wget/nc), and switched dependents to `condition: service_started`.
- Moved `out_of_order_time_window` from CLI flag (rejected by Prometheus)
  into prometheus.yml under `storage.tsdb`.

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
