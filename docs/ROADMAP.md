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

## Stage C - Loki + Alloy + trace-id correlation  [DONE]

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

**Done so far (read-side traffic + in-app chaos):**
- `apps/query-client/`: round-robins Scan / Get / Increment-and-read against
  HBase. OTel agent attached so reads show up as their own service in the
  service map and in RED panels (distinguishable from the consumer's writes).
- `apps/.../Chaos.java` shared utility wired into producer, consumer, and
  query-client. Per-operation probabilistic latency / errors via
  `CHAOS_LATENCY_PROB`, `CHAOS_LATENCY_MS_MIN/MAX`, `CHAOS_ERROR_PROB`.
  Defaults to 0 (off) so flipping it on is purely a deploy-time concern.

**Still TODO:**
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
  - Crank `CHAOS_LATENCY_PROB=0.2` on the consumer for 5 minutes — do
    p99 + error-rate alerts catch it?

**What this buys you:** confidence that the observability stack pays off.

**Depends on:** Stage D for the alert-firing scenarios.

## Out of scope (intentionally)

- A real metrics-long-term-storage backend (Mimir, Thanos). For a laptop
  lab Prometheus's local TSDB is fine.
- Multi-tenancy in any of the data stores.
- TLS / auth between any of the components. This is a sandbox.
- Production-grade Kafka or HBase tuning. This lab is about *seeing* the
  system, not running it well.

---

## Production Track — Kubernetes + Cilium

This track is a parallel branch, not a linear continuation of Stages A–E. It
replaces the Docker Compose runtime with a real Kubernetes cluster and adds
Cilium as the CNI + service-mesh layer. The observability backend (Tempo,
Prometheus, Loki, Grafana) stays the same.

**Why a separate track:** Stages A–E instrument the application layer. This
track adds the *network* layer — Cilium sees what the JVM agents can't, and
vice versa. Together they give you the full picture you'd expect in production.

See `docs/K8S_PROJECTION.md` for the per-protocol coverage table and the
architecture diagram. Implementation lives in `cilium/`.

### K-1 — kind cluster + Cilium CNI

Bootstrap a single-node (or 3-node) kind cluster with Cilium as the CNI and
Hubble UI enabled.

- `cilium/kind-cluster.yaml`: disables kind's default CNI so Cilium can own it.
- Install Cilium via Helm (`cilium/cilium-values.yaml`) with `hubble.relay`
  and `hubble.ui` enabled.
- Verify: `cilium status --wait`, `hubble observe` shows pod-to-pod flows.

**What this buys you:** a real CNI environment that matches managed k8s
(EKS, GKE, AKS all support Cilium). Hubble is the always-on network observer.

### K-2 — Kafka L7 visibility

Enable Cilium's Kafka L7 policy on the `kafka` pod. This uses an Envoy Kafka
filter — no changes to the broker or the Java apps required.

- Add a `CiliumNetworkPolicy` with `rules.kafka` allow-list (topic name, role:
  produce / consume) targeting the kafka pod.
- Verify: `hubble observe --protocol kafka` shows produce/consume events with
  topic names. The Hubble service map shows `producer → kafka → consumer` with
  per-topic labels.

**What this buys you:** broker-side Kafka visibility. The OTel Java agent sees
the *client* side (KafkaProducer.send span in producer, poll span in consumer).
Cilium sees the *broker* side — topic-level throughput, latency, and error rate
without touching the application. These two views are complementary, not
redundant.

**Note:** requires PLAINTEXT Kafka (no broker-level TLS). Our current setup
already uses `PLAINTEXT` — no change needed.

### K-3 — gRPC + HTTP L7 visibility

Enable Cilium L7 visibility on the OTLP gRPC port (4317) and on the Jetty HTTP
ports (HBase 16010/16030, Hadoop 9870).

- Add `CiliumNetworkPolicy` with `rules.http` and `rules.grpc` for those ports.
- Verify: `hubble observe --protocol grpc` shows method names like
  `opentelemetry.proto.collector.trace.v1.TraceService/Export`. HTTP panel
  shows Jetty health-check paths.

**What this buys you:** confirms OTLP telemetry is flowing at the network layer
(useful for debugging "why aren't my spans arriving?") and shows the same
Jetty-UI edges the OTel agent surfaces, from the network perspective.

### K-4 — hubble-otel bridge

Deploy `github.com/cilium/hubble-otel` as a Deployment in the cluster. It
reads the Hubble gRPC stream and forwards Hubble flow events to the OTel
Collector as OTLP logs (or spans).

- Add `cilium/manifests/hubble-otel.yaml`: Deployment + Service pointing at the
  existing OTel Collector.
- Configure the OTel Collector's logs pipeline to accept Hubble events and ship
  them to Loki (with a `service=hubble` label).
- Verify: Grafana Loki Explore, `{service="hubble"}` shows Kafka flow events.
  A Kafka produce trace in Tempo and the corresponding Hubble network event in
  Loki are visible side-by-side.

**What this buys you:** network events (DNS failures, TCP resets, Kafka topic
errors) appear in the same Grafana stack as OTel traces. You can correlate "the
HBase Put span took 800ms" with "there were 3 TCP retransmits on that connection
in the same window."

### K-5 — OTel Operator (agent injection)

Replace baked-in `JAVA_TOOL_OPTIONS=-javaagent:...` in the app Dockerfiles with
OTel Operator init-container injection. This is the production pattern — the
agent version is managed by the platform, not the app image.

- Install `opentelemetry-operator` via Helm.
- Create an `Instrumentation` CRD in `cilium/otel-operator/instrumentation.yaml`
  with Java agent config (exporter endpoint, resource attributes).
- Annotate the producer / consumer / query-client `Deployment` manifests with
  `instrumentation.opentelemetry.io/inject-java: "true"`.
- Verify: `kubectl describe pod producer-xxx` shows the init container that
  copies the agent JAR; spans still arrive in Tempo.

**What this buys you:** decouples the agent upgrade cycle from the app build.
Mirrors how platform teams manage OTel in production.

### K-6 — Persistent gaps and the path forward

After K-1 through K-5, what remains opaque in the network graph:

| Path | Protocol | Why | Option to fill it |
|---|---|---|---|
| HBase client → RegionServer | HBase RPC (TCP:16000/16030) | No Cilium L7 parser | ROADMAP2.md §2 option A (custom OTel agent extension) |
| RegionServer → NameNode | Hadoop IPC (TCP:8020) | No Cilium L7 parser | Same custom extension |
| DataNode block transfer | DataTransferProtocol (TCP:9866) | No Cilium L7 parser | eBPF custom dissector (high effort) |
| All → ZooKeeper | ZK wire (TCP:2181) | No Cilium L7 parser | Not worth the effort for this lab |

These gaps are the same in production Kubernetes. Cilium can tell you *that*
traffic flowed on those ports and *how many bytes*, but not *which table* or
*which region*. OTel's HBase client instrumentation (already present via the
Java agent) fills in the client side; the server side requires the custom
extension from ROADMAP2.md.

**Stage D equivalence in k8s:** swap `dockerstatsreceiver` for cAdvisor +
`kube-state-metrics` scraped by Prometheus; alerting rules stay the same.
The OTel Collector's `k8sattributesprocessor` enriches every span/metric with
the pod name, namespace, and node, giving you the same "container restart count"
signal that Stage D targets on Compose.
