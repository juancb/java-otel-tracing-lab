# Service Graph

Tempo's `metrics_generator` watches every span and emits
`traces_service_graph_request_total` (and `_failed_total`, `_duration_*`) per
`(client, server)` pair. These land in Prometheus via remote-write; Grafana's
Node Graph panel reads them and draws the dependency graph.

Open it: **Grafana → Explore → Tempo → Service Graph → Run query**, or go
directly to the "OTel Lab — Service Map" dashboard.

---

## Quick verification

```bash
./prom_query.sh            # defaults to http://localhost:9090
./prom_query.sh http://localhost:9090
```

The script queries `rate(traces_service_graph_request_total[2m])` and
`rate(traces_service_graph_request_failed_total[2m])`, prints a table of
observed edges, and cross-checks them against the expected topology below.

---

## Expected topology

### Nodes

Any JVM container with the OTel agent attached appears as a node once it emits
at least one span that Tempo's service-graph processor sees.

| Node | Role | Why it appears |
|---|---|---|
| `producer` | Java app | sends Kafka records; OTel agent instruments KafkaProducer |
| `kafka` | Broker JVM | OTel agent attached to the official Kafka image |
| `consumer` | Java app | polls Kafka, writes HBase Puts |
| `query-client` | Java app | round-robins Scan / Get / Increment against HBase |
| `hbase-master` | HBase daemon | OTel agent; serves region assignment RPCs |
| `hbase-regionserver` | HBase daemon | OTel agent; handles all client RPCs |
| `hadoop-namenode` | HDFS daemon | OTel agent; mostly silent except its Jetty UI |
| `hadoop-datanode` | HDFS daemon | OTel agent; mostly silent at the protocol level |
| `zookeeper` | ZK daemon | OTel agent; nearly silent (ZK protocol not auto-instrumented) |
| `user` | synthetic phantom | Tempo synthesizes this for any SERVER span with no upstream CLIENT span — in this lab it is exclusively Docker's healthcheck `curl` traffic hitting Jetty UIs |

### Expected edges

| From → To | Why | Present |
|---|---|---|
| `producer` → `kafka` | KafkaProducer.send | ✓ |
| `kafka` → `consumer` | poll/consume with header propagation | ✓ |
| `consumer` → `hbase-regionserver` | HBase Put RPC; `peer.service` rewritten by the Collector's `transform/peer_service` processor | ✓ |
| `query-client` → `hbase-regionserver` | Scan / Get / Increment RPCs | ✓ |
| `hbase-master` → `hbase-regionserver` | region assignment calls | ✓ |
| `hbase-regionserver` → `hbase-master` | heartbeats | ✓ |
| `user` → `hadoop-namenode` | Docker healthcheck `curl http://namenode:9870/` | ✓ |
| `user` → `hbase-master` | Docker healthcheck `curl http://localhost:16010/` | ✓ |
| `user` → `hbase-regionserver` | Docker healthcheck `curl http://localhost:16030/` | ✓ |

### Expected absences

These paths carry real I/O but are **not** auto-instrumented; don't spend time
looking for them in the graph.

| Missing edge | Why absent |
|---|---|
| `hbase-regionserver` → `hadoop-datanode` | WAL block writes use Hadoop's DataTransferProtocol (custom binary on `:9866`), not gRPC — no OTel instrumentation |
| `hadoop-namenode` ↔ `hadoop-datanode` | Block reports and heartbeats use Hadoop IPC (protobuf-over-TCP on `:8020`) — not auto-instrumented |
| `consumer` ↔ `zookeeper` | ZooKeeper protocol is not instrumented by the OTel Java agent |
| `hbase-master` ↔ `zookeeper` | Same; HBase uses ZK for leader election and region tracking |
| `kafka` internal controller ↔ broker | Single-node KRaft — there is no peer, so no cross-node edge |
| `hadoop-namenode` ↔ `hadoop-datanode` (HDFS replication) | Same as the block-report case above |

