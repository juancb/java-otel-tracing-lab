# Changes

A chronological log of what was built and why. Newest entries first.

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
- `grafana/provisioning/datasources/tempo.y