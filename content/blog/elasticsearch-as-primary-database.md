+++
title = "Elasticsearch as a primary database: what I wish someone had told me"
description = "No transactions, near-real-time reads, versions instead of locks, and mappings you can't change. Living with a search engine as the source of truth"
date = "2019-02-17T19:40:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "elasticsearch-as-primary-database"
author = "Milorad Bozic"
tags = ["distributed-systems", "elasticsearch", "databases", "consistency"]

+++

Two years ago I [used Elasticsearch as a read model](/blog/elasticsearch-read-model-from-replica/):
MySQL was the truth, Elasticsearch was a copy built for searching, and if the copy broke you rebuilt
it. On the platform I work on now, Elasticsearch **is** the truth. Users, content, results: the
primary store for a lot of the data is an Elasticsearch cluster.

It wasn't my decision, and I'm not going to argue it was right or wrong. It works. But it's a very
different database from the ones most of us learned on, and the problems come exactly from treating
it like one of those. Here's my list.

## 1. "Saved" doesn't mean "visible"

Elasticsearch is *near* real time. A document you just indexed is durable (it's in the translog) but
it doesn't show up in **searches** until the next refresh, by default about a second later.

The classic bug: user saves something, the UI redirects to a list, the list is a search, the new item
isn't there. User saves again. Now there are two.

What helps:

- **Read by id when you can.** A `GET /index/_doc/{id}` is real time, it doesn't wait for a refresh.
  After a write, show the thing you just wrote by id, not via a search.
- **`refresh=wait_for` on writes that a user will immediately search for.** The request returns only
  after the change is searchable. Slower, so not for bulk jobs.
- Never `refresh=true` on every write. It works in tests and kills the cluster under load.

## 2. There are no transactions

You can't update a user and their results "together". Each document write is atomic on its own,
and that's all you get.

So you design for it:

- Put things that must change together **in the same document**. Denormalize more than you're
  comfortable with.
- When you can't, make the multi-step operation **safe to re-run** from any point, and write the steps
  in an order where a half-finished state is harmless. (Same idea as the [queue jobs at my last
  job](/blog/invoice-fan-out-sqs/): the unit of failure has to be something you can retry.)

## 3. Versions instead of locks

Two requests read the same document, both change it, both write it back. The second one silently
overwrites the first. In SQL you'd reach for a transaction or `SELECT ... FOR UPDATE`. Here you use
**optimistic concurrency**: every document has a version, and you can say "only write this if the
version is still the one I read".

```
GET /attempts/_doc/42           -> { "_version": 7, ... }

PUT /attempts/_doc/42?version=7
{ ...changed document... }
```

If someone else wrote in between, you get a `409 Conflict`. Then you read again, apply your change
again, and retry. We wrapped this in a small helper so nobody does a blind read-modify-write by
accident. (Elasticsearch is moving this to sequence numbers, `if_seq_no` and `if_primary_term`, same
idea.)

## 4. The mapping is (almost) forever

You can add fields to a mapping. You can't change the type of an existing field. If `score` was
mapped as `keyword` by dynamic mapping because the first document happened to contain `"85"`, it's a
`keyword` until you reindex everything.

- **Turn off dynamic mapping** for the important indices (`"dynamic": "strict"`). A typo in a field
  name should be an error, not a new field.
- **Always go through an alias**, so that reindexing into a new index and switching over is possible
  without downtime. When Elasticsearch is the primary store, reindex is your migration tool, the same
  way `ALTER TABLE` would be.

## 5. No joins, so model for the reads

There are no joins worth using. Every screen should be answerable from one index, ideally one query.
This pushes you to model data around how it's **read**, not how it's related. For a primary store
that's a real trade-off: writes get more complicated (update the copies), reads get simple and fast.

## 6. Backups are snapshots, and you should test restoring them

If Elasticsearch is your primary store, losing the cluster means losing the data, not "rebuild from
MySQL". Snapshots to S3 on a schedule, and, the part people skip, actually restoring one into a test
cluster from time to time. A backup you've never restored is a hope, not a backup.

## 7. Watch the cluster like a database

Shard count, heap usage, rejected thread pool tasks, and cluster health going yellow. With a search
index you can get away with not looking. With the primary store you can't.

## Would I choose it?

For data that is mostly read, searched and aggregated, with few cross-document invariants, it's
actually quite pleasant. For anything with money or strict invariants, I'd still want a relational
database underneath, with Elasticsearch as the copy.

The main lesson is not about Elasticsearch, though. Every database makes promises about consistency,
and they're all different. Find out what yours actually promises before you write code that assumes
the ones you're used to.
