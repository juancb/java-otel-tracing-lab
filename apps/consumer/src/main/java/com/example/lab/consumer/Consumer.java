package com.example.lab.consumer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.Admin;
import org.apache.hadoop.hbase.client.Connection;
import org.apache.hadoop.hbase.client.ConnectionFactory;
import org.apache.hadoop.hbase.client.Put;
import org.apache.hadoop.hbase.client.Table;
import org.apache.hadoop.hbase.client.TableDescriptor;
import org.apache.hadoop.hbase.client.TableDescriptorBuilder;
import org.apache.hadoop.hbase.client.ColumnFamilyDescriptorBuilder;
import org.apache.hadoop.hbase.util.Bytes;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.time.Instant;
import java.util.Collections;
import java.util.List;
import java.util.Properties;

/**
 * Polls Kafka and writes each record to HBase.
 *
 * <p>The OTel Java agent auto-instruments both the Kafka client (creating
 * {@code kafka.poll} and per-record consume spans) and the HBase client
 * (creating spans for the underlying RPCs). Trace context arrives in the
 * Kafka message headers, so spans on the consumer side automatically link
 * back to the producer's send span.
 *
 * <p>Row-key strategy: {@code deviceId|reverseTs} where {@code reverseTs}
 * is {@code Long.MAX_VALUE - epochMillis}. This makes scans-by-device return
 * newest readings first without needing a reverse scan.
 */
public final class Consumer {

    private static final Logger LOG = LoggerFactory.getLogger(Consumer.class);

    private static final ObjectMapper JSON =
            new ObjectMapper().registerModule(new JavaTimeModule());

    private static final byte[] CF = Bytes.toBytes("d");
    private static final byte[] Q_METRIC = Bytes.toBytes("metric");
    private static final byte[] Q_VALUE = Bytes.toBytes("value");
    private static final byte[] Q_TS = Bytes.toBytes("ts");

    public static void main(String[] args) throws Exception {
        String bootstrap = envOr("BOOTSTRAP_SERVERS", "kafka:9092");
        String topic = envOr("TOPIC", "sensor.readings");
        String groupId = envOr("GROUP_ID", "sensor-consumer");
        String zkQuorum = envOr("HBASE_ZK_QUORUM", "zookeeper");
        String tableName = envOr("HBASE_TABLE", "sensor_readings");

        LOG.info("Starting consumer: bootstrap={} topic={} group={} hbaseZk={} table={}",
                bootstrap, topic, groupId, zkQuorum, tableName);

        Configuration hConf = HBaseConfiguration.create();
        hConf.set("hbase.zookeeper.quorum", zkQuorum);
        hConf.set("hbase.zookeeper.property.clientPort", "2181");
        // Don't bother with HDFS-specific config; the client only talks to ZK + RegionServers.

        try (Connection hConn = ConnectionFactory.createConnection(hConf)) {
            ensureTable(hConn, tableName);

            Properties kProps = new Properties();
            kProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
            kProps.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
            kProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
            kProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
            kProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
            kProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
            kProps.put(ConsumerConfig.CLIENT_ID_CONFIG, "otel-lab-consumer");

            try (KafkaConsumer<String, String> kc = new KafkaConsumer<>(kProps);
                 Table table = hConn.getTable(TableName.valueOf(tableName))) {

                kc.subscribe(Collections.singletonList(topic));

                while (!Thread.currentThread().isInterrupted()) {
                    ConsumerRecords<String, String> batch = kc.poll(Duration.ofSeconds(1));
                    if (batch.isEmpty()) {
                        continue;
                    }

                    int wrote = 0;
                    java.util.List<Put> puts = new java.util.ArrayList<>(batch.count());
                    for (ConsumerRecord<String, String> rec : batch) {
                        Put put = toPut(rec);
                        if (put != null) {
                            puts.add(put);
                            wrote++;
                        }
                    }
                    if (!puts.isEmpty()) {
                        // batched put — one HBase RPC per region per batch
                        table.put(puts);
                    }
                    kc.commitSync();
                    if (LOG.isDebugEnabled()) {
                        LOG.debug("Polled={} wrote={}", batch.count(), wrote);
                    }
                }
            }
        }
    }

    private static Put toPut(ConsumerRecord<String, String> rec) {
        try {
            SensorReading reading = JSON.readValue(rec.value(), SensorReading.class);
            long reverseTs = Long.MAX_VALUE - reading.timestamp().toEpochMilli();
            String rowKey = reading.deviceId() + "|" + String.format("%019d", reverseTs);
            Put put = new Put(Bytes.toBytes(rowKey));
            put.addColumn(CF, Q_METRIC, Bytes.toBytes(reading.metric()));
            put.addColumn(CF, Q_VALUE, Bytes.toBytes(reading.value()));
            put.addColumn(CF, Q_TS, Bytes.toBytes(reading.timestamp().toEpochMilli()));
            return put;
        } catch (Exception e) {
            LOG.warn("Skipping un-parseable record at offset {}: {}", rec.offset(), e.getMessage());
            return null;
        }
    }

    /** Creates the target table if it does not exist. Idempotent. */
    private static void ensureTable(Connection conn, String name) throws Exception {
        TableName tn = TableName.valueOf(name);
        try (Admin admin = conn.getAdmin()) {
            if (admin.tableExists(tn)) {
                LOG.info("HBase table {} already exists", name);
                return;
            }
            LOG.info("Creating HBase table {}", name);
            TableDescriptor td = TableDescriptorBuilder.newBuilder(tn)
                    .setColumnFamily(ColumnFamilyDescriptorBuilder.of(CF))
                    .build();
            admin.createTable(td);
            LOG.info("Created HBase table {}", name);
        }
    }

    private static String envOr(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    /** Mirror of the producer-side record so Jackson can deserialize. */
    public record SensorReading(String deviceId, String metric, double value, Instant timestamp) {}
}
