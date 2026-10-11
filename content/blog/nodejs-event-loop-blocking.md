+++
title = "One big JSON.parse and every request waits: the Node.js event loop in practice"
description = "What blocks the event loop, how to see it happening, and three ways out: streaming, smaller units of work, and worker threads"
date = "2021-12-12T17:30:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "nodejs-event-loop-blocking"
author = "Milorad Bozic"
tags = ["nodejs", "performance", "typescript", "concurrency"]

+++

Coming to Node from Java, the concurrency model is the thing that takes longest to really feel. In a
Spring Boot service, a slow request blocks its own thread, and the other two hundred threads carry on.
In Node there's **one** thread running your JavaScript. If one request keeps it busy for 800 ms, every
other request on that process waits 800 ms. Your p99 latency goes up for everybody, and the slow
request isn't even the one that looks slow in the logs.

Map data is very good at making this happen.

## What blocks the event loop

Anything synchronous and CPU-heavy:

- `JSON.parse` / `JSON.stringify` of a big payload. A large GeoJSON FeatureCollection can take hundreds
  of milliseconds, and it's one uninterruptible call.
- Geometry work in JavaScript: simplifying, intersecting or computing areas for thousands of polygons.
- Sorting or grouping large arrays.
- Sync APIs: `fs.readFileSync`, `crypto.pbkdf2Sync`, `zlib.gzipSync`, in a request path.
- A regex with catastrophic backtracking on user input.

I/O is fine. Waiting on Postgres or an HTTP call doesn't block anything; that's what Node is good at.
It's the work *between* awaits that counts.

## Seeing it

You can't fix what you can't see, and event loop blocking looks like "everything is a bit slow
sometimes". Node has a built-in way to measure it:

```ts
import { monitorEventLoopDelay } from 'perf_hooks';

const histogram = monitorEventLoopDelay({ resolution: 20 });
histogram.enable();

setInterval(() => {
  metrics.gauge('eventloop.delay.p99.ms', histogram.percentile(99) / 1e6);
  metrics.gauge('eventloop.delay.max.ms', histogram.max / 1e6);
  histogram.reset();
}, 10_000);
```

If the p99 delay is in the hundreds of milliseconds, something is hogging the thread. To find *what*,
run with `--cpu-prof` (or attach Chrome DevTools to `--inspect`) under realistic load and look for the
wide bars in the flame graph.

## Way out 1: don't do the work

The best fix is usually to not have a huge payload in the first place. That's what [vector
tiles](/blog/vector-tiles-buildings-map/) did for the map: instead of building and serializing one giant
GeoJSON response, each request produces a small binary tile, and Postgres does the geometry work, not
the Node process.

Same idea elsewhere: paginate, select only the fields you need, let the database aggregate.

## Way out 2: stream instead of buffering

When you really have to send a lot, don't build it in memory and `JSON.stringify` it in one go. Stream it:
rows come out of the database cursor and are written to the response as they arrive. Memory stays flat,
and the work is split into many small pieces with I/O in between, so other requests get their turn.

```ts
import { pipeline } from 'stream/promises';
import QueryStream from 'pg-query-stream';

app.get('/export/buildings.ndjson', async (req, res) => {
  const client = await pool.connect();
  try {
    const rows = client.query(new QueryStream(EXPORT_SQL, [req.query.area]));
    res.setHeader('Content-Type', 'application/x-ndjson');
    await pipeline(rows, toNdjson(), res);
  } finally {
    client.release();
  }
});
```

Newline-delimited JSON (one object per line) is also much friendlier for the client than one huge array,
because it can be parsed line by line.

## Way out 3: move CPU work off the main thread

Some work really is CPU-heavy and can't be avoided: a geometry calculation, generating a report. For
that, Node has **worker threads**. The main thread stays free to handle requests, and the heavy part runs
in parallel on another core.

```ts
import Piscina from 'piscina';

const pool = new Piscina({ filename: require.resolve('./geometry-worker') });

app.post('/analysis/catchment', validate(CatchmentRequest), async (req, res) => {
  const result = await pool.run(req.body);   // runs in a worker thread
  res.json(result);
});
```

A pool library like Piscina handles the queue and the number of workers. Two things to keep in mind:
data passed to a worker is copied (structured clone), so passing a giant object can cost as much as you
saved; and a pool has a limit, so under load requests queue up for workers. That's fine, it's explicit
back-pressure instead of one request silently freezing all the others.

## Summary

- Node runs your JavaScript on one thread. CPU work in one request delays all of them.
- Measure event loop delay. It's the metric that explains "everything is slow sometimes".
- Avoid the work (smaller payloads, let the database do it), stream what's big, and move unavoidable CPU
  work to worker threads.

Different runtime, same lesson as [timeouts and bulkheads](/blog/timeouts-circuit-breakers-resilience4j/)
on the JVM: don't let one expensive thing use up the resource everyone else needs.
