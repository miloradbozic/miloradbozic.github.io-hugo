+++
title = "Upgrading to Laravel 5.3: where did lists() go?"
description = "A small shim, a grep and a plan for removing a renamed method from a large codebase"
date = "2017-02-26T21:05:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "laravel-53-upgrade-lists-pluck"
author = "Milorad Bozic"
tags = ["php", "laravel", "upgrade"]

+++

As promised in the last post, here are some notes from the Laravel 5.3 upgrade we did on the
customer portal at work. The codebase is almost two years old, has grown three separate
"apps" (customer area, back-office, partner tools) on subdomains, and was started on Laravel 5.0.
So not a huge app, but big enough that "just run the tests" is not the whole story.

Most of the upgrade guide went smoothly. One thing did not.

## The rename

In 5.2 `lists()` was deprecated in favor of `pluck()`. In 5.3 it is gone. That applies to
collections, the query builder and the Eloquent builder. Code like this:

```php
$options = $tariffs->lists('name', 'id');
```

now fails with `BadMethodCallException: Method lists does not exist.` The good news is that
it fails loudly. The bad news is that you only find out where it happens when that line runs,
and a lot of ours was in admin screens that nobody opens on a Tuesday.

## Step 1: a shim, so we can ship

We didn't want to block the upgrade on touching dozens of files in parts of the app we don't know
well. Laravel collections are *macroable*, so we can put the old name back as an alias:

```php
namespace App\Providers;

use Illuminate\Support\ServiceProvider;
use Illuminate\Database\Eloquent\Collection;

class MacroServiceProvider extends ServiceProvider
{
    public function boot()
    {
        // Temporary: alias for pluck(), removed in Laravel 5.3.
        // Delete when nothing calls ->lists() anymore.
        Collection::macro('lists', function ($value, $key = null) {
            return $this->pluck($value, $key);
        });
    }
}
```

Register it in `config/app.php` and the old calls on Eloquent collections work again.

## The catch: which Collection?

This is what bit us a day later. There are two collection classes:

- `Illuminate\Support\Collection`, the general one, which you get from `collect()`, and
- `Illuminate\Database\Eloquent\Collection`, which extends it and is what you get from
  `Model::all()` or `->get()`.

A macro registered on the Eloquent one does **not** exist on the base one. So
`collect($array)->lists('x')` was still broken. And neither macro helps with
`DB::table('contracts')->lists('id')` or `Contract::where(...)->lists('id')`, because those are
builder calls, not collections.

So the shim is a safety net for one class of calls, not a fix. Treat it like that.

## Step 2: actually remove the old calls

Finding them is easy:

```bash
grep -rn -- "->lists(" app/ resources/views/ | wc -l
```

Fewer hits than I feared, but enough of them in places nobody tests by hand. The replacement is
mechanical, since `pluck()` takes the same arguments in 5.3:

```bash
grep -rl -- "->lists(" app/ resources/views/ | xargs sed -i 's/->lists(/->pluck(/g'
```

I still read every diff before committing, because one hit was a method called `lists()` on one of
our own classes that has nothing to do with Laravel. sed doesn't know that.

One more behavior change to watch for: in 5.3, query builder `get()` returns a collection instead
of an array. Code that did `DB::table(...)->pluck('id')` and then passed the result to
`in_array()` or `array_merge()` started to misbehave. `->all()` or `->toArray()` at the boundary
fixes it.

## Step 3: delete the shim

Once the grep returns nothing, the macro goes away. I put a comment in the provider and created a
ticket for it, otherwise "temporary" in a codebase means "forever".

## What I'd do differently

- Run the grep **before** the upgrade, on the old version. `pluck()` already worked in 5.2, so the
  rename could have been its own small, boring PR, deployed separately.
- Make deprecation notices visible. They were in the docs and nobody looked at them, because
  nothing in the app complained.
- Have at least one smoke test that opens every admin page. It doesn't need to assert much;
  "returns 200" would have caught most of this.

Upgrades are mostly not hard. They are just long, and the long tail is always in the code
nobody is looking at.