To extend trace coverage into these gaps, see
[Extending traces into HDFS/Hadoop](#extending-traces-into-hdfshadoop) below.

---

## What is the `user` node?

`user` is **not a real service**. Tempo synthesizes it whenever it sees a
SERVER span that has no matching parent CLIENT span — i.e., the request arrived
from outside any trace context.

In this lab every `user → X` edge is Docker's healthcheck `curl`:

| Edge | Source |
|---|---|
| `user → hadoop-namenode` | `curl http://namenode:9870/` |
| `user → hbase-master` | `curl http://localhost:16010/` |
| `user → hbase-regionserver` | `curl http://localhost:16030/` |

The OTel Java agent's Jetty instrumentation captures each incoming HTTP request
as a SERVER span. A bare `curl` carries no W3C trace context, so Tempo parks
those orphan-server spans under the synthetic `user` node.

Removing the healthchecks would eliminate this top tier entirely and collapse
the graph to the data-path edges only.

---

## Timing: why an edge takes 30–90 s to appear

Tempo's `metrics_generator` flushes service-graph aggregations every 15 s.
Prometheus needs two scrape samples to compute a non-zero `rate()`. New edges
typically appear 30–90 s after the first request. If an expected edge is still
absent after 5 minutes:

```bash
docker compose logs producer --tail 20   # should show "Produced N records"
docker compose logs consumer --tail 20   # should show "Polled=N wrote=N"
curl -s 'http://localhost:9090/api/v1/query?query=traces_service_graph_request_total' | python3 -m json.tool
```

---

## Using the graph to troubleshoot

The graph is the entry point, not the answer. Each edge in Grafana is
clickable — it opens pre-built TraceQL and metric queries for that hop.
The diagnostic motion:

```
graph edge (find which hop is slow / failing)
   ↓
RED panels (per-service rate / errors / p99 over time)
   ↓
JMX dashboard for that service (queue depth, GC, internal counters)
   ↓
Tempo Explore (one specific bad request, span breakdown)
   ↓
Loki (log lines for that exact trace ID)
```

### Slow HBase Put / Get on the consumer side

1. **Hover the `consumer → hbase-regionserver` edge.** Grafana shows req/s,
   p99, error rate. Compare p99 to a healthy baseline (single-node, local disk
   → a few ms is normal).
2. **Click the edge → pick a slow trace.** The timeline shows time in the
   consumer's code vs. inside the HBase client RPC.
3. **Cross-reference RegionServer JMX** on the JMX dashboard:
   - `hbase_regionserver_ipc_processcalltime_99th_percentile` — server's own
     view. If high: RS was actually slow. If low: slowness is in the network
     or client pre-call path.
   - `hbase_regionserver_ipc_numcallsingeneralqueue` — nonzero means RS is
     queuing requests waiting for handler threads.
   - `hbase_regionserver_wal_synctime_99th_percentile` — WAL fsyncs are
     bounded by DataNode disk speed. If high, the bottleneck is HDFS.
   - JVM heap + GC — GC stop-the-world pauses look exactly like high p99
     RPC latency. Match GC spikes against latency spikes.
4. If RS RPC time is high but WAL/handler queues are fine → probably GC.
   Check `jvm_gc_collection_seconds_total{service="hbase-regionserver"}`.
5. If WAL sync time is high → HDFS is the bottleneck. Check
   `hadoop_datanode_byteswritten` rate and
   `hadoop_rpc_rpcprocessingtimeavgtime`.

### Concrete example: trace a single slow Put

```
1. Grafana → Explore → Tempo
2. TraceQL: { resource.service.name = "consumer" && duration > 100ms }
3. Click a result. Trace timeline shows:
     consumer.poll                 (5 ms)
     consumer.processRecord       (105 ms)  ← slow
       hbase.client.put           (102 ms)  ← slow
         (server-side HBase span   (98 ms))
4. Switch to "OTel Lab — JMX". Sync the time picker to the trace timestamp.
5. hbase_regionserver_ipc_numcallsingeneralqueue at that moment:
   - nonzero → RS saturated (too many concurrent clients)
   - zero    → probably GC
6. jvm_gc_collection_seconds_total{service="hbase-regionserver"} delta:
   - spike → GC pause was the cause
```

Three signals (trace, RPC queue, GC), one minute, root cause identified.

### HDFS capacity / replication issues

This lab is single-DN so real replication scenarios won't occur, but the
metrics that surface them are wired:

- `hadoop_namenode_underreplicatedblocks` — nonzero if a DN died
- `hadoop_namenode_corruptblocks`
- `hadoop_namenode_capacityremaining` — watch for sudden drops
- `hadoop_namenode_blockstotal` — growing without matching ingest growth
  means something is generating many small blocks

---

## Extending traces into HDFS/Hadoop

Three options to get trace continuity past the HBase → HDFS boundary, ranked
by effort:

| Option | Effort | What you get | Trace-ID continuity |
|---|---|---|---|
| **A. Custom OTel Java agent extension** — hook Hadoop's `RpcEngine` to extract W3C context from a custom call header and create child spans | High | Full in-band HDFS tracing, same trace tree as the client | Yes |
| **B. Hadoop's native OTel branch** (HADOOP-17560 lineage) — WIP patches for 3.3.x native OTel support | Medium | Full when stable | Yes |
| **C. eBPF observation** (Pixie, Tetragon) — kernel-level Hadoop RPC observation | Medium | Topology + per-call latency | No — synthetic spans, no parent linkage |

For a lab context, option A is the right shape: add a Maven module under
`apps/otel-extensions/` and load it via
`-Dotel.javaagent.extensions=/opt/otel/extensions/hadoop-rpc.jar`. NameNode ↔
DataNode heartbeat tracing generalizes from there.

Option C via eBPF gives you "is the network slow?" without requiring code
changes, but the spans won't be children of the client's trace tree.
