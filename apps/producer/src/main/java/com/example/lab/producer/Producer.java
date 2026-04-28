package com.example.lab.producer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.Properties;
import java.util.Random;
import java.util.concurrent.TimeUnit;

/**
 * Synthetic sensor-telemetry producer.
 *
 * <p>The whole point of this class is to drive realistic Kafka traffic so
 * that the OpenTelemetry Java agent (attached at runtime via {@code -javaagent})
 * has something to instrument. This file therefore contains <em>no</em>
 * tracing code — the agent's Kafka instrumentation creates spans for every
 * {@code KafkaProducer#send} call automatically, including the W3C Trace
 * Context headers that propagate to the consumer.
 *
 * <p>Configuration via environment variables (sensible defaults baked in
 * for laptop runs):
 * <ul>
 *   <li>{@code BOOTSTRAP_SERVERS} — Kafka broker(s); default {@code kafka:9092}</li>
 *   <li>{@code TOPIC} — destination topic; default {@code sensor.readings}</li>
 *   <li>{@code RATE_PER_SEC} — messages per second; default {@code 5}</li>
 *   <li>{@code NUM_DEVICES} — distinct device IDs to simulate; default {@code 50}</li>
 * </ul>
 */
public final class Producer {

    private static final Logger LOG = LoggerFactory.getLogger(Producer.class);

    private static final ObjectMapper JSON =
            new ObjectMapper().registerModule(new JavaTimeModule());

    /** Metric names we'll round-robin across. */
    private static final String[] METRICS = {
            "temperature_c", "humidity_pct", "pressure_hpa", "vibration_g"
    };

    public static void main(String[] args) throws Exception {
        String bootstrap = envOr("BOOTSTRAP_SERVERS", "kafka:9092");
        String topic = envOr("TOPIC", "sensor.readings");
        int ratePerSec = Integer.parseInt(envOr("RATE_PER_SEC", "5"));
        int numDevices = Integer.parseInt(envOr("NUM_DEVICES", "50"));

        LOG.info("Starting producer: bootstrap={} topic={} rate/s={} devices={}",
                bootstrap, topic, ratePerSec, numDevices);

        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        // Reasonable defaults for a learning environment. We want each send
        // to produce its own span, so don't batch too aggressively.
        props.put(ProducerConfig.LINGER_MS_CONFIG, "10");
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "otel-lab-producer");

        long sleepNanos = TimeUnit.SECONDS.toNanos(1) / Math.max(1, ratePerSec);
        Random rng = new Random();

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            // Block until the first attempted send so we crash fast if the
            // broker DNS / network is wrong.
            long sent = 0;
            while (!Thread.currentThread().isInterrupted()) {
                String deviceId = String.format("device-%04d", rng.nextInt(numDevices));
                String metric = METRICS[rng.nextInt(METRICS.length)];
                double value = baselineFor(metric) + rng.nextGaussian() * 2.0;
                Instant now = Instant.now();

                SensorReading reading = new SensorReading(deviceId, metric, value, now);
                String json = JSON.writeValueAsString(reading);

                ProducerRecord<String, String> record =
                        new ProducerRecord<>(topic, deviceId, json);

                producer.send(record, (md, ex) -> {
                    if (ex != null) {
                        LOG.warn("Send failed", ex);
                    } else if (LOG.isDebugEnabled()) {
                        LOG.debug("Sent partition={} offset={}", md.partition(), md.offset());
                    }
                });

                if (++sent % 100 == 0) {
                    LOG.info("Produced {} records", sent);
                }
                LockSupport.parkNanos(sleepNanos);
            }
        }
    }

    /** Plausible baseline value for the given metric, so traces look realistic. */
    private static double baselineFor(String metric) {
        return switch (metric) {
            case "temperature_c" -> 22.0;
            case "humidity_pct" -> 45.0;
            case "pressure_hpa" -> 1013.0;
            case "vibration_g" -> 0.05;
            default -> 0.0;
        };
    }

    private static String envOr(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    // Avoid pulling in another dependency just for park.
    private static final class LockSupport {
        static void parkNanos(long nanos) {
            java.util.concurrent.locks.LockSupport.parkNanos(nanos);
        }
    }

    /** Wire format we send to Kafka. Public-record-style shape for readability. */
    public record SensorReading(String deviceId, String metric, double value, Instant timestamp) {}
}
