package com.example.lab.queryclient;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.Connection;
import org.apache.hadoop.hbase.client.ConnectionFactory;
import org.apache.hadoop.hbase.client.Get;
import org.apache.hadoop.hbase.client.Increment;
import org.apache.hadoop.hbase.client.Result;
import org.apache.hadoop.hbase.client.ResultScanner;
import org.apache.hadoop.hbase.client.Scan;
import org.apache.hadoop.hbase.client.Table;
import org.apache.hadoop.hbase.util.Bytes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Random;
import java.util.concurrent.TimeUnit;

/**
 * Drives read traffic against HBase. The OTel Java agent auto-instruments
 * the HBase client, so each Scan / Get / Increment shows up as a span in
 * Tempo and pivots into Loki via the trace_id MDC key in the log layout.
 *
 * <p>Three operation modes round-robin per tick (interval =
 * {@code QUERY_INTERVAL_MS}):
 * <ol>
 *   <li><b>scan</b>: Scan recent rows, capped by {@code SCAN_LIMIT}. The
 *       row key layout (deviceId|reverseTs) means a per-device scan is
 *       newest-first by construction.</li>
 *   <li><b>get</b>: Get a single row for a randomly-chosen device's
 *       latest reading. Demonstrates point-lookup latency vs. the
 *       BlockCache.</li>
 *   <li><b>increment</b>: Atomic increment on a counter cell on a shared
 *       row, then Get to read it back. Exercises HBase's compare-and-
 *       increment path, which crosses both the WAL and the regionserver
 *       memstore. Useful for showing read-after-write tail latency.</li>
 * </ol>
 *
 * <p>Each operation rolls the {@link Chaos} dice before issuing the RPC
 * so latency and errors can be injected on the read path independently
 * of the producer/consumer.
 *
 * <p>Configuration via env vars (see also {@link Chaos} for chaos vars):
 * <ul>
 *   <li>{@code HBASE_ZK_QUORUM} (default {@code zookeeper})</li>
 *   <li>{@code HBASE_TABLE} (default {@code sensor_readings})</li>
 *   <li>{@code QUERY_INTERVAL_MS} (default {@code 2000})</li>
 *   <li>{@code SCAN_LIMIT} (default {@code 20})</li>
 *   <li>{@code NUM_DEVICES} (default {@code 50}; matches the producer)</li>
 *   <li>{@code COUNTER_TABLE} (default {@code sensor_counters}; created
 *       on first run)</li>
 * </ul>
 */
public final class QueryClient {

    private static final Logger LOG = LoggerFactory.getLogger(QueryClient.class);

    private static final byte[] CF = Bytes.toBytes("d");
    private static final byte[] Q_VALUE = Bytes.toBytes("value");
    private static final byte[] Q_TS = Bytes.toBytes("ts");
    private static final byte[] Q_METRIC = Bytes.toBytes("metric");

    // Counter table layout: a single shared "totals" row per metric, with
    // one column per device. Get/Increment touches just one cell.
    private static final byte[] COUNTER_CF = Bytes.toBytes("c");
    private static final byte[] COUNTER_ROW = Bytes.toBytes("totals");
    private static final byte[] COUNTER_QUAL = Bytes.toBytes("queries");

    public static void main(String[] args) throws Exception {
        String zkQuorum = envOr("HBASE_ZK_QUORUM", "zookeeper");
        String tableName = envOr("HBASE_TABLE", "sensor_readings");
        String counterTableName = envOr("COUNTER_TABLE", "sensor_counters");
        long intervalMs = Long.parseLong(envOr("QUERY_INTERVAL_MS", "2000"));
        int scanLimit = Integer.parseInt(envOr("SCAN_LIMIT", "20"));
        int numDevices = Integer.parseInt(envOr("NUM_DEVICES", "50"));

        LOG.info("Starting query-client zk={} table={} counterTable={} intervalMs={} scanLimit={} devices={}",
                zkQuorum, tableName, counterTableName, intervalMs, scanLimit, numDevices);

        Configuration hConf = HBaseConfiguration.create();
        hConf.set("hbase.zookeeper.quorum", zkQuorum);
        hConf.set("hbase.zookeeper.property.clientPort", "2181");

        Random rng = new Random();
        long tick = 0;

        try (Connection hConn = ConnectionFactory.createConnection(hConf)) {
            ensureCounterTable(hConn, counterTableName);

            try (Table dataTable = hConn.getTable(TableName.valueOf(tableName));
                 Table counterTable = hConn.getTable(TableName.valueOf(counterTableName))) {

                while (!Thread.currentThread().isInterrupted()) {
                    int mode = (int) (tick % 3);
                    try {
                        switch (mode) {
                            case 0 -> doScan(dataTable, scanLimit);
                            case 1 -> doGet(dataTable, rng, numDevices);
                            case 2 -> doIncrementAndRead(counterTable, rng, numDevices);
                            default -> throw new IllegalStateException("unreachable");
                        }
                    } catch (Chaos.ChaosException ce) {
                        LOG.warn("Skipping query due to chaos: {}", ce.getMessage());
                    } catch (Exception e) {
                        LOG.warn("Query failed: {}", e.toString());
                    }
                    tick++;
                    Thread.sleep(intervalMs);
                }
            }
        }
    }

