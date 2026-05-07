# Kubernetes + Cilium projection

This document maps the Docker Compose lab onto a production-aligned Kubernetes
deployment. The application code and observability backend (Tempo, Prometheus,
Loki, Grafana) are unchanged. What changes is:

1. **Runtime** — kind/k3d instead of Docker Compose
2. **CNI** — Cilium instead of the Docker bridge network
3. **Network observability** — Hubble (bundled with Cilium) adds HTTP L7 and
   general flow visibility at the network layer. **Note:** Cilium Kafka L7
   enforcement (`role: produce/consume`) was removed post-Cilium 1.19 via
   proxylib removal — see the deprecation note below.
4. **Agent delivery** — OTel Operator init-container injection instead of
   baked-in `JAVA_TOOL_OPTIONS` in the Dockerfiles

See `docs/ROADMAP.md` §"Production Track" for the staged implementation plan
(K-1 through K-6). The `cilium/` directory holds the manifests.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Kubernetes cluster (kind)                                  │
│                                                            │
│  ┌──────────┐   Kafka wire   ┌───────┐   Kafka wire       │
│  │ producer │ ─────────────► │ kafka │ ◄─────────────────  │
│  └──────────┘                └───────┘         │           │
│       │ OTel agent (init)        │ Cilium L7   │           │
│       │ OTLP/gRPC                │ (Envoy      │           │
│       ▼                          │  Kafka       │           │
│  ┌──────────────────┐            │  filter)     │           │
│  │  OTel Collector  │ ◄──────────┘              │           │
│  └──────────────────┘                    ┌──────────┐      │
│       │                                  │ consumer │      │
│       ├── traces ──► Tempo               └──────────┘      │
│       ├── metrics ─► Prometheus              │ OTel agent   │
│       └── logs ───► Loki                     │ OTLP/gRPC    │
│                        ▲                     ▼             │
│                        │              ┌──────────────────┐  │
│  ┌────────────────┐    │              │ hbase-regionserver│  │
│  │  hubble-otel   │────┘              └──────────────────┘  │
│  │  (Deployment)  │                          │ HBase RPC     │
│  └────────────────┘                          │ (opaque)      │
│          ▲                                   ▼             │
│          │ Hubble gRPC stream         ┌──────────────┐     │
│  ┌───────────────┐                   │ hadoop-*     │     │
│  │  Cilium/Hubble│                   └──────────────┘     │
│  │  (per-node    │                                        │
│  │   DaemonSet)  │                                        │
│  └───────────────┘                                        │
│                                                            │
└────────────────────────────────────────────────────────────┘

           Grafana (Tempo + Prometheus + Loki datasources)
           reads traces, metrics, and logs from all three
           backends — OTel agent spans and Hubble flow events
           appear in the same dashboards.
