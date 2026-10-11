+++
title = "Mentoring two junior developers: what actually helped"
description = "Notes from a year of mentoring: small real tasks, reviews that teach, pairing, and letting people get stuck (a little)"
date = "2021-09-19T18:00:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "mentoring-junior-developers"
author = "Milorad Bozic"
tags = ["mentoring", "teams", "code-review", "career"]

+++

For most of this year I've been mentoring two junior developers on our team. I had done bits of
this before, a code review here, an explanation there, but never as an actual responsibility for
someone's growth. Here's what I think worked, and what I'd do differently.

## Real work, sized right

The temptation is to give juniors "safe" work: small bugs, copy changes, tests nobody needs. It's safe,
and it teaches almost nothing, because there's no real decision in it.

What worked better: **real features, cut small**. A new filter on the map, end to end: the query,
the API endpoint, the [validation](/blog/typescript-runtime-validation-zod/), the UI. Small enough to
finish in a few days, big enough to touch every layer. They learn how the system fits together, and
they ship something people use, which matters more for motivation than any amount of praise.

## Pairing, but with them driving

When we pair, they have the keyboard. If I drive, they watch me be fast and learn mostly that I'm fast.
If they drive, I see exactly where they hesitate, and that's where the useful conversation is.

It's slower. It's also the only way I've found to learn *how* someone thinks about a problem, not just
whether they got to the answer.

## Code review that teaches

A review comment like "change this to a map" fixes the code. A comment like "this loops over all
buildings for every search result, so it's O(n·m). A `Map` keyed by id makes the lookup constant; worth it
here because n can be thousands" fixes the code *and* the next ten pieces of code.

A few rules I try to follow:

- **Explain why**, at least the first time a type of comment comes up.
- **Label what's blocking and what's taste.** "nit:" for preferences, so they know which comments
  they're free to ignore. Otherwise every comment looks like an order.
- **Ask instead of tell** when I'm not sure: "what happens here if the request times out?" They often
  find the problem themselves, and remember it much better.
- **Say what's good.** Not as a trick to soften the rest, but because they really don't know which of
  their choices were good ones.

## Let them get stuck, a little

When someone is stuck, it's very easy to just give the answer. Sometimes that's right. But being stuck
for a while, then finding it, is how you learn to debug.

The rule we settled on: try alone for a fixed time (an hour, roughly), and write down what you tried.
After that, ask, no guilt. The written list is useful on its own: half the time, writing down "what I
tried" shows the answer. The other half, it tells me exactly where to start.

## Teach the system, not only the code

Juniors usually learn syntax and frameworks quickly. What takes longer, and what nobody teaches, is the
stuff around the code:

- how a request gets from the browser to the database and back,
- where the logs are and how to read them,
- what happens on deploy,
- why we [cache tiles](/blog/vector-tiles-buildings-map/) but not search results.

A one-hour session drawing the whole system on a whiteboard (well, a shared screen) was more useful than
any single code review.

## What I'd do differently

- **Set goals explicitly** at the start. "Get better" is not a goal. "Can take a feature from ticket to
  production without help by the end of the quarter" is.
- **Check in regularly, outside of code.** Short weekly one-to-ones, not only conversations when
  something is broken.
- **Hand over ownership earlier.** Once one of them knew a part of the codebase well, I should have made
  them the person others ask about it. Being the expert on something, even something small, does a lot.

## What I got out of it

Explaining things you "just know" forces you to find out if you actually understand them. More than once
I started explaining why we do something, and halfway through realised we shouldn't be doing it.

And it's genuinely satisfying to see someone review *your* pull request a few months later and find a real
bug in it.
