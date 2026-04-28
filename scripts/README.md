# Helper scripts

## `chatter.sh` / `chatter.ps1`

Drives synthetic admin + DML traffic against HBase so the service graph and
trace explorer have something to show beyond steady-state producer/consumer
flow. Each cycle:

1. Creates a uniquely-named temp table (`chatter_N`)
2. Puts three rows (drives WAL append + memstore write spans)
3. Flushes the table (RS -> HDFS WAL/StoreFile activity)
4. Scans the table back (RS read path)
5. Disables and drops the table (master region-close + meta updates)
6. Every 5 cycles, also runs `status 'detailed'` + balancer toggle for
   master-internal procedure activity.

### Run from the repo root

```bash
# Linux / macOS / Git Bash / WSL
bash scripts/chatter.sh

# Windows PowerShell
.\scripts\chatter.ps1
```

Override the cycle interval with `INTERVAL_SECS=30 bash scripts/chatter.sh`
or `.\scripts\chatter.ps1 -IntervalSecs 30`. Stop with Ctrl+C.

### What you should see in Tempo afterwards

In Grafana **Explore -> Tempo -> TraceQL**:

```
{ resource.service.name = "hbase-master" && name =~ ".*Procedure.*" }
{ resource.service.name = "hbase-regionserver" && name =~ ".*Mutate|Flush.*" }
{ resource.service.name =~ "hbase-.*" }
```

In **Explore -> Tempo -> Service Graph** the edges
`consumer -> hbase-regionserver`, `hbase-master -> hbase-regionserver`, and
(intermittently) `hbase-regionserver -> hadoop-datanode` should fill in.
