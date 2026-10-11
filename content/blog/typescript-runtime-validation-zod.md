+++
title = "TypeScript types stop at the network: validating input with Zod"
description = "Why `as User` is a lie at every API boundary, and how one schema gives you both runtime validation and static types"
date = "2021-05-16T19:10:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "typescript-runtime-validation-zod"
author = "Milorad Bozic"
tags = ["typescript", "nodejs", "api", "validation"]

+++

TypeScript makes a Node codebase much nicer to work in. But there's one place where it quietly
stops helping, and it's exactly the place where most bugs come from: **the boundary**. Anything that
comes from outside your process, HTTP request bodies, query strings, responses from other services,
messages from a queue, environment variables, is `unknown` at runtime, no matter what type you put on it.

## The lie

```ts
app.post('/searches', async (req, res) => {
  const body = req.body as SavedSearch;   // <- trust me
  await searches.save(body.userId, body.bounds, body.filters);
  res.sendStatus(201);
});
```

`as SavedSearch` doesn't check anything. It tells the compiler to stop asking. If a client sends
`bounds` as a string, or forgets `filters`, the code compiles fine and fails somewhere deeper, with an
error that has nothing to do with the real cause. Or worse, it doesn't fail and saves garbage.

The types describe what you *hope* arrives. You need something that checks what *actually* arrives.

## One schema, two uses

[Zod](https://github.com/colinhacks/zod) lets you write a schema once, validate data against it at
runtime, and **derive the TypeScript type from the schema**. So the type and the check can't drift apart.

```ts
import { z } from 'zod';

const Bounds = z.object({
  west: z.number().min(-180).max(180),
  south: z.number().min(-90).max(90),
  east: z.number().min(-180).max(180),
  north: z.number().min(-90).max(90),
});

const SavedSearch = z.object({
  name: z.string().min(1).max(100),
  bounds: Bounds,
  filters: z.object({
    useClass: z.array(z.enum(['office', 'retail', 'residential', 'industrial'])).default([]),
    minArea: z.number().positive().optional(),
  }),
});

type SavedSearch = z.infer<typeof SavedSearch>;   // the type, for free
```

And at the boundary:

```ts
app.post('/searches', async (req, res) => {
  const parsed = SavedSearch.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ errors: parsed.error.flatten() });
  }

  const search = parsed.data;   // typed as SavedSearch, and actually is one
  await searches.save(req.user.id, search);
  res.sendStatus(201);
});
```

Inside the function, `search` is a real `SavedSearch`. The client gets a 400 with a useful message
instead of a 500 from three layers down.

## A small middleware

Writing `safeParse` in every handler gets old, so we have a tiny helper:

```ts
function validate<T extends z.ZodTypeAny>(schema: T) {
  return (req: Request, res: Response, next: NextFunction) => {
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ errors: parsed.error.flatten() });
    }
    req.body = parsed.data;
    next();
  };
}

app.post('/searches', validate(SavedSearch), saveSearchHandler);
```

## Validate everything that crosses the boundary

Not only request bodies:

- **Query strings.** They're always strings. A small `z.preprocess(Number, z.number())` turns `"12"`
  into `12`, and rejects `"abc"`.
- **Responses from other services and third-party APIs.** If an external API changes a field, you want
  an error at the point where its data enters your system, with the exact field named, not a
  `Cannot read property 'x' of undefined` somewhere in the UI. This is the runtime cousin of [contract
  tests](/blog/consumer-driven-contract-tests/).
- **Environment variables**, at startup. A missing `DATABASE_URL` should crash the process
  immediately with a clear message, not at the first query an hour later.

```ts
const numberFromString = (fallback: number) =>
  z.preprocess((v) => (v === undefined ? fallback : Number(v)), z.number());

const Env = z.object({
  DATABASE_URL: z.string().url(),
  PORT: numberFromString(3000),
  TILE_CACHE_SECONDS: numberFromString(3600),
});

export const env = Env.parse(process.env);
```

## Parse, don't validate

The idea behind all this has a nice name from the Haskell world: *parse, don't validate*. Don't just
check the data and keep passing around the loose thing you got. Turn it into a value of a precise type
once, at the edge, and from then on the rest of the code can trust it.

TypeScript gives you the types. Something like Zod makes them true.
