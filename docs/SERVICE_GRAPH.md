# Reading the service graph

Stage A wires Tempo's service-graph processor through Prometheus into
Grafana's Node Graph. Every edge represents a (client_service, server_service)
pair Tempo has observed in trace data, with rate / errors / latency
annotations on hover.

Open it from Grafana's left nav: **Explore -> Tempo -> Service Graph -> Run query**.

## What you see today (Stage A + Stage B applied)

![Service Graph after Stage B](images/service-graph.png)

Three edges from a synthetic `user` node:

```
user -> hadoop-namenode
user -> hbase-master
user -> hbase-regionserver
```

Plus, once the consumer has been writing for a couple of minutes, an edge:

```
consumer -> hbase-regionserver
```

## What is the `user` node?

`user` is **not** a real service. It's a placeholder Tempo's service-graph
generator synthesizes whenever it sees a SERVER span that has no matching
parent CLIENT span - i.e., the request arrived from outside the trace
context graph.

In this lab, every `user -> X` edge is **Docker's healthcheck curl**:

| Edge                       | Caller of the curl                                  |
|----------------------------|-----------------------------------------------------|
| `user -> hadoop-namenode`  | `curl http://localhost:9870/` on the NN container   |
| `user -> hadoop-datanode`  | `curl http://namenode:9870/jmx?qry=...`             |
| `user -> hbase-master`     | `curl http://localhost:16010/`                      |
| `user -> hbase-regionserver` | `curl http://localhost:16030/`                    |

The OTel Java agent's Jetty server instrumentation captures each of those
incoming HTTP requests as a SERVER span. Curl from a shell carries no W3C
trace context, so Tempo paints them as orphan-server spans and groups them
under the synthetic `user`.

If you removed the healthchecks, this entire top tier would disappear and
the graph would collapse to just `consumer -> hbase-regionserver`.

## What about the `hadoop-namenode` node? Is that HDFS?

Yes - **`hadoop-namenode` and `hadoop-datanode` ARE HDFS.** The two HDFS
daemon roles in the lab use those as their `OTEL_SERVICE_NAME`. Without
Stage B, only the NameNode shows up because only its UI was getting
healthchecked. With Stage B, the DataNode JMX endpoint is also being
scraped (on port 7075), so you'll see it appear once we add it to the
healthcheck rotation.

What you do **not** see in the service graph today is the actual HDFS
*data path* - the WAL block writes from RegionServer to DataNode, the
NameNode metadata RPCs from RegionServer for block lookups. Those happen
over Hadoop IPC, which the OTel Java agent doesn't auto-instrument
end-to-end. Stage B fills that gap with **JMX-derived metrics** on the
new "OTel Lab - JMX" dashboard, where you can see DataNode block IO
rates, NameNode capacity, and RegionServer WAL append latency.

## Why the missing producer / consumer / kafka nodes

The three top edges are healthcheck noise. The data path is:

```
producer (kafka.send)
  -> kafka:9092 (peer.service=kafka)
       -> consumer (kafka.poll)
            -> hbase-regionserver (peer.service=hbase, rewritten by Collector)
                 -> hadoop-* (RPC, not instrumented as spans)
```

You'll see those edges populate as data flows. The Tempo metrics_generator
flushes service-graph aggregations every 15s, and Prometheus needs at least
two samples to compute a rate, so brand-new edges typically appear in the
graph 30-90 seconds after the first request.

If after 5+ minutes the data-path edges still aren't there, the producer
or consumer probably isn't actually sending traffic. Quick checks:

```bash
docker compose logs producer --tail 20    # should see "Produced N records" lines
docker compose logs consumer --tail 20    # should see "Polled=N wrote=N" debug lines
curl 'http://localhost:9090/api/v1/query?query=traces_service_graph_request_total' | jq
```

## Using this to troubleshoot

The graph is the entry point, not the answer. Each edge clicks through to
underlying TraceQL searches and metric panels. The diagnostic flow shape:

