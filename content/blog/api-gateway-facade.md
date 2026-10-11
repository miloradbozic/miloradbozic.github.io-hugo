+++
title = "One door for every client: an API gateway as a facade"
description = "Why our web app, the LMS integrations and the ship clients all talk to one entry point, and what belongs there (and what doesn't)"
date = "2019-04-28T18:20:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "api-gateway-facade"
author = "Milorad Bozic"
tags = ["distributed-systems", "microservices", "api-gateway", "architecture", "java"]

+++

As we split the old platform into Spring Boot services, we got a new problem very quickly: there
are now many services, and many kinds of clients. The web app, the assessment UI, LMS integrations,
the clients used on board ships. If every client talks to every service directly, every client has
to know where every service lives, how it authenticates, and how its API looks this month.

So all clients go through **one entry point**: an API gateway that acts as a facade over the
services behind it.

## What a facade means here

The facade pattern, from the old Gang of Four book: give a simple interface to a complicated
subsystem. That's exactly the job:

- The client sees **one host** and one consistent API.
- Behind it, requests are routed to the right service.
- Services can be split, merged, moved or rewritten, and clients don't notice as long as the facade
  keeps its contract.

The last point is the important one during a migration. While a feature still lives in the old
monolith, the gateway routes it there. When it moves to a new service, we change one route. The
client keeps calling the same URL. That's how we can migrate piece by piece without a big-bang switch.

## What we put in the gateway

**Routing.** `/assessments/**` goes to the assessment service, `/content/**` to content, and so on.
Some routes still point at the legacy platform.

**Authentication at the edge.** Every request must carry a valid token from
[Keycloak](/blog/exam-state-singleton-stateless-services/). The gateway checks it once: signature,
expiry, audience. Requests without a valid token never reach a service. Services still check roles for
their own operations, but they don't each have to reimplement token handling for external traffic.

**Aggregation for slow clients.** This is where the ships come in. A screen that needs data from three
services would need three round trips from the client. Over [satellite
internet](/blog/exams-over-satellite-internet/) at ~600 ms each, that hurts. So for a few important
screens the gateway has an endpoint that calls the services *inside the data center*, where calls take
milliseconds, and returns one combined response. One round trip over the satellite instead of three.

**Cross-cutting basics.** A request id added to every incoming request and passed on to every service
call, so a request can be followed through the logs of all services. CORS in one place. Rate limiting.

## What we keep out of it

This is where gateways go wrong. They're the one place every request passes through, so it's tempting
to put "just a little" logic there. Then a bit more. Then the gateway is a new monolith that every team
has to change for every feature.

Our rules:

- **No business logic.** The gateway doesn't know what a passing score is. If a rule is about the
  domain, it lives in the service that owns that domain.
- **Aggregation only, no decisions.** An aggregate endpoint can combine responses. It can't decide
  things based on them.
- **No database.** If the gateway needs to remember something, that's a sign the thing belongs in a
  service.

## The costs

- **It's a single point of failure** by design. So it runs as several instances, it's stateless, and it
  has to be boring and well tested.
- **One more hop.** In the data center that's negligible. Over the satellite, the aggregation more than
  pays it back.
- **Timeouts become your problem.** If one service is slow, the gateway must not wait forever and
  hold the connection. Every route has a timeout, and an aggregate endpoint returns partial data
  rather than nothing when one service is down, if the screen can live with that.

## Why I like it

A gateway as a facade is not exciting technology. But during a migration from a monolith to services,
it's the thing that lets you move the inside without breaking the outside. And for clients on a bad
network it's the natural place to turn many small calls into one.
