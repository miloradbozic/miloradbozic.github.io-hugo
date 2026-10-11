+++
title = "RabbitMQ with Spring Boot: retries, dead letters and the message that comes twice"
description = "Durable queues, publisher confirms, delayed retries via TTL and dead-letter exchanges, and why every consumer must be idempotent"
date = "2019-07-14T19:00:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "rabbitmq-retries-dead-letters"
author = "Milorad Bozic"
tags = ["distributed-systems", "rabbitmq", "messaging", "spring-boot", "java"]

+++

When a seafarer finishes an assessment, several things have to happen: the result is scored and
stored, reports are updated, the LMS that launched the test gets the outcome, maybe a certificate is
generated. None of that should make the person wait, and none of it should fail because one of those
systems is having a bad day.

So "attempt finished" is an **event** on RabbitMQ, and each of those things is a consumer. The
setup is simple to start with. Making it reliable takes a few more pieces, so here they are in one
place.

## 1. Don't lose the message on the way in

Two things must be true before you can say "the message is safe":

- The queue is **durable** and the message is **persistent**, so a broker restart doesn't drop it.
- The publisher gets a **confirm** from the broker. Without confirms, `convertAndSend` returning
  means "I handed it to the client library", not "RabbitMQ has it".

```yaml
spring:
  rabbitmq:
    publisher-confirms: true
    publisher-returns: true
```

```java
rabbitTemplate.setConfirmCallback((correlation, ack, cause) -> {
    if (!ack) {
        log.error("Message not confirmed: {} ({})", correlation, cause);
        // keep it for re-publishing instead of pretending it was sent
    }
});
```

There's still a gap: if you save to the database and then publish, the service can die in between.
The proper fix is a transactional outbox (save the event in the same transaction as the data, publish
from there). We do that for the events that matter most.

## 2. Ack after the work, not before

Consumers use manual acknowledgment: the message is acked only after the work is done. If the consumer
crashes halfway, the message goes back to the queue and someone else gets it. That's what you want.

It also means the same message **will** sometimes be processed twice: the work was done, then the
consumer died before the ack. Which brings us to the most important rule.

## 3. Every consumer is idempotent

Every event carries a unique id. Consumers record the ids they have handled, or better, make the
operation naturally idempotent: "set the result of attempt 42 to 85%" is safe to run twice, "add 85 to
the total" is not.

This is the same rule I keep writing about, [for queues](/blog/invoice-fan-out-sqs/) and [for flaky
networks](/blog/offline-first-answer-saving/). I'm starting to think it's the only rule.

## 4. Retry later, not right now

When a consumer fails because the LMS is down, retrying immediately is useless. It's still down 5 ms
later. And a message that fails instantly and is requeued instantly turns your consumer into a busy
loop.

RabbitMQ doesn't have delayed retries built in, but you can build them with two features: a
**message TTL** and a **dead-letter exchange**.

```
results.exchange ──> results.queue ──(consumer fails, reject without requeue)
                          │
                          └─ dead-letter → results.retry.queue  (x-message-ttl = 30s, no consumers)
                                                  │
                                                  └─ when TTL expires, dead-letter back → results.queue
```

The retry queue has no consumers. Messages sit there until their TTL expires, then they're
dead-lettered back to the main queue for another try. In Spring:

```java
@Bean
Queue resultsQueue() {
    return QueueBuilder.durable("results.queue")
        .withArgument("x-dead-letter-exchange", "")
        .withArgument("x-dead-letter-routing-key", "results.retry.queue")
        .build();
}

@Bean
Queue resultsRetryQueue() {
    return QueueBuilder.durable("results.retry.queue")
        .withArgument("x-message-ttl", 30000)
        .withArgument("x-dead-letter-exchange", "")
        .withArgument("x-dead-letter-routing-key", "results.queue")
        .build();
}
```

## 5. Give up eventually: the parking lot

Some messages will never succeed: bad data, a bug, a result for an attempt that doesn't exist. Without
a limit they go round forever.

RabbitMQ records each dead-lettering in the `x-death` header, including a count. The consumer checks
it, and after N attempts publishes the message to a **parking lot** queue instead of retrying. Nothing
consumes the parking lot automatically. It's for humans: an alert when it's not empty, and a small tool
to look at a message and either re-publish it or drop it.

## 6. Know what's happening

The numbers worth watching: queue depth per queue, the age of the oldest message, consumer count (zero
consumers on a busy queue is an outage, even if nothing is "down"), and the size of the parking lot.

## Summary

- Durable queues, persistent messages, publisher confirms.
- Manual ack after the work.
- Idempotent consumers, always.
- Delayed retries with TTL + dead-letter exchange.
- A parking lot and a human for what can't be retried.

None of this is complicated on its own. The trick is having all of it in place before the first time
something downstream is down for an hour.
