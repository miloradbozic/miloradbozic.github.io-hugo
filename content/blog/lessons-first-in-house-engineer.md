+++
title = "What I learned as the first in-house engineer"
description = "Almost three years of taking a codebase back from an agency, growing a team around it, and slowly turning a monolith into something calmer"
date = "2017-12-17T17:00:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "lessons-first-in-house-engineer"
author = "Milorad Bozic"
tags = ["career", "architecture", "teams", "distributed-systems"]

+++

At the end of this month I'm leaving HolaLuz. I joined when the company was small and its software
was built by an external agency. I was the first engineer hired to own it in-house. When I leave,
there's a team of developers, a CI pipeline, infrastructure as code, and a system that fails in
smaller and more boring ways than it used to.

This is not a goodbye post, it's notes for myself on what I would tell someone starting in the
same position.

## 1. Move the code before you change it

The first months were not about features. They were about making the codebase *ours*: one
repository that we control, a process to get changes into production that doesn't depend on someone
outside the company, and an inventory of what runs where. We moved repositories more than once
(Assembla, then Bitbucket, then GitHub), and every move was cheap because history came with it.

You can't improve something you can't deploy with confidence. Ownership first.

## 2. CI before refactoring

Before touching the big parts, we added a build that runs on every change: lint, PHPUnit, and
static analysis (phpcs, phpmd, copy-paste detection). It was an Ant build, nothing fancy. The
static analysis was noisy at the start, and we did not fix everything. What we did was stop the
numbers from getting worse.

Together with a git-flow style process (feature branches, release branches, hotfix branches) it
gave us something we didn't have before: a version number for what's in production, and a way to
say "this broke in 1.43, here's the diff".

## 3. The external system will be down. Design for it

A big part of our work is talking to systems we don't control: the ERP, the bank's payment gateway,
the CRM, the email provider. In the beginning, a lot of that happened inside the user's request. If
the ERP was slow, sign-up was slow. If it was down, sign-up failed.

The fix, every time, was the same pattern:

- accept the user's action and store it locally,
- put a job on a queue to talk to the external system,
- retry with backoff, and alert a human when retries run out.

Sending a new contract to the ERP is a queued job now. The customer gets "thanks, you're signed up"
in milliseconds, whether the ERP is up or not. It's eventually consistent, and that turned out to be
completely fine for the business once we explained it in those terms: "it will be in the ERP within
minutes, and if it isn't, we'll know."

## 4. Make every job safe to run twice

Once things run on queues, things run twice. Messages get redelivered, workers die halfway,
someone clicks "retry" in a panic. I wrote about this with the [invoice
fan-out](/blog/invoice-fan-out-sqs/) and the [OAuth token
keep-alive](/blog/oauth2-token-keepalive-laravel-scheduler/), and it's the single most useful habit
I picked up here. Upserts instead of inserts, natural keys instead of generated ones, a cheap lock
in front of expensive work.

## 5. Split reads before you split writes

We didn't do a big "rewrite into microservices". We took things out one at a time, starting with
the safest: [search as a read model](/blog/elasticsearch-read-model-from-replica/), reports, the
queue workers. Each step taught us something about running more than one moving part, while the
risk stayed small. If I started again, I would do it in the same order.

## 6. Ops is part of the job

For a long time I was the person who wrote the feature *and* the person who got the alert when it
broke. It's tiring, but it made me write different code: more logging at the boundaries, timeouts
on every outgoing call, commands that can be re-run safely. [Immutable
servers](/blog/immutable-servers-packer-ansible-terraform/) came from the same place. I didn't
want to be the only person who knew what was on web-3.

## 7. The team is the system

The best technical decision I made here was hiring people who are better than me at things I'm
weak at, and then writing things down so I wasn't a bottleneck. Code review, a README per service,
runbooks for the jobs that fail at night. The codebase grew from one in-house engineer to many,
and the parts that aged best are the ones where several people felt they owned them.

## What's next

A new job in the new year, and I expect a lot more of what the last year was slowly turning into:
services, queues, and the question "what happens when this other thing is down?" More on that here.

Gracias, Barcelona.