### Slow HBase Put / Get on the consumer side

1. **Look at the edge** `consumer -> hbase-regionserver` in the graph. Hover
   shows requests/sec, p99 duration, error rate. Compare p99 against your
   eyeball of "what should this take" (single-node, local disk -> a few
   ms is normal).
2. **Click the consumer edge** and pick a slow trace. The trace timeline
   shows the breakdown: time spent in the consumer's local code vs. time
   inside the HBase client RPC.
3. **Cross-reference RegionServer JMX** on the JMX dashboard:
   - `hbase_regionserver_ipc_processcalltime_99th_percentile` - server's
     own view of how long it took to handle the RPC. If this is high too,
     the work was actually slow at the RS. If it's low, the slowness is in
     the network or in the consumer's pre-call path.
   - `hbase_regionserver_ipc_numcallsingeneralqueue` - if non-zero, RS is
     queueing requests waiting for handlers.
   - `hbase_regionserver_wal_synctime_99th_percentile` - WAL fsyncs are
     bounded by HDFS DataNode disk speed. If high, the bottleneck is in
     HDFS, not HBase.
   - JVM heap + GC pause - GC stop-the-world pauses look like high p99
     RPC latency. Match GC time spikes against latency spikes.
4. **If RS RPC time is high but WAL/handler queues are fine**: probably
   GC. Look at the JMX dashboard's `jvm_gc_collection_seconds_total{gc=...}`.
5. **If WAL sync time is high**: the bottleneck is HDFS. Look at
   `hadoop_datanode_byteswritten` rate and `hadoop_rpc_rpcprocessingtimeavgtime`.

### HDFS replication / capacity issues

This lab is single-DN, so you won't see real replication scenarios. But the
metrics that *would* surface them are wired:

- `hadoop_namenode_underreplicatedblocks` (would be nonzero if a DN died)
- `hadoop_namenode_corruptblocks`
- `hadoop_namenode_capacityremaining` - watch for sudden drops
- `hadoop_namenode_blockstotal` - if growing fast without ingest growing,
  something is generating small blocks

### General system faults

The diagnostic motion is always the same triangle:

```
graph edge (find which hop is slow / failing)
   ↓
RED panels (per service rate / errors / p99 over time)
   ↓
JMX panel for that service (queue depth, GC, internal counters)
   ↓
trace explorer (one specific bad request, span breakdown)
```

Future stages will fill in the other corners:

- **Stage C** (Loki + trace-id MDC): from the trace explorer, jump to the
  actual log lines for that request. "Consumer threw an exception at
  18:23:14" -> click the trace -> see `RegionTooBusyException` in the log.
- **Stage D** (container metrics + alerts): when JVM heap or container CPU
  is the actual cause, surface it as its own panel and alert on it.
- **Stage E** (synthetic probes + chaos drill): so you can practice the
  flow above against deliberately-broken scenarios without waiting for a
  real incident.

## Concrete example: trace a single slow Put

```
1. Grafana -> Explore -> Tempo
2. TraceQL tab. Query: { resource.service.name = "consumer" && duration > 100ms }
3. Click a result. Trace view shows:
     consumer.poll                  (5ms)
     consumer.processRecord         (105ms)  ← slow
       hbase.client.put             (102ms)  ← slow
         (server-side HBase span    (98ms)   ← if instrumentation captured it)
4. The slow component is the HBase Put. Switch to the "OTel Lab - JMX"
   dashboard. Sync the time picker to the trace's timestamp.
5. Look at hbase_regionserver_ipc_numcallsingeneralqueue at that time. If
   nonzero -> RS was saturated. If zero -> probably GC.
6. Look at jvm_gc_collection_seconds_total{service="hbase-regionserver"}
   delta around that window. Spike -> GC pause was the cause.
```

Three signals (trace, RPC queue, GC), one minute, root cause identified.