```

---

## Protocol coverage table

### What Cilium sees at L7

| Traffic path | Protocol | Cilium L7 | What Hubble shows |
|---|---|---|---|
| `producer → kafka` | Kafka binary (TCP:9092) | **REMOVED** ⚠ | Was: topic name, operation. Removed in Cilium 1.20 — see deprecation note |
| `consumer → kafka` | Kafka binary (TCP:9092) | **REMOVED** ⚠ | Same — removed |
| `apps → otel-collector` | gRPC / OTLP (TCP:4317) | YES (policy valid, events at L4) | gRPC service/method visible in Envoy; per-RPC L7 events not surfaced in Hubble for persistent H2 connections |
| `apps → otel-collector` | HTTP / OTLP (TCP:4318) | YES | URL path, method, status code |
| Healthchecks → Jetty UIs | HTTP (TCP:9870/16010/16030) | YES | URL path, status code, latency — confirmed working in K-3 |
| Service discovery | DNS (UDP:53) | YES | Query name, response, TTL |

### Cilium Kafka L7 enforcement: removed in Cilium 1.20

`role: produce` / `role: consume` in `CiliumNetworkPolicy` relied on **proxylib**
— Cilium's Go extension framework for custom L7 protocol parsers. Proxylib was
deprecated in Cilium v1.16 and removed post-1.19:

- [PR #43557](https://github.com/cilium/cilium/pull/43557) — removes proxylib
  and all Kafka-aware `CiliumNetworkPolicy` rules
- [PR #45644](https://github.com/cilium/cilium/pull/45644) — removes leftover
  Kafka case branches from Hubble's flow classifier (dead code cleanup)
- [Issue #44551](https://github.com/cilium/cilium/issues/44551) — removes Kafka
  as a Hubble CLI export format in v1.20

**Impact on this lab:** We observed the breakage in K-2 — the `kafka-l7` policy
showed `VALID: True` (API schema still accepts it) but was running on deprecated
proxylib code, causing DROPS on Kafka 3.8 protocol v9+ Produce requests and
showing all topics as `''`. The policy has been removed from `cilium/manifests/policies/`.

**Correct approach for Kafka topic observability:**
- The **OTel Java agent** records the topic name in span attributes for every
  `KafkaProducer.send()` call. This flows into Tempo → span-metrics → Prometheus
  → the "OTel Lab — Hubble L7" Grafana dashboard, which shows `sensor.readings`
  topic rate and latency.
- For broker-side **enforcement** (allow/deny by topic), the migration path is
  `CiliumEnvoyConfig` using Envoy's native Kafka filter. This is not implemented
  in this lab but is the upstream-supported replacement.

**HTTP and gRPC L7 policies (K-3) are unaffected** — they use Envoy natively
without proxylib and remain the recommended pattern.

### What Cilium CANNOT see at L7 (permanent gaps)

| Traffic path | Protocol | Why | How to fill the gap |
|---|---|---|---|
| `consumer/query-client → hbase-regionserver` | HBase RPC (TCP:16000/16030) | Custom binary; no Cilium parser | OTel Java agent (already in place) provides client-side spans; server-side needs custom extension (ROADMAP2.md §2) |
| `hbase-regionserver → hadoop-namenode` | Hadoop IPC (TCP:8020) | Custom binary; no Cilium parser | Custom OTel agent extension (ROADMAP2.md §2, option A) |
| `hbase-regionserver → hadoop-datanode` | DataTransferProtocol (TCP:9866) | Custom binary; no Cilium parser | No practical option short of an eBPF custom dissector |
| All → ZooKeeper | ZK wire (TCP:2181) | Custom binary; no Cilium parser | Not worth the effort; ZK is coordination infra, not on the hot path |

At L4 (TCP), Cilium sees *all* of these: connection count, bytes transferred,
retransmits, connection latency. It just can't decode the payload.

---

## Cilium vs OTel: what each adds

### What Cilium/Hubble adds over OTel alone

| Capability | Notes |
|---|---|
| **Kafka broker-side visibility** | OTel sees the client (KafkaProducer.send span); Cilium sees the broker — per-topic throughput, latency, error rate without any code change |
| **Network-layer failures** | TCP retransmits, connection resets, DNS failures, and packet drops are invisible to application code; Hubble surfaces them as flow events |
| **Zero-instrumentation baseline** | Before OTel agent is injected or if it crashes, Cilium still shows the L3/L4 topology |
| **Policy enforcement** | `CiliumNetworkPolicy` can allow-list specific Kafka topics, gRPC methods, or HTTP paths — the network is the policy enforcement point |
| **Pod identity** | Hubble labels flows with the Kubernetes pod, namespace, and label — no need for `resource.service.name` configuration |

### What OTel adds over Cilium alone

| Capability | Notes |
|---|---|
| **W3C trace propagation** | Trace IDs cross service boundaries; Cilium observes flows but does not inject or propagate trace context |
| **HBase / Hadoop client spans** | The OTel Java agent's HBase instrumentation creates client-side spans Cilium can never see |
| **Business-logic spans** | Custom spans in application code, exception recording, custom attributes |
| **Metrics from inside the JVM** | Heap usage, GC pause, thread pool depth — JVM internals invisible at the network layer |
| **Cross-protocol trace linking** | A single trace ID connects the Kafka consumer poll, the HBase Put, and the WAL sync into one waterfall |

---

## Implementation recipe (abbreviated)

### K-1: kind cluster + Cilium

```bash
# Requires: kind, kubectl, helm, cilium CLI

# 1. Create cluster without default CNI
kind create cluster --config cilium/kind-cluster.yaml

# 2. Install Cilium via Helm
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values cilium/cilium-values.yaml

