+++
title = "Spring Boot on Kubernetes: memory, probes and shutting down politely"
description = "The JVM inside a container limit, readiness versus liveness, and draining traffic before a pod goes away"
date = "2019-10-20T18:00:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "spring-boot-on-kubernetes"
author = "Milorad Bozic"
tags = ["kubernetes", "spring-boot", "java", "devops", "distributed-systems"]

+++

Our Spring Boot services run on Kubernetes now. Getting a jar into a container and a container into
a cluster is the easy part, and there are a hundred tutorials for it. These are the things that are
easy to get wrong after that, and that every Java service on Kubernetes needs to get right.

## 1. The JVM and the container memory limit

You give the pod a memory limit, say 1 GiB. If the process goes over it, the kernel kills it
(`OOMKilled`), no exception, no stack trace, just a restart.

Older JVMs didn't know about container limits and sized the heap from the memory of the whole
**node**. On a big node that meant a heap far larger than the limit, and an OOM kill as soon as the
service got busy. Since Java 8u191 (and Java 10+) the JVM reads the container limit. Use that, and
size the heap as a percentage:

```yaml
env:
  - name: JAVA_OPTS
    value: "-XX:MaxRAMPercentage=70.0"
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "1Gi"
```

Why 70% and not 100%: the heap is not the only memory a JVM uses. Metaspace, thread stacks, direct
buffers and the code cache live outside it. Leave room for them.

Setting request equal to limit for memory also means the pod gets what it asked for and isn't the
first to be evicted when a node is under pressure.

## 2. Readiness and liveness are different questions

- **Readiness:** "Should this pod get traffic right now?" If not, Kubernetes takes it out of the
  Service, but leaves it running.
- **Liveness:** "Is this pod broken beyond repair?" If not, Kubernetes **kills and restarts** it.

The mistake is using the same check for both, especially a check that includes dependencies. If
liveness checks the database and the database is slow for a minute, Kubernetes restarts *every* pod of
the service at once. Now you have a database problem and an outage.

Our rule:

- Liveness: the process is up and can answer an HTTP request. Nothing else.
- Readiness: the app has finished starting and can do its job, which may include its critical
  dependencies.

```yaml
readinessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 20
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /actuator/info
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 6
```

Spring Boot starts slowly, so the liveness probe needs a generous initial delay. Otherwise a pod that
is still starting gets killed for being "dead", starts again, and never gets to finish.

## 3. Shut down politely

When a pod is deleted (a deploy, a scale-down, a node drain), two things happen **at the same time**:
Kubernetes sends `SIGTERM` to the container, and it starts removing the pod from the Service endpoints.
"At the same time" means the pod can get the signal while load balancers still send it new requests.
If the app stops immediately, those requests fail. You see a handful of 502s on every deploy and it
looks random.

The fix has two parts:

**Wait a little before stopping**, so the endpoint removal has time to reach everyone:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 10"]
terminationGracePeriodSeconds: 40
```

**Finish in-flight requests** instead of dropping them when the JVM shuts down. Spring Boot doesn't do
this out of the box with embedded Tomcat at the moment, so we have a small shutdown hook that stops
accepting new connections and waits for running requests to finish, up to a timeout.

For queue consumers, "politely" means stop taking new messages, finish (and ack) the current one, then
exit. Anything not acked goes back to the queue, which is fine as long as [consumers are
idempotent](/blog/rabbitmq-retries-dead-letters/).

## 4. Config and secrets from the environment

The same image goes to every environment. Configuration comes from ConfigMaps and Secrets as
environment variables, which Spring Boot picks up without any extra code
(`SPRING_DATASOURCE_URL` becomes `spring.datasource.url`). It's the [immutable image
idea](/blog/immutable-servers-packer-ansible-terraform/) from two years ago, just with containers
instead of AMIs.

## 5. Logs to stdout, with a request id

Pods come and go, and their files go with them. Logs go to stdout as JSON, and the cluster ships them.
Every log line includes the request id the [gateway](/blog/api-gateway-facade/) adds, so one request can
be followed across services.

## Checklist

- Heap as a percentage of the container limit, with room for non-heap memory.
- Memory request = limit.
- Liveness: is the process alive. Readiness: can it serve. Never dependencies in liveness.
- `preStop` sleep + graceful shutdown + enough termination grace period.
- Config from the environment, one image everywhere.
- JSON logs to stdout with a request id.

None of this is visible on a good day. All of it is visible on the day of a busy deploy.
