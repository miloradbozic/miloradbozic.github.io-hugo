+++
title = "Exams over satellite internet: designing for the worst network you can imagine"
description = "First notes from a new job: online assessments for seafarers, taken on board ships with slow, expensive and unreliable connections"
date = "2018-05-20T20:00:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "exams-over-satellite-internet"
author = "Milorad Bozic"
tags = ["distributed-systems", "offline-first", "architecture", "networking"]

+++

New year, new job. I'm now at [Videotel](https://www.videotel.com), working on the platform that
the maritime industry uses for training and assessment of seafarers. Crew members take tests when
they apply for a job, and they take training and assessments **on board**, while the ship is at sea.

The second part is what makes this interesting. Most of what I knew about web apps assumes the
network is fast and basically always there. On a ship it's neither.

## What the network looks like at sea

The ship talks to the rest of the world over satellite. Compared to an office connection:

- **Latency is huge.** A geostationary satellite is about 36,000 km up. Signal goes up and down
  for the request and again for the response, so you're looking at roughly 600 ms of round trip
  before your server has done any work. A page that needs 20 sequential requests is now a
  12-second page.
- **Bandwidth is small and shared.** The whole crew shares one link, and the ship's own operational
  traffic has priority over someone's training module.
- **It's expensive.** On some vessels data is still paid per megabyte. Shipping a 2 MB JavaScript
  bundle on every visit is not only slow, it costs someone money.
- **It drops.** Weather, the ship's position, the antenna losing the satellite during a turn. A
  connection that is gone for minutes is normal, not an incident.

And in the middle of that, someone is taking a 40-minute assessment that matters for their
certification.

## What this means for the design

We are starting to plan a new version of the assessment platform, and the network shapes almost
every decision. My working list so far:

**1. Load once, then work locally.** When the assessment starts, the client should get everything
it needs for the whole test in as few requests as possible: questions, media, the rules. After that,
moving to the next question must not need the network at all.

**2. Count round trips, not milliseconds.** At 600 ms per round trip, chatty APIs are the enemy.
"Get test, then get item 1, then get item 1's image, then post answer 1, then get item 2..." is
the natural REST design, and it's exactly wrong here. Fewer, bigger requests.

**3. Never lose an answer.** If the connection drops after question 17, the 17 answers must still be
there, on the device, and must reach the server when the link is back. The user should not even
need to notice.

**4. Every write must be safe to repeat.** If the client sends an answer and the connection drops
before the response arrives, it doesn't know if the server got it. It will send it again. The
server must accept the same answer twice without counting it twice. (I [learned this one on
queues](/blog/invoice-fan-out-sqs/) last year, and it turns out a flaky network is just another
way to get at-least-once delivery.)

**5. The server decides what counts.** Offline-friendly doesn't mean the client is trusted. Scoring,
time limits and "is this attempt still open" stay on the server. The client collects answers; the
server judges them when they arrive.

**6. Measure on a bad network, not in the office.** Chrome's network throttling with high latency
and packet loss is now part of how we test. It's humbling.

## Why I like this problem

On a normal web app you can ignore most of this and get away with it. Here you can't. Every
distributed systems problem you can read about, partial failure, retries, duplicates, "did my
request arrive?", shows up between one browser and one server, just because there's a satellite
in the middle.

I'll write more as we build it.