# 3. Wait and verify
cilium status --wait
hubble observe   # should show DNS + pod-to-pod flows
```

`cilium/kind-cluster.yaml` must set `networking.disableDefaultCNI: true` and
allocate enough `kubeadmConfigPatches` for Cilium's requirements.

### K-2: Kafka L7 policy

```yaml
# cilium/manifests/kafka-l7-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: kafka-l7
spec:
  endpointSelector:
    matchLabels:
      app: kafka
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: producer
      toPorts:
        - ports:
            - port: "9092"
          rules:
            kafka:
              - topic: sensor-readings
                role: produce
    - fromEndpoints:
        - matchLabels:
            app: consumer
      toPorts:
        - ports:
            - port: "9092"
          rules:
            kafka:
              - topic: sensor-readings
                role: consume
```

After applying: `hubble observe --protocol kafka --follow` shows produce/fetch
events with the topic name. The Hubble UI service map shows the edge
`producer → kafka` labelled with the topic.

### K-4: hubble-otel bridge (sketch)

```yaml
# cilium/manifests/hubble-otel.yaml  (abbreviated)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hubble-otel
spec:
  template:
    spec:
      containers:
        - name: hubble-otel
          image: ghcr.io/cilium/hubble-otel:v0.1.8
          args:
            - --hubble-address=hubble-relay.kube-system.svc:80
            - --otlp-address=otel-collector.observability.svc:4317
            - --log-format=json
```

This ships Hubble L7 flow events as OTLP logs to the existing Collector. Add
a `logs` pipeline in the Collector config that routes them to Loki with
`service=hubble`. In Grafana Loki Explore, `{service="hubble"}` then shows
network-level events alongside `{service="consumer"}` application logs.

### K-5: OTel Operator injection (sketch)

```yaml
# cilium/otel-operator/instrumentation.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: java-instrumentation
spec:
  exporter:
    endpoint: http://otel-collector.observability.svc:4317
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.10.0
  env:
    - name: OTEL_SERVICE_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['app']
```

Add `instrumentation.opentelemetry.io/inject-java: "true"` to producer,
consumer, and query-client Deployments. The Operator handles the init container;
remove `JAVA_TOOL_OPTIONS` from the app Dockerfiles.

---

## Mapping from Docker Compose services to k8s manifests

| Compose service | k8s resource | Notes |
|---|---|---|
| `producer` | Deployment (1 replica) | Annotation for OTel Operator injection |
| `consumer` | Deployment (1 replica) | Same |
| `query-client` | Deployment (1 replica) | Same |
| `kafka` | StatefulSet (1 pod) + Service | Port 9092 ClusterIP + 29092 NodePort for external access |
| `zookeeper` | StatefulSet (1 pod) + Service | Port 2181 ClusterIP |
| `namenode` | StatefulSet + Service | Ports 9870, 8020 |
| `datanode` | StatefulSet + Service | Shares PVC with namenode for HDFS |
| `hbase-master` | StatefulSet + Service | Ports 16000, 16010 |
| `hbase-regionserver` | StatefulSet + Service | Ports 16030 |
| `otel-collector` | Deployment + Service | Ports 4317, 4318 |
| `tempo` | StatefulSet + Service | Port 3200 |
| `prometheus` | StatefulSet + Service | Port 9090 |
| `loki` | StatefulSet + Service | Port 3100 |
| `alloy` | DaemonSet + Service | Docker log scraping → Loki |
| `grafana` | Deployment + Service + Ingress | Port 3000 |
| `hubble-otel` | Deployment | New in k8s track |

StatefulSets for the data services (Kafka, ZK, HBase, Hadoop, Tempo,
Prometheus, Loki) ensure stable pod names and PVC binding across restarts.

---

## Stage D equivalence in Kubernetes

The Compose Stage D uses `dockerstatsreceiver` for container CPU/memory. In
Kubernetes:

- **cAdvisor** (built into kubelet) exposes per-container CPU/memory/IO at
  `/metrics/cadvisor`. Prometheus scrapes it automatically via the `kubernetes_sd`
  job.
- **kube-state-metrics** exposes pod restart counts, resource requests/limits,
  and HPA state.
- **OTel Collector `k8sattributesprocessor`** enriches every span and metric
  with `k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name` so Grafana
  dashboards can join trace data to container metrics.

The alerting rules from Stage D translate 1-to-1: `container_restarts` →
`kube_pod_container_status_restarts_total`, container CPU throttle →
`container_cpu_cfs_throttled_seconds_total`.
