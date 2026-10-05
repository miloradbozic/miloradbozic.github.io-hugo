+++
title = "Card payments with Redsys: trust the notification, not the redirect"
description = "What I learned wiring a Spanish bank TPV into a customer portal for paying overdue invoices"
date = "2017-01-15T19:20:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "redsys-card-payments-lessons"
author = "Milorad Bozic"
tags = ["php", "laravel", "payments", "redsys"]

+++

Over the last couple of months at [HolaLuz](https://www.holaluz.com) I worked on letting
customers pay overdue electricity invoices by card, directly from the customer area and from
our internal back-office tool. In Spain this almost always means **Redsys**, the payment gateway
behind most bank "TPV virtual" contracts.

The integration itself is not complicated, and there are decent PHP libraries for it. But a few
things only became clear once real money started moving, so I'm writing them down while I
still remember.

## How the flow works

Very short version:

1. Your backend builds a set of *merchant parameters* (amount, order number, currency,
   terminal, the URLs Redsys should call back), Base64-encodes them as JSON and signs them
   with a key derived from your secret and the order number (3DES + HMAC-SHA256).
2. The browser POSTs a form with `Ds_MerchantParameters`, `Ds_Signature` and
   `Ds_SignatureVersion` to Redsys.
3. The customer types the card details on the bank's page.
4. Redsys does two things, independently:
   - redirects the **browser** to your `URL_OK` or `URL_KO`, and
   - makes a **server-to-server** POST to your notification URL (`urlMerchant`) with
     the signed result.

The important word is *independently*.

## Lesson 1: the redirect is UX, the notification is the truth

My first version marked the payment as done on the OK redirect. It looked fine in testing.
In production it isn't, because:

- the customer can close the tab right after paying, so you never see the redirect;
- anyone can open `/tpv/ok` in a browser;
- the notification can arrive *before* or *after* the redirect.

So now the OK page only says "thanks, we're processing your payment". The only thing that
changes the state of a payment is the notification, and only after the signature is verified:

```php
public function notification(Request $request)
{
    $params    = $request->get('Ds_MerchantParameters');
    $signature = $request->get('Ds_Signature');

    $data  = json_decode(base64_decode(strtr($params, '-_', '+/')), true);
    $order = $data['Ds_Order'];

    $expected = $this->redsys->createMerchantSignatureNotif($this->key, $params);
    if (!hash_equals($expected, $signature)) {
        Log::warning('TPV notification with invalid signature', ['order' => $order]);
        return response('', 400);
    }

    $payment = $this->payments->findByOrder($order);
    $payment->markFromResponse((int) $data['Ds_Response'], $params, $signature);

    return response('', 200);
}
```

`Ds_Response` between `0000` and `0099` means authorized; everything else is some kind of
denial. Don't forget that the comparison is numeric, the value comes as a zero-padded string.

## Lesson 2: store the signed request and the signed response

When a customer calls support saying "I paid, but the portal says I still owe money", you want
to answer that from data, not from guessing. We added columns to the payments table for the
exact `params`, `signature` and `version` we sent, and the exact ones we received back:

```php
Schema::table('payments', function (Blueprint $table) {
    $table->string('request_version')->nullable();
    $table->text('request_params')->nullable();
    $table->string('request_signature')->nullable();
    $table->string('response_code')->nullable();
    $table->string('response_version')->nullable();
    $table->text('response_params')->nullable();
    $table->string('response_signature')->nullable();
});
```

It is a bit of duplication, but it already paid off twice. Base64 JSON is cheap to keep and
trivial to decode when you need it.

## Lesson 3: one invoice, many attempts

A customer can try to pay the same invoice three times (wrong CVV, card blocked, then success).
Redsys does not allow reusing an order number, so every attempt needs a new one, while the
payment still belongs to the same invoice reference.

My first approach was `rand(1000, 99999999)` for the order number, which "works" until it
doesn't. Redsys wants 4 to 12 characters with the first 4 being digits, and two attempts
colliding is a real (if unlikely) problem. Something derived from the payment id plus an attempt
counter is boring and safe.

The other side of this: **check if the invoice is already paid before you build the form.** We
ask the ERP for the outstanding amount first and short-circuit with "already paid" instead of
letting someone pay twice.

## Lesson 4: don't mock the ERP inside the service class

Our invoices and payments live in the ERP, which we talk to via SOAP web services. While building
the payment screen the ERP test environment was not always available, so I did the quick thing:

```php
public function getAmount($reference)
{
    return 44; // TODO remove after testing

    // ... real SOAP call below
}
```

You can guess how comfortable I was deploying that. The fix was already there in the code: the
service implements an interface and Laravel's container resolves it. So the fake belongs in its
own class, bound only where we want it:

```php
// AppServiceProvider::register()
if (config('services.erp.fake')) {
    $this->app->bind(PaymentGatewayInterface::class, FakeErpPayments::class);
} else {
    $this->app->bind(PaymentGatewayInterface::class, ErpPayments::class);
}
```

The fake returns predictable data, tests use it, and the real class never contains a stray
`return 44;` again.

## Summary

- The browser redirect is for the customer; the signed server notification is for your database.
- Verify the signature with `hash_equals`, always.
- Persist what you sent and what you received.
- New order number per attempt, same invoice reference.
- Fakes go behind interfaces, not above the real code.

Next time I'll probably write about the Laravel 5.3 upgrade we are planning, which I'm sure will
give me something to complain about.
