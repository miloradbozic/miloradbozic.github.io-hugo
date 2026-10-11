+++
title = "Our first step out of the monolith was a read model"
description = "Feeding Elasticsearch from a MySQL read replica: pagination that doesn't slow down, reindexing without downtime, and choosing how stale is OK"
date = "2017-08-20T19:30:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "elasticsearch-read-model-from-replica"
author = "Milorad Bozic"
tags = ["distributed-systems", "elasticsearch", "mysql", "architecture"]

+++

When people talk about breaking up a monolith, the first picture is usually "take the payments
code, put it in its own service with its own database". We haven't done that yet. What we did first
was less dramatic and, I think, the right first step: we took one **read path** out of the main
database.

## The problem

Our back-office tool lets people search customers and contracts by name, address, ID document,
supply point code, partial phone number and a few other things, in any combination. In MySQL that
turned into `LIKE '%...%'` across joined tables. Some searches took seconds, and since they ran on
the primary they competed with the customer area and with sign-ups.

Full-text and "search across everything" is what Elasticsearch is good at, so we index customers
and contracts there. The interesting part is not Elasticsearch itself. It's that we now have **two
copies of the data**, and every question becomes "how do they stay in sync, and how wrong is it
allowed to be?"

## Read from a replica, not the primary

The indexer is an Artisan command that reads from a MySQL **read replica** and writes documents
to Elasticsearch. Indexing everything means scanning big tables, and the primary should never pay
for that.

The price is replica lag. Usually it's under a second, under load it can be more. For a back-office
search that's fine: if a contract signed ten seconds ago doesn't show up yet, nobody is hurt. That
was an explicit decision, written down, not something we found out later. For the customer seeing
their own data in the customer area it would *not* be fine, and that still reads from the primary.

## Pagination that doesn't get slower

The first version of the indexer paged with offset:

```php
$batch = $this->contracts->skip($skip)->take(5000)->get();
```

That is `LIMIT 5000 OFFSET n`, and MySQL has to walk past all `n` rows to get to your page. The
first batches were fast, the last ones took ages, and the full run got slower every month as the
tables grew. Classic.

Keyset pagination fixes it. Remember the last id and ask for what comes after it:

```php
$lastId = 0;

do {
    $batch = Contract::where('id', '>', $lastId)
        ->orderBy('id')
        ->limit(5000)
        ->get();

    if ($batch->isEmpty()) {
        break;
    }

    $this->bulkIndex($batch);
    $lastId = $batch->last()->id;
} while (true);
```

Every batch is now an index range scan, so batch 1 and batch 200 cost the same. Also: send each
batch with the `_bulk` API, not one request per document.

## Reindexing without downtime: aliases

Mappings change. Sometimes you want a new analyzer for names with accents, sometimes a new field.
Changing a mapping usually means building the index again, and you don't want search to be empty
or half-full while that happens.

So the application never talks to a real index. It talks to an **alias**:

1. Create a new index `contracts_v7` with the new mapping.
2. Fill it completely with the indexer.
3. Atomically move the alias `contracts` from `contracts_v6` to `contracts_v7`.
4. Delete `contracts_v6` when you're happy.

```json
POST /_aliases
{
  "actions": [
    { "remove": { "index": "contracts_v6", "alias": "contracts" } },
    { "add":    { "index": "contracts_v7", "alias": "contracts" } }
  ]
}
```

Search keeps working on the old index the whole time, and the switch is one atomic call. Rollback
is the same call in the other direction.

## Keeping it fresh between full runs

A full reindex every hour is our safety net. On top of that, the code paths that change a customer
or contract also push the changed document to the index. If that push fails, nothing breaks: the
next hourly run fixes it. So the event-style update gives us speed, and the periodic full sync gives
us correctness. I didn't expect to like having both, but now I'd be nervous having only one of them.

## Why I call this a first step

Nothing here is a microservice. But a few things changed in how we work:

- The search side has its own data model, shaped for reading, not a copy of our tables.
- We had to say out loud how stale data may be, per use case.
- We had to design for one side being down or behind, without the other side breaking.

Those are exactly the questions we'll have to answer when we split out real services. Better to
learn them on search, where being ten seconds behind is fine, than on billing, where it isn't.
