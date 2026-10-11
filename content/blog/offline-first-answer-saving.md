+++
title = "Never lose an answer: offline-first answer saving for exams at sea"
description = "A client-side outbox, idempotent writes with client-generated ids, and letting the server keep the clock"
date = "2018-12-16T19:00:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "offline-first-answer-saving"
author = "Milorad Bozic"
tags = ["distributed-systems", "offline-first", "javascript", "idempotency"]

+++

Back in May I wrote about [what satellite internet on a ship means](/blog/exams-over-satellite-internet/)
for an online exam. The rule I cared about most was: **never lose an answer**. The connection can go
away at any point, for minutes, and the person taking the test should be able to keep going.

This is how we're approaching it. Not finished, but the shape is clear.

## Step 1: load the whole test up front

When the attempt starts, the client fetches everything it needs in one go: all items, the media they
use, the navigation rules. From then on, showing the next question is a local operation. The network
is only needed to send answers, and that can happen later.

This sounds obvious, but it changes the API. Instead of "give me the next question" (one round trip
per question, at ~600 ms each), it's "give me the test" once.

## Step 2: answers go to an outbox, not to the server

When the user answers, the UI does **not** call the API directly. It writes the answer to a local
outbox, persisted in the browser so it survives a reload or a crashed tab, and immediately moves on.
A separate sender process drains the outbox whenever there's a connection.

```js
function saveAnswer(attemptId, itemId, response) {
    var entry = {
        id: uuid(),              // generated on the client
        attemptId: attemptId,
        itemId: itemId,
        response: response,
        answeredAt: Date.now(),  // when the user answered, by the device clock
        seq: nextSeq(attemptId)  // order of answers within this attempt
    };
    outbox.put(entry);           // IndexedDB / localStorage
    sender.wake();
}
```

The UI's only job is to make writing to the outbox never fail. Everything network-related is the
sender's problem.

## Step 3: make sending safe to repeat

The sender takes entries from the outbox and sends them. If the request times out, it doesn't know if
the server got it. So it sends again, later. That means the server **will** receive some answers twice.

The fix is the client-generated `id`. The server stores answers with that id as a unique key:

```
PUT /attempts/{attemptId}/answers/{answerId}
```

- First time: store it, return `201`.
- Same id again: it's already there, return `200` with the same result.

`PUT` with an id chosen by the client is idempotent by design. The client can retry as much as it
wants and the result is the same. An entry is removed from the outbox only after the server has
confirmed it.

## Step 4: order and "last answer wins"

A user can change their answer to question 5 three times while offline. When the link comes back,
those three requests may arrive in any order, especially if retries are involved. Without care, the
server might keep the second answer instead of the third.

That's what `seq` is for. Per attempt, the client numbers its answers. For each item, the server keeps
the response with the highest `seq` it has seen, and ignores older ones that arrive late. It's a small
version of what databases call last-writer-wins, with an explicit version number instead of timestamps,
because device clocks can't be trusted to order things.

## Step 5: the server keeps the clock

Speaking of clocks: assessments have time limits. If the client decides when time is up, anyone can
change the device clock and get more time. If the server decides based on when answers *arrive*,
someone who answered on time but was offline is punished for the weather.

Our compromise:

- The server records when the attempt started, by its own clock, when the start request arrived.
- The client sends `answeredAt` with every answer. The server uses it, but checks it's plausible:
  not before the attempt started, not in the future, not after the time limit plus a tolerance.
- Answers that arrive late but were given on time count. Answers given after the limit don't.

This is where JQTI+ helps: every operation takes an explicit timestamp, so we can replay answers into
the test session with the time they were *given*, not the time they arrived.

## Step 6: finishing while offline

"Finish test" is just another entry in the outbox, after all the answers. The UI shows "Your answers
are saved and will be submitted when the connection is available". When the server receives the
finish, it knows (by `seq`) whether it has every answer before it. If something is still missing, it
waits for it before scoring.

## The general lesson

None of this is specific to ships. It's the standard toolbox for any system where messages can be
delayed, duplicated or reordered: an outbox, idempotent writes with ids chosen by the sender,
sequence numbers instead of clocks for ordering, and one side that has the final word.

The satellite just makes it impossible to pretend those problems don't exist.
