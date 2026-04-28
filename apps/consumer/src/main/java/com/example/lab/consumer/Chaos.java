package com.example.lab.consumer;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.ThreadLocalRandom;

/**
 * In-app chaos injection. Each call to {@link #maybe(String)} rolls two dice:
 *
 * <ol>
 *   <li>With probability {@code CHAOS_LATENCY_PROB}, sleep a uniformly-random
 *       duration in {@code [CHAOS_LATENCY_MS_MIN, CHAOS_LATENCY_MS_MAX]}.</li>
 *   <li>With probability {@code CHAOS_ERROR_PROB}, throw a
 *       {@link ChaosException}. Caller decides whether to swallow or propagate.</li>
 * </ol>
 *
 * <p>Both probabilities default to 0 (no chaos) so flipping it on is purely
 * a deploy-time concern. Triggered events are logged at WARN with the call
 * site's tag, so they show up alongside the corresponding span in Loki via
 * the trace_id MDC the OTel agent injects.
 *
 * <p>Why probabilistic instead of timed waves: the dashboards smooth out
 * over a 1m rate window anyway, and per-op probability gives deterministic
 * statistics ("with prob 0.05 of 200ms latency at 5 RPS, expect ~1 slow op
 * every 4 seconds").
 */
public final class Chaos {

    public static final class ChaosException extends RuntimeException {
        ChaosException(String tag) {
            super("Injected chaos error at " + tag);
        }
    }

    private static final Logger LOG = LoggerFactory.getLogger(Chaos.class);

    private static final double LATENCY_PROB =
            Double.parseDouble(envOr("CHAOS_LATENCY_PROB", "0"));
    private static final long LATENCY_MIN_MS =
            Long.parseLong(envOr("CHAOS_LATENCY_MS_MIN", "100"));
    private static final long LATENCY_MAX_MS =
            Long.parseLong(envOr("CHAOS_LATENCY_MS_MAX", "500"));
    private static final double ERROR_PROB =
            Double.parseDouble(envOr("CHAOS_ERROR_PROB", "0"));

    static {
        if (LATENCY_PROB > 0 || ERROR_PROB > 0) {
            LOG.warn("Chaos enabled: latencyProb={} latencyMs=[{},{}] errorProb={}",
                    LATENCY_PROB, LATENCY_MIN_MS, LATENCY_MAX_MS, ERROR_PROB);
        }
    }

    private Chaos() {}

    /**
     * Roll the dice for the given call site. Sleep first (so latency happens
     * even on the events that will throw), then throw if the error roll
     * comes up.
     *
     * <p>The {@code tag} is included in log lines / exception messages so
     * traces and logs are easy to correlate to the call site (e.g.,
     * {@code "producer.send"}, {@code "consumer.put"}, {@code "query.scan"}).
     */
    public static void maybe(String tag) {
        ThreadLocalRandom rng = ThreadLocalRandom.current();
        if (LATENCY_PROB > 0 && rng.nextDouble() < LATENCY_PROB) {
            long ms = (LATENCY_MAX_MS <= LATENCY_MIN_MS)
                    ? LATENCY_MIN_MS
                    : rng.nextLong(LATENCY_MIN_MS, LATENCY_MAX_MS + 1);
            LOG.warn("Chaos: injecting {}ms latency at {}", ms, tag);
            try {
                Thread.sleep(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
        if (ERROR_PROB > 0 && rng.nextDouble() < ERROR_PROB) {
            LOG.warn("Chaos: throwing error at {}", tag);
            throw new ChaosException(tag);
        }
    }

    private static String envOr(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v;
    }
}
