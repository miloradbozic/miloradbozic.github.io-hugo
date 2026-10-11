+++
title = "Moving data off a legacy platform without a big bang"
description = "Backfill, keep in sync, verify, switch reads, switch writes. A data migration plan where every step can be rolled back"
date = "2020-06-14T19:00:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "migrating-data-off-legacy-platform"
author = "Milorad Bozic"
tags = ["distributed-systems", "migrations", "microservices", "architecture"]

+++

Moving **code** from a legacy platform to new services is the part everyone talks about. With the
[gateway in front](/blog/api-gateway-facade/), you can route one endpoint at a time to the new
service. Moving the **data** is harder, because for a while it has to live in two places, and both
places think they're right.

The "big bang" version: announce downtime for a weekend, stop everything, run a migration script,
switch, hope. It works for small systems. For a platform that is used around the clock, by people on
ships in every time zone, a weekend of downtime isn't an option, and "hope" is not a rollback plan.

This is the step-by-step approach I'd use for any data migration like this now.

## Step 0: decide who owns the data at every moment

At any point during the migration, **exactly one system is the source of truth** for a given piece of
data, and everyone knows which. Most migration bugs come from a period where both systems accept
writes and nobody decided which one wins.

## Step 1: backfill

Copy all existing data from the legacy store into the new service's store. Some rules that save pain:

- **Idempotent**: the backfill can be re-run, and running it twice gives the same result (upserts by
  the legacy id, kept as a column in the new store).
- **Resumable**: it works in batches with [keyset pagination](/blog/elasticsearch-read-model-from-replica/)
  and remembers where it stopped.
- **Throttled**: it must not slow down the legacy system, which is still serving all the traffic.
- **Transforming**: this is where the old model becomes the new model. Records that can't be
  transformed go to a reject list for a human, instead of stopping the whole run.

## Step 2: keep it in sync

While the backfill runs, and after it, the legacy system keeps changing. You need changes to flow to the
new store too. Options:

- **Dual writes from the application**: every write goes to both. Simple to start, but if one write
  succeeds and the other fails, they drift, and there's no transaction across the two stores.
- **Change events**: the legacy system publishes "this record changed" events, and a consumer applies
  them to the new store. Better, if you can change the legacy code.
- **Change data capture** from the legacy database's log. The most complete, also the most
  infrastructure.

Whichever you choose, the sync consumer must be idempotent and must handle events arriving out of
order (apply only if newer than what's stored, using a version or update timestamp from the source).

## Step 3: verify

Before trusting the new store, compare. A job that walks both stores and reports differences: missing
records, different values, records that exist only in the new store. Run it until the difference is
zero, or every remaining difference is understood.

This step is the one teams skip because "the sync works". It's also the one that finds the
timezone bug, the encoding bug and the "this field was sometimes `null` and sometimes `""`" bug.

## Step 4: switch reads (shadow first)

Now the new service starts **reading** from its own store, still with legacy as the source of truth for
writes.

A useful middle step is **shadow reads**: serve the response from legacy as before, but also read from
the new service in the background and log when the two responses differ. Real traffic, zero user
impact, and a list of differences you'd never find with test data.

When the shadow differences are gone, switch reads for real. Rollback is one route in the gateway.

## Step 5: switch writes

The last and scariest step: the new service becomes the source of truth. Writes go there first. If the
legacy system still needs the data (other legacy features read it), the sync now runs in the **other
direction**, from new to old, until nothing on the legacy side reads it anymore.

Do it per slice if you can: per customer, per tenant, per fleet. A small slice first, watch it, then the
rest.

## Step 6: delete

Remove the reverse sync, the legacy tables, the shadow code. A migration isn't finished until the old
path is gone, otherwise you maintain both forever.

## Why this is worth the effort

Every step is small, and every step except the last has a cheap rollback. The total takes much longer
than a big-bang weekend. But nobody has to be awake at 3 am hoping a script finishes, and the users
never notice that the data they're looking at moved from one system to another underneath them.
