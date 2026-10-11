+++
title = "Timeouts, retries and circuit breakers with Resilience4j"
description = "One slow service shouldn't take down the ones that call it. Setting timeouts on purpose, retrying carefully, and failing fast when a dependency is down"
date = "2020-09-27T18:15:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "timeouts-circuit-breakers-resilience4j"
author = "Milorad Bozic"
tags = ["distributed-systems", "resilience", "spring-boot", "java", "microservices"]

+++

In a system of services, a dependency that is **down** is the easy case: the call fails quickly and
you handle the error. The hard case is a dependency that is **slow**. Every call waits. Threads pile up
waiting. The calling service runs out of threads and stops responding. Now *its* callers are waiting.
One slow database query turns into an outage three services away.

The tools for this are old and well known: timeouts, retries, circuit breakers, bulkheads. We use
[Resilience4j](https://resilience4j.readme.io/) for them in our Spring Boot services. Hystrix used to
be the default choice, but Netflix put it in maintenance mode, and Resilience4j is lighter and plays
well with Spring Boot 2.

## 1. Every call has a timeout, chosen on purpose

The default timeout of many HTTP clients is "infinite" or something close to it. That's a decision
nobody made. Every outgoing call gets an explicit **connect timeout** and **read timeout**, based on
what the caller can afford, not on how long the dependency usually takes.

A good question to set it: "if this call takes longer than X, is the answer still useful?" For a
user waiting for a page, X is small. For a background job, it can be larger.

## 2. Retry, but carefully

Retries help with short, random failures: a dropped connection, one pod restarting. They hurt when the
dependency is overloaded, because now every caller sends it two or three times the traffic.

Our rules:

- Retry only **idempotent** operations. A `GET` is fine. A `POST` that creates something is only safe
  with an idempotency key, the same trick as [answers with client-generated ids](/blog/offline-first-answer-saving/).
- **Few attempts, with backoff** (and some randomness, so all callers don't retry at the same moment).
- Never retry at **every** layer. If the gateway retries 3 times and the service behind it retries 3
  times and the service behind *that* does too, one failure becomes 27 calls.

```yaml
resilience4j.retry:
  instances:
    contentService:
      maxRetryAttempts: 3
      waitDuration: 200ms
      retryExceptions:
        - java.io.IOException
        - java.util.concurrent.TimeoutException
```

## 3. Circuit breaker: stop calling what's broken

If a dependency has been failing for the last minute, the next call will most likely fail too. Making
it anyway costs a thread, a timeout's worth of waiting, and load on a service that's already in trouble.

A circuit breaker counts failures (and slow calls). When too many of the recent calls fail, it **opens**:
calls fail immediately, without touching the network. After a while it lets a few test calls through
(**half-open**). If they succeed, it closes again.

```yaml
resilience4j.circuitbreaker:
  instances:
    contentService:
      slidingWindowSize: 50
      failureRateThreshold: 50
      slowCallDurationThreshold: 2s
      slowCallRateThreshold: 50
      waitDurationInOpenState: 30s
      permittedNumberOfCallsInHalfOpenState: 5
```

```java
@CircuitBreaker(name = "contentService", fallbackMethod = "cachedContent")
@Retry(name = "contentService")
public Content content(String id) {
    return contentClient.get(id);
}

private Content cachedContent(String id, Throwable cause) {
    return contentCache.get(id)
        .orElseThrow(() -> new ContentUnavailableException(id, cause));
}
```

Counting **slow** calls as failures is the part that matters most. A dependency that answers in 20
seconds is worse for you than one that doesn't answer at all.

## 4. Have a plan for "it's down"

A circuit breaker only moves the question: when the call fails fast, what do you do? Options, from best
to worst:

- **A useful fallback**: a cached value, a default, a reduced response. The [gateway's aggregate
  endpoints](/blog/api-gateway-facade/) return partial data when one part is missing.
- **Do it later**: put the work on a [queue](/blog/rabbitmq-retries-dead-letters/) and tell the user
  it's being processed.
- **A clear error**, quickly. Still much better than a page that hangs for 30 seconds.

## 5. Bulkheads: don't let one dependency eat all threads

If all outgoing calls share one thread pool, a single slow dependency can use all of it, and calls to
healthy dependencies have nothing left. A **bulkhead** limits how many concurrent calls go to each
dependency. When the limit is reached, extra calls fail immediately instead of waiting.

## 6. Watch it

Resilience4j exposes metrics through Micrometer: circuit breaker state, failure rates, retries. A circuit
breaker opening is an event you want to know about, and a dashboard where you can see which breakers
are open is the fastest way to answer "what's broken right now?"

## Summary

- Explicit timeouts on every call, based on what the caller can afford.
- Retries only for idempotent calls, with backoff, at one layer.
- Circuit breakers that also count slow calls.
- A fallback plan for when the breaker is open.
- Bulkheads so one dependency can't take every thread.

In a monolith, a slow function makes one request slow. In a distributed system, without these, it can
make everything slow. The patterns are not new, and that's the point: they're the price of having a
network between your modules.