    /** Mode 0: scan the latest rows up to a cap. */
    private static void doScan(Table table, int limit) throws Exception {
        Chaos.maybe("query.scan");
        long t0 = System.nanoTime();
        Scan scan = new Scan().setLimit(limit).setCaching(Math.min(limit, 100));
        int rows = 0;
        try (ResultScanner scanner = table.getScanner(scan)) {
            for (Result r = scanner.next(); r != null; r = scanner.next()) {
                rows++;
            }
        }
        long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
        LOG.info("scan rows={} elapsedMs={}", rows, ms);
    }

    /** Mode 1: point Get for the latest row of a randomly-picked device. */
    private static void doGet(Table table, Random rng, int numDevices) throws Exception {
        Chaos.maybe("query.get");
        String deviceId = String.format("device-%04d", rng.nextInt(numDevices));
        // Reverse-ts row key: any row in the device's range starts with
        // "deviceId|"; the *latest* row is the one with the smallest
        // reverseTs prefix. We do a tiny prefix scan limited to 1 row.
        String prefix = deviceId + "|";
        long t0 = System.nanoTime();
        Scan scan = new Scan()
                .setRowPrefixFilter(Bytes.toBytes(prefix))
                .setLimit(1)
                .setCaching(1);
        try (ResultScanner scanner = table.getScanner(scan)) {
            Result r = scanner.next();
            long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
            if (r == null || r.isEmpty()) {
                LOG.info("get device={} hit=false elapsedMs={}", deviceId, ms);
            } else {
                String metric = Bytes.toString(r.getValue(CF, Q_METRIC));
                double value = r.getValue(CF, Q_VALUE) != null
                        ? Bytes.toDouble(r.getValue(CF, Q_VALUE)) : Double.NaN;
                long ts = r.getValue(CF, Q_TS) != null
                        ? Bytes.toLong(r.getValue(CF, Q_TS)) : 0L;
                LOG.info("get device={} metric={} value={} ts={} elapsedMs={}",
                        deviceId, metric, value, ts, ms);
            }
        }
    }

    /** Mode 2: atomic increment of a counter cell, then read it back. */
    private static void doIncrementAndRead(Table table, Random rng, int numDevices) throws Exception {
        Chaos.maybe("query.increment");
        String deviceId = String.format("device-%04d", rng.nextInt(numDevices));
        byte[] qual = Bytes.toBytes(deviceId);

        long t0 = System.nanoTime();
        Increment incr = new Increment(COUNTER_ROW).addColumn(COUNTER_CF, qual, 1L);
        Result incrResult = table.increment(incr);
        byte[] afterBytes = incrResult.getValue(COUNTER_CF, qual);
        long after = afterBytes != null ? Bytes.toLong(afterBytes) : -1L;
        // Separate Get to demonstrate the read-after-write span pair in
        // Tempo. In real code you'd just trust the increment return value.
        Get get = new Get(COUNTER_ROW).addColumn(COUNTER_CF, qual);
        Result r = table.get(get);
        long counter = (r == null || r.isEmpty())
                ? -1L
                : Bytes.toLong(r.getValue(COUNTER_CF, qual));
        long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
        LOG.info("incr device={} after={} readback={} elapsedMs={}",
                deviceId, after, counter, ms);
    }

    private static void ensureCounterTable(Connection conn, String name) throws Exception {
        TableName tn = TableName.valueOf(name);
        try (var admin = conn.getAdmin()) {
            if (admin.tableExists(tn)) {
                LOG.info("HBase counter table {} already exists", name);
                return;
            }
            LOG.info("Creating HBase counter table {}", name);
            var td = org.apache.hadoop.hbase.client.TableDescriptorBuilder.newBuilder(tn)
                    .setColumnFamily(org.apache.hadoop.hbase.client.ColumnFamilyDescriptorBuilder.of(COUNTER_CF))
                    .build();
            admin.createTable(td);
            LOG.info("Created HBase counter table {}", name);
        }
    }

    private static String envOr(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v;
    }
}
