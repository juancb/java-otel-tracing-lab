# Reading the service graph

Stage A wires Tempo's service-graph processor through Prometheus into
Grafana's Node Graph. The graph is *derived from observed traffic* — every
edge represents a (client_service, server_service) pair Tempo has seen in
trace data, with rate / errors / latency annotations.

Open it from Grafana's left nav: **Explore -> Tempo datasource -> Service
Graph tab -> Run query**.

## What you see today (Stage A)

![Service Graph after Stage A](images/service-graph.png)

Two disconnected clusters appear, plus two orphan nodes near the bottom.
Both come from *different* sources of spans, and neither is wrong — they
just reflect what the JVM agent and HBase's built-in tracing each produce.

### Top cluster: `user -> hadoop-namenode`, `hadoop-datanode`, `hbase-master`, `hbase-regionserver`

These edges are not from the data pipeline. They are healthcheck traffic.

Every 10 seconds the Docker daemon runs `curl http://localhost:9870/`,
`localhost:9864/`, `localhost:16010/`, `localhost:16030/` against the four
Hadoop / HBase web UIs. The OTel Java agent auto-instruments Jetty (the
embedded HTTP server those UIs run on), so each curl turns into a SERVER
span on the receiving JVM. Curl from a shell has no incoming trace context,
so Tempo synthesizes a placeholder client called `user`.

Useful side-effect: this is how we know the agent is loaded and exporting
on those four JVMs. Not useful: it doesn't reflect actual data movement.

**This also answers "do we have HDFS in the lab?" - yes.** The
`hadoop-namenode` and `hadoop-datanode` nodes are the two HDFS daemons. The
data path through HDFS (RegionServer writes a WAL block -> DataNode stores
it) doesn't show up here because Hadoop IPC isn't auto-instrumented well by
the OTel Java agent. We'll surface that path through JMX in Stage B
instead.

### Bottom cluster: `consumer -> hbase` (often red)

This edge is the actual data write path: producer puts a record on Kafka,
consumer reads it, consumer writes a Put to HBase.

It dangles into a phantom node called `hbase` (not `hbase-master` or
`hbase-regionserver`) for an annoying reason: HBase 2.4+ ships *its own*
OTel client-side instrumentation that creates the client span with
`peer.service=hbase` baked in - the literal string. Tempo's service-graph
processor uses that attribute to label the destination, so it ends up as a
node named `hbase` regardless of which RegionServer or Master actually
served the RPC.

The fix that would join the two clusters together is one of:

- A Collector `transform` processor that rewrites `peer.service=hbase` to
  `peer.service=hbase-regionserver` (or `hbase-master` for admin RPCs)
  before the spans hit Tempo.
- Disable HBase's built-in tracing (set `hbase.htrace.spanreceiver.classes`
  empty in `hbase-site.xml`) and let the OTel agent's generic RPC
  instrumentation produce the spans instead. That preserves W3C trace
  context across the wire correctly.

We'll pick one of those when we get to Stage B. For Stage A the disconnect
is acceptable - it's still a usable debugging view.

### Why no `producer` node yet

The producer's `kafka.send` span carries `peer.service=kafka` (set by the
agent's Kafka instrumentation), so once the producer has been emitting for
a while inside the dashboard time window, an edge `producer -> kafka`
should appear. If it doesn't show up after 5+ minutes:

- Confirm the producer container is healthy: `docker compose logs producer --tail 20`
- Check the time picker is "Last 15m" or wider.
- Look at Prometheus directly:
  ```
  http://localhost:9090/graph?g0.expr=traces_service_graph_request_total
  ```
  If `producer` doesn't appear as a `client` label there, no spans are
  reaching the metrics_generator with `producer` as the source service.

### Why edges go red

Red = the edge has had non-zero error spans in the time window. The big red
`consumer -> hbase` 66-second p90 in the screenshot above is left over from
when HBase Master was crash-looping (HDFS had no DataNodes registered).
Tempo's metrics_generator counts those failed RPC attempts. After a few
minutes of clean traffic the edge transitions to green.

To clear stale errors, you can either wait the time window out or drop the
TSDB:

```
docker compose down
docker volume rm otel-lab_prometheus-data
docker compose up -d
```

## What the graph *should* look like once Stage B lands

```
producer -> kafka -> consumer -> hbase-regionserver -> hadoop-datanode
                                       |
                                       v
                                  hbase-master -> hadoop-namenode
                                       |
                                       v
                                  zookeeper
```

JMX-derived edges (Stage B) plus the peer-service rewrite should produce a
single connected component that mirrors the actual data path.
