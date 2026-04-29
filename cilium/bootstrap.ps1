# Bootstrap the Cilium k8s lab end-to-end.
# Idempotent: safe to re-run; will skip steps that are already in place.
#
# Usage from the repo root:
#   pwsh cilium/bootstrap.ps1
#
# To start fresh:
#   kind delete cluster --name otel-lab
#   pwsh cilium/bootstrap.ps1

$ErrorActionPreference = "Stop"

$Repo = Split-Path -Parent $PSScriptRoot
$Cilium = $PSScriptRoot
$ClusterName = "otel-lab"
$Ctx = "kind-$ClusterName"

function Step($msg) { Write-Host ">>> $msg" -ForegroundColor Cyan }

# ---------- 1. Build images if any are missing ----------
Step "Checking otel-lab/* images exist locally"
$needed = @(
    "otel-lab/zookeeper:local",
    "otel-lab/kafka:local",
    "otel-lab/hadoop-hbase:local",
    "otel-lab/producer:local",
    "otel-lab/consumer:local",
    "otel-lab/query-client:local"
)
$missing = $needed | Where-Object { -not (docker image inspect $_ 2>$null) }
if ($missing) {
    Write-Host "Missing images: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "Run 'docker compose build' from the repo root first." -ForegroundColor Yellow
    exit 1
}

# ---------- 2. Create the kind cluster ----------
$existing = kind get clusters 2>$null
if ($existing -contains $ClusterName) {
    Step "Cluster '$ClusterName' already exists"
} else {
    Step "Creating kind cluster '$ClusterName'"
    kind create cluster --config "$Cilium/kind-cluster.yaml"
    if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed" }
}

# ---------- 3. Load the local images into kind ----------
Step "Loading otel-lab/* images into the kind cluster (one-time per image)"
foreach ($img in $needed) {
    Write-Host "  loading $img"
    kind load docker-image $img --name $ClusterName | Out-Null
}

# ---------- 4. Install Cilium ----------
$installed = kubectl --context=$Ctx get ds -n kube-system cilium -o name 2>$null
if ($installed) {
    Step "Cilium already installed — upgrading to apply current values"
    # Get the control-plane container IP (needed by Cilium's init phase before DNS is up)
    $cpIp = docker inspect "${ClusterName}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
    if (-not $cpIp) { throw "Could not determine control-plane IP" }
    Write-Host "  Control-plane IP: $cpIp"
    cilium upgrade --version=v1.19.1 --values="$Cilium/cilium-values.yaml" `
        --helm-set "k8sServiceHost=$cpIp" --helm-set "k8sServicePort=6443" `
        --context=$Ctx
} else {
    Step "Installing Cilium v1.19.1 with Hubble + Envoy"
    # Use the container IP directly to avoid the DNS-before-CNI bootstrapping deadlock:
    # with kube-proxy disabled, the `kubernetes` ClusterIP VIP isn't set up by the time
    # Cilium's init container runs, and CoreDNS isn't up either.
    $cpIp = docker inspect "${ClusterName}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
    if (-not $cpIp) { throw "Could not determine control-plane IP" }
    Write-Host "  Control-plane IP: $cpIp"
    cilium install --version=v1.19.1 --values="$Cilium/cilium-values.yaml" `
        --helm-set "k8sServiceHost=$cpIp" --helm-set "k8sServicePort=6443" `
        --context=$Ctx
    if ($LASTEXITCODE -ne 0) { throw "cilium install failed" }
}

Step "Waiting for Cilium to be ready (this can take 60-90s)"
cilium status --wait --context=$Ctx --wait-duration=3m

# ---------- 5. Apply namespaces ----------
Step "Applying namespaces"
kubectl --context=$Ctx apply -f "$Cilium/manifests/00-namespaces.yaml"

# ---------- 6. Build ConfigMaps from existing config files ----------
Step "Creating ConfigMaps from $Repo configs"

function ApplyCM($name, $ns, $files) {
    $cmArgs = @("--context=$Ctx", "create", "configmap", $name, "-n", $ns, "--dry-run=client", "-o", "yaml")
    foreach ($f in $files) { $cmArgs += "--from-file=$f" }
    $yaml = & kubectl @cmArgs
    $yaml | & kubectl --context=$Ctx apply -f -
}

# Tempo: use the existing tempo.yaml as-is (references prometheus:9090, same ns)
ApplyCM "tempo-config" "observability" @("$Repo/tempo/tempo.yaml")

# Prometheus: use the k8s-adapted version with FQDN targets
ApplyCM "prometheus-config" "observability" @("$Cilium/configs/prometheus.yml")

# Loki: existing config is k8s-portable
ApplyCM "loki-config" "observability" @("$Repo/loki/config.yaml")

# OTel Collector: existing config (refs tempo:4317, prometheus:9090 in same ns)
ApplyCM "otel-collector-config" "observability" @("$Repo/otel-collector/config.yaml")

