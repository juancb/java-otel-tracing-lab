Plan for the response. I'll lay out three distinct deliverables and let you pick which to proceed on.

## 1. Verify the service graph makes sense

I'll write down what *should* be there and you can compare against Tempo's service map. Then I'll explain anything that's there but unexpected, and anything that's missing but expected.

**Expected nodes** (anything emitting a trace counts):
- `producer`, `consumer`, `query-client` — the three Java apps with the OTel agent
- `kafka` — broker JVM has the agent attached
- `hbase-master`, `hbase-regionserver` — HBase 2.5 ships with built-in client-side OTel
- `hadoop-namenode`, `hadoop-datanode` — agent attached, but mostly silent at the protocol level
- `zookeeper` — agent attached, even quieter
- `user` — phantom node for the Docker healthcheck `curl` traffic hitting Jetty UIs (already documented in `SERVICE_GRAPH.md`)

**Expected edges** (one direction means the OTel agent saw a client span on that side):

| From → To | Why | Should be visible |
|---|---|---|
| `producer` → `kafka` | KafkaProducer.send | ✓ |
| `kafka` → `consumer` | poll → process record (header propagation) | ✓ |
| `consumer` → `hbase-regionserver` | HBase Put RPC | ✓ (after Stage B's OTTL `peer.service` rewrite) |
| `query-client` → `hbase-regionserver` | Scan / Get / Increment | ✓ (new, post-78fb303) |
| `hbase-master` → `hbase-regionserver` | region assignment | ✓ |
| `hbase-regionserver` → `hbase-master` | heartbeats | ✓ |
| `user` → various Jetty UIs | curl healthchecks | ✓ |

**Expected absences** (so you don't waste time looking):
- `hbase-regionserver` → `hadoop-datanode` (block writes via DataTransferProtocol — not auto-instrumented)
- `hadoop-namenode` ↔ `hadoop-datanode` (block reports, heartbeats — Hadoop RPC, not auto-instrumented)
- `consumer` ↔ `zookeeper` / `hbase-master` ↔ `zookeeper` (ZK protocol, not instrumented)
- `kafka` internal controller↔broker (single-node KRaft — there's no peer)

**Verification plan**: Open `http://localhost:3000/d/otel-lab-service-map/` and the **Tempo Service Graph view** in Explore. Cross-check against the table. I'll also write a small script that pulls `traces_service_graph_request_total` from Prometheus and prints the actual edges as a table so you don't have to eyeball it.

## 2. Extending traces inside HDFS / Hadoop

Quick correction first: **HDFS doesn't actually use gRPC**. It uses Hadoop's own RPC (protobuf-over-TCP on `:8020`) for metadata and a separate `DataTransferProtocol` (custom binary on `:9866`) for block transfers. So "gRPC tracing" doesn't apply directly. Newer Hadoop subprojects (Ozone, Submarine) do use gRPC, but core HDFS doesn't.

Three real options to get trace continuity into HDFS, ranked by effort:

| Option | Effort | Value | Trace context aligned to client? |
|---|---|---|---|
| **A. Custom OTel Java agent extension** that hooks Hadoop's `Server.Connection` / `RpcEngine` classes to extract the trace context from a custom call header and create child spans | High (real instrumentation work) | Full in-band tracing | Yes — same trace tree as the client |
| **B. Apache Hadoop's OTel branch** — there's a long-running JIRA series (HADOOP-17560 lineage) for native OTel support. Currently incomplete in 3.3.x. We could test the WIP patches | Medium | Full when stable | Yes |
| **C. eBPF-based observation** (Pixie, Tetragon, custom) — observes Hadoop RPC at the kernel layer and emits spans | Medium | Topology + per-call latency, **no** parent trace ID linkage | No — synthetic spans, not children of the client |

Recommendation if you want it now: **A**, and the right shape for a lab is to write the agent extension as a Maven module under `apps/otel-extensions/` and load it via `-Dotel.javaagent.extensions=/opt/otel/extensions/hadoop-rpc.jar`. I'd budget a focused half-day to get NameNode↔DataNode heartbeats traced, then it generalizes.

## 3. Cilium / Kubernetes-future question

This is a layered answer because Cilium does some of what you want and can't do other parts.

**What Cilium gives you that's genuinely valuable:**
- **L7 visibility for Kafka** (built-in since Cilium 1.x): per-topic produce/fetch metrics, request rate, error rate, topic-level latency histograms via Hubble. So "topic latency" is a yes — Cilium can do that without OTel.
- **Service-mesh-style L4 telemetry**: pod-to-pod flow rates, connection latency, TLS errors. Service-graph-equivalent at the network layer.
- **mTLS / identity-aware policy**: not observability, but useful in production.
- **gRPC-aware telemetry** for things that *do* use gRPC.

**What Cilium can't give you:**
- **Trace IDs aligned with the client** for arbitrary protocols. Cilium observes packets; it doesn't synthesize OTel spans linked to upstream context. To do that, the trace context has to live *in* the protocol payload, and someone has to put it there at the application layer (the OTel agent's job).
- **Decoding Hadoop RPC payloads**. Cilium's L7 parsers don't include Hadoop's protocol. You get TCP-level flow data only.

**The practical k8s deployment recipe** I'd recommend:
1. **OTel Operator** to inject the Java agent into JVM pods via init containers (same agent we use today, just packaged differently).
2. **Cilium with Kafka L7 visibility enabled** for topic-level latency dashboards. Combined with OTel's Kafka instrumentation, you get both views — application-level trace propagation *and* network-level topic latency.
3. **For HDFS**: option A from §2 above. Cilium gives you "is the network slow" but won't give you a trace-id-linked HDFS span.
4. **Hubble → OTLP**: there's a Hubble exporter that can ship Hubble flows to OTel as logs/metrics. That gets the network telemetry into the same Grafana stack you already have.

**What I'd actually build to demo this:**
- A `cilium/` directory with a `kind-cluster.yaml` + Cilium install manifest that boots the same lab in kind/k3d. Probably a 2-3 hour exercise.
- A short `docs/K8S_PROJECTION.md` that explains the equivalence: which services use OTel agent injection, which use Cilium L7 visibility, where the seams are.

---

**Concrete deliverables I can produce, ordered shortest-to-longest:**

1. (~10 min) Verification table comparing expected edges to actual ones from your running stack — using a `prom_query.sh` against `traces_service_graph_request_total`.
2. (~30 min) `docs/SERVICE_GRAPH.md` rewrite with the table above, plus the explicit "expected absences" list, plus how to extend it with custom instrumentation.
3. (~half-day) The Hadoop RPC OTel agent extension (option A). This is real code with a real maintenance cost.
4. (~2-3 hr) `docs/K8S_PROJECTION.md` + a kind/k3d Cilium-enabled variant of the lab — sketch level, no traffic running on it yet.

Which of those do you want me to do, and in what order? I'd suggest 1 + 2 first (cheap, immediately useful) and then deciding between 3 and 4 based on whether Hadoop-internal tracing or the k8s projection is closer to your real goal.