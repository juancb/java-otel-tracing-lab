# cilium/

Kubernetes + Cilium implementation of the lab. Mirrors the Docker Compose setup
in `docker-compose.yml` but replaces the Docker bridge network with Cilium as
the CNI, adds Hubble for network-layer observability, and uses the OTel Operator
for Java agent injection instead of baked-in Dockerfiles.

See `docs/K8S_PROJECTION.md` for the full protocol coverage table, architecture
diagram, and explanation of what Cilium adds over the OTel Java agent alone.
See `docs/ROADMAP.md` §"Production Track — Kubernetes + Cilium" for the staged
implementation plan (K-1 through K-6).

---

## Directory layout (to be populated)

```
cilium/
├── kind-cluster.yaml          # kind cluster config — disables default CNI
├── cilium-values.yaml         # Helm values: Kafka L7, Hubble relay + UI, hubble-otel
├── manifests/
│   ├── namespace.yaml         # observability namespace
│   ├── zookeeper.yaml         # StatefulSet + Service
│   ├── kafka.yaml             # StatefulSet + Service (ports 9092, 29092)
│   ├── hadoop.yaml            # namenode + datanode StatefulSets + Services
│   ├── hbase.yaml             # hbase-master + hbase-regionserver StatefulSets
│   ├── producer.yaml          # Deployment + OTel injection annotation
│   ├── consumer.yaml          # Deployment + OTel injection annotation
│   ├── query-client.yaml      # Deployment + OTel injection annotation
│   ├── otel-collector.yaml    # Deployment + Service (4317, 4318)
│   ├── tempo.yaml             # StatefulSet + Service + PVC
│   ├── prometheus.yaml        # StatefulSet + Service + PVC
│   ├── loki.yaml              # StatefulSet + Service + PVC
│   ├── alloy.yaml             # DaemonSet (Docker log scraping → Loki)
│   ├── grafana.yaml           # Deployment + Service + Ingress
│   ├── hubble-otel.yaml       # Deployment: Hubble flow → OTel Collector bridge
│   ├── kafka-l7-policy.yaml   # CiliumNetworkPolicy: Kafka topic-level allow rules
│   └── http-visibility.yaml   # CiliumClusterwideNetworkPolicy: HTTP + gRPC L7
└── otel-operator/
    ├── install.yaml           # OTel Operator Helm install (or kustomize)
    └── instrumentation.yaml   # Instrumentation CRD: Java agent config + endpoint
```

---

## Bootstrap order (K-1 → K-6)

```bash
# K-1: cluster + Cilium
kind create cluster --config cilium/kind-cluster.yaml
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --namespace kube-system \
  --values cilium/cilium-values.yaml
cilium status --wait

# K-2: Kafka L7 policy
kubectl apply -f cilium/manifests/kafka-l7-policy.yaml
# then deploy kafka + producer + consumer:
kubectl apply -f cilium/manifests/kafka.yaml
kubectl apply -f cilium/manifests/producer.yaml
kubectl apply -f cilium/manifests/consumer.yaml
# verify:
hubble observe --protocol kafka --follow

# K-3: gRPC + HTTP visibility
kubectl apply -f cilium/manifests/http-visibility.yaml
hubble observe --protocol grpc --follow

# K-4: hubble-otel bridge
kubectl apply -f cilium/manifests/otel-collector.yaml
kubectl apply -f cilium/manifests/hubble-otel.yaml
# Hubble flows now appear in Loki under {service="hubble"}

# K-5: OTel Operator
kubectl apply -f cilium/otel-operator/install.yaml
kubectl apply -f cilium/otel-operator/instrumentation.yaml
# Existing producer/consumer/query-client Deployments need the annotation:
#   instrumentation.opentelemetry.io/inject-java: "true"
# Remove JAVA_TOOL_OPTIONS from the app Dockerfiles after this.

# K-6: Full stack
kubectl apply -f cilium/manifests/
# Verify all pods Running, then open Grafana at the NodePort / Ingress URL
```

---

## Key design decisions captured in docs/K8S_PROJECTION.md

- Kafka L7 uses Cilium's Envoy Kafka filter — requires PLAINTEXT broker (no
  TLS). Current lab uses `PLAINTEXT`; no broker change needed.
- HBase RPC, Hadoop IPC, and ZooKeeper protocol remain opaque to Cilium. OTel
  Java agent fills the client side; server side needs the custom agent extension
  from `docs/ROADMAP2.md` §2.
- `hubble-otel` is a separate project (`github.com/cilium/hubble-otel`), not
  bundled with Cilium. Pin the version in `manifests/hubble-otel.yaml`.
- Stage D (alerts) maps to cAdvisor + kube-state-metrics + Prometheus scrape
  jobs, not `dockerstatsreceiver`. Alert rules are identical.
