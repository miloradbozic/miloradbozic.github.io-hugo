+++
title = "From a day to an hour: fanning out invoice work over SQS"
description = "Turning a sequential batch job into many small idempotent jobs, and what at-least-once delivery means in practice"
date = "2017-06-11T20:10:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "invoice-fan-out-sqs"
author = "Milorad Bozic"
tags = ["distributed-systems", "aws", "sqs", "redis", "laravel"]

+++

Every billing cycle we have to process invoices for all of our customers: pull them from the ERP,
store them, make them visible in the customer area, and keep the related contracts in sync. For a
long time this was one big job that went through the invoices one by one. It took about a day.
The worst part was not the duration, it was what happened when it failed at 70%: figure out where
it stopped, fix the data, start again, hope.

Now the same work finishes in one or two hours, and a failure in the middle is a non-event. The
code change was smaller than I expected. The change in how we think about the job was bigger.

## One big loop → many small jobs

The old shape was:

```php
foreach ($invoices as $invoice) {
    $this->syncContractsFor($invoice);   // SOAP calls to the ERP
    $this->syncInvoice($invoice);        // more SOAP calls
}
```

Almost all of the time is spent waiting on the ERP. The CPU does nothing. That's the definition
of work that should run in parallel.

The new shape has two parts. A **dispatcher** walks the invoices and puts one message per invoice
on an SQS queue:

```php
$this->invoices->toProcess()->chunk(10000, function ($invoices) {
    foreach ($invoices as $invoice) {
        dispatch(
            (new SyncInvoice($invoice->cycle, $invoice->number, $invoice->contracts))
                ->onConnection('sqs')
                ->onQueue(config('queues.invoices'))
        );
    }
});
```

And a pool of **workers** (plain `php artisan queue:work` processes on a few instances) each pick
messages and do the work for exactly one invoice. Want it faster? Add workers, up to the point
where the ERP starts to complain. That ERP limit, not our code, is now the real bottleneck, and
it's a much better problem to have.

`chunk()` matters for the dispatcher: loading a few hundred thousand Eloquent models at once is
a great way to meet the PHP memory limit.

## At-least-once means "sometimes twice"

This is the part that is easy to read in the SQS docs and easy to forget in code. A standard SQS
queue guarantees **at-least-once** delivery. The same message can be delivered to two workers. And
if a worker takes longer than the queue's *visibility timeout*, SQS assumes it died and gives the
message to someone else, while the first worker is still happily working.

So every job must be safe to run twice. Two ways to get there, and we use both.

**1. Make the work itself idempotent.** Syncing an invoice is an upsert by invoice number, not an
insert. Running it twice leaves the same row. This is the real protection.

**2. Cheap dedupe in front of it.** Running the same invoice twice in parallel is still wasted ERP
calls, and two concurrent upserts of the same rows can deadlock in MySQL. So before doing anything,
the job claims the invoice in Redis:

```php
public function handle(InvoiceSync $sync)
{
    $key = 'invoice:' . $this->cycle . str_pad($this->number, 8, '0', STR_PAD_LEFT);

    // SET key 1 NX EX 7200: only succeeds if nobody else holds it
    if (! Redis::set($key, 1, 'NX', 'EX', 7200)) {
        return; // someone else has it, or did it recently
    }

    try {
        $sync->contractsFor($this->contracts);
        $sync->invoice($this->cycle, $this->number);
    } catch (\Exception $e) {
        Redis::del($key);   // let a retry try again
        throw $e;           // and let the queue retry it
    }
}
```

`SET ... NX EX` is atomic, so two workers can't both win. If the job fails, we release the key and
rethrow, so the queue's normal retry picks it up. If the worker dies hard (OOM, instance gone), the
key expires on its own after two hours.

## Things that bit us

- **Visibility timeout shorter than the slowest job.** Some invoices have dozens of contracts and
  take minutes. With the default timeout they were delivered again while still running. Set the
  visibility timeout above your worst case, not your average.
- **The lock TTL is also a "don't redo" window.** After a *successful* run the key stays for two
  hours, so re-running the sync for the same invoice inside that window silently does nothing. For
  a nightly batch that's what we want. For the "re-sync this one customer now" button in the
  back-office it wasn't, and that one now deletes the key first. Know which semantics you picked.
- **Poison messages.** An invoice with broken data in the ERP fails every time. Without a limit it
  goes round forever and burns ERP calls. A redrive policy to a dead-letter queue after a few
  attempts, plus a command that lists what's in the DLQ, turned that into a short daily review.
- **Progress is no longer a log line.** With one loop, "invoice 51234 of 98000" told you where you
  were. With a queue you look at the queue depth (`ApproximateNumberOfMessages`) and the DLQ
  instead. We put both on a dashboard.

## The real win

Duration went from about a day to an hour or two, which is nice. But the actual improvement is
that the unit of failure went from "the whole batch" to "one invoice". A failure no longer means
someone spends the morning restarting a job. It means one message in a dead-letter queue, with
the invoice number on it.

That idea, small independent units of work that are safe to repeat, is something I'm starting to
see everywhere now.