# Alloy: k8s-adapted config. Pass explicit key=path so the ConfigMap key is
# `config.alloy` (what Alloy's args reference) not `alloy.alloy` (the filename).
$alloyArgs = @("--context=$Ctx", "create", "configmap", "alloy-config", "-n", "observability", "--dry-run=client", "-o", "yaml", "--from-file=config.alloy=$Cilium/configs/alloy.alloy")
(& kubectl @alloyArgs) | & kubectl --context=$Ctx apply -f -

# Grafana datasources + dashboards
$dsFiles = Get-ChildItem "$Repo/grafana/provisioning/datasources/*.yaml"
ApplyCM "grafana-datasources" "observability" $dsFiles.FullName
ApplyCM "grafana-dashboards-cfg" "observability" @("$Repo/grafana/provisioning/dashboards/dashboards.yaml")
$dashFiles = Get-ChildItem "$Repo/grafana/provisioning/dashboards/*.json"
ApplyCM "grafana-dashboards" "observability" $dashFiles.FullName

# JMX exporter rule files (consumed by all hadoop/hbase/kafka pods)
$jmxFiles = Get-ChildItem "$Repo/jmx-exporter/*.yaml"
ApplyCM "jmx-exporter-config" "data" $jmxFiles.FullName

# k8s-specific hdfs-site.xml — adds ip-hostname-check=false so the DataNode
# can register by pod IP without a resolvable reverse-DNS PTR record.
ApplyCM "hadoop-hdfs-site" "data" @("$Cilium/configs/hdfs-site.xml")

# ---------- 7. Apply observability stack ----------
Step "Applying observability stack (tempo, prom, loki, alloy, otel-collector, grafana)"
kubectl --context=$Ctx apply -f "$Cilium/manifests/observability/"

Step "Waiting for observability StatefulSets/Deployments to be ready (3m timeout)"
kubectl --context=$Ctx -n observability rollout status statefulset/tempo --timeout=3m
kubectl --context=$Ctx -n observability rollout status statefulset/prometheus --timeout=3m
kubectl --context=$Ctx -n observability rollout status statefulset/loki --timeout=3m
kubectl --context=$Ctx -n observability rollout status deployment/otel-collector --timeout=3m
kubectl --context=$Ctx -n observability rollout status deployment/grafana --timeout=3m

# ---------- 8. Apply data plane ----------
Step "Applying data plane (zookeeper, hadoop, hbase, kafka, apps)"
kubectl --context=$Ctx apply -f "$Cilium/manifests/data/"

Step "Waiting for data plane (10m timeout — HBase + HDFS take a while)"
kubectl --context=$Ctx -n data rollout status statefulset/zookeeper          --timeout=3m
kubectl --context=$Ctx -n data rollout status statefulset/namenode           --timeout=5m
kubectl --context=$Ctx -n data rollout status statefulset/datanode           --timeout=5m
kubectl --context=$Ctx -n data rollout status statefulset/hbase-master       --timeout=5m
kubectl --context=$Ctx -n data rollout status statefulset/hbase-regionserver --timeout=5m
kubectl --context=$Ctx -n data rollout status statefulset/kafka              --timeout=3m
kubectl --context=$Ctx -n data rollout status deployment/producer            --timeout=2m
kubectl --context=$Ctx -n data rollout status deployment/consumer            --timeout=2m
kubectl --context=$Ctx -n data rollout status deployment/query-client        --timeout=2m

# ---------- 9. Apply K-2 + K-3 L7 policies ----------
Step "Applying K-2 Kafka L7 CiliumNetworkPolicy"
kubectl --context=$Ctx apply -f "$Cilium/manifests/policies/kafka-l7.yaml"

Step "Applying K-3 gRPC + HTTP L7 visibility policies"
kubectl --context=$Ctx apply -f "$Cilium/manifests/policies/grpc-visibility.yaml"
kubectl --context=$Ctx apply -f "$Cilium/manifests/policies/http-visibility.yaml"

# ---------- 10. Summary ----------
Step "Bootstrap complete"
Write-Host ""
Write-Host "Grafana:    http://localhost:13000  (Compose: 3000)"  -ForegroundColor Green
Write-Host "Prometheus: http://localhost:19090  (Compose: 9090)"  -ForegroundColor Green
Write-Host "Tempo:      http://localhost:13200  (Compose: 3200)"  -ForegroundColor Green
Write-Host "Loki:       http://localhost:13100  (Compose: 3100)"  -ForegroundColor Green
Write-Host ""
Write-Host "Verify Kafka L7 visibility (give it 30s for traffic to flow):" -ForegroundColor Yellow
Write-Host "  cilium hubble port-forward&" -ForegroundColor Yellow
Write-Host "  hubble observe --protocol kafka --follow" -ForegroundColor Yellow
Write-Host ""
Write-Host "Or open Hubble UI:" -ForegroundColor Yellow
Write-Host "  cilium hubble ui" -ForegroundColor Yellow
