+++
title = "Keeping an OAuth2 integration alive with the Laravel scheduler"
description = "Refresh token rotation, a cron job that pings an API on purpose, and the race condition hiding behind it"
date = "2017-04-09T18:40:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "oauth2-token-keepalive-laravel-scheduler"
author = "Milorad Bozic"
tags = ["php", "laravel", "oauth2", "integrations"]

+++

Our lead pipeline at work pushes every new sign-up into a marketing CRM (Infusionsoft) so the
sales and marketing teams can follow up. It talks to the CRM's REST API using OAuth2. That
worked fine for weeks and then, one Monday morning, it didn't: no new leads in the CRM since
Saturday, and every API call failed with an invalid token error.

Somebody had to log in to the CRM in a browser and authorize our app again. Then it happened
again a few weeks later. This post is about why, and the small fix.

## How the token setup works

A one-time browser flow gives us two tokens:

- an **access token**, short lived, sent with every API call;
- a **refresh token**, used to get a new access token when the old one expires.

We store both in a single row in the database. Before every API call the client checks whether
the access token is expired and if so, refreshes it:

```php
$client->setToken($stored->getToken());

if ($client->isTokenExpired()) {
    $client->refreshAccessToken();
    $stored->setToken($client->getToken())->save();
}
```

Two details make this fragile:

1. The refresh token is **single use**. Each refresh returns a *new* refresh token and the old
   one stops working. If you refresh and fail to save the result, you're locked out.
2. The integration only refreshes when there is traffic. Weekends and holidays mean fewer
   sign-ups, and if the tokens are left alone long enough they are no longer usable.

## Fix 1: a keep-alive command

The simple part: make sure there is always traffic. An Artisan command that refreshes if needed
and then makes one cheap, harmless API call:

```php
class CrmKeepAlive extends Command
{
    protected $signature = 'crm:keep-alive';
    protected $description = 'Refreshes the CRM OAuth token so it never expires unattended';

    public function handle(CrmTokenRepository $tokens, CrmClientFactory $factory)
    {
        $client = $factory->make();

        $tokens->refreshIfExpired($client);

        // Any authenticated read works; we only care that the token is used.
        $client->contacts()->findByEmail('keepalive@example.com', ['Id']);

        $this->info('CRM token OK');
    }
}
```

And in `app/Console/Kernel.php`:

```php
$schedule->command('crm:keep-alive')->hourly();
```

Hourly is overkill on purpose. It's one request, and it also works as a health check: if this
command starts failing, we know before marketing does.

## Fix 2: the race you create by fixing 1

Now there are two independent things that may refresh the token at the same moment: the
scheduled command, and a queue worker processing a lead. Because the refresh token is single
use, that's a real problem:

1. Worker and cron both read the same expired token.
2. Worker refreshes, gets tokens B, saves them.
3. Cron refreshes with token A, which is now invalid. Error.
4. Or worse, the order flips and an older response overwrites a newer one.

The fix is to make "read, refresh, save" one operation. We don't have Redis locks in this
project, but we do have MySQL, and the token is a single row, so a row lock inside a transaction
does the job:

```php
public function refreshIfExpired(CrmClient $client)
{
    DB::transaction(function () use ($client) {
        $row = CrmToken::lockForUpdate()->firstOrFail();

        $client->setToken($row->getToken());

        if ($client->isTokenExpired()) {
            $client->refreshAccessToken();
            $row->setToken($client->getToken())->save();
        }
    });
}
```

The second process waits on the lock, then reads the token the first one *just saved*, sees it
isn't expired, and moves on. Every code path that refreshes goes through this one method now.
While moving things around I also found we were saving the token twice in a row in one place,
once as raw JSON and once through the setter. Harmless, but a sign that nobody was quite sure
where the token's state lived.

Also `withoutOverlapping()` on the scheduled command, so a slow run can't stack up with the
next one:

```php
$schedule->command('crm:keep-alive')->hourly()->withoutOverlapping();
```

## Fix 3: fail loudly

Last thing: when the refresh does fail, we used to log it and continue, and every lead after that
failed quietly. Now a failed refresh sends an email to the team with a link to the re-authorize
page. It shouldn't happen anymore, but if it does, it's minutes instead of a weekend.

## Takeaways

- With rotating refresh tokens, a refresh is a write. Treat it like one: lock, refresh, save,
  commit.
- If a credential only stays valid while it's used, use it on a schedule, not only when users
  happen to show up.
- A keep-alive job doubles as the cheapest monitoring you will ever set up.
