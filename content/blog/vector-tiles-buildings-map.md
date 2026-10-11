+++
title = "Don't send the whole city: vector tiles for a map full of buildings"
description = "Why a big GeoJSON response stops working, how vector tiles fix it, and generating them straight from PostGIS"
date = "2021-02-21T18:40:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "vector-tiles-buildings-map"
author = "Milorad Bozic"
tags = ["nodejs", "typescript", "maps", "postgis", "performance"]

+++

A change of scene: I'm now at Brightmarbles, working on Savills Maps, a mapping product for
**Savills**, the real-estate company. Think a city map where every building is a shape you can click,
with data about it: ownership, use, size, deals. Node.js and TypeScript on the backend, React on the
front.

After years of exams and queues it's a very different kind of data, and the first lesson was about
volume.

## The naive version

The obvious API is "give me the buildings in this area" returning GeoJSON:

```
GET /buildings?bbox=-0.15,51.50,-0.10,51.52
```

It works fine when you're zoomed in on a few streets. Zoom out to a whole district and it's tens of
thousands of polygons, each with dozens of coordinates. The response is many megabytes, the server
spends its time building one enormous JSON string, the browser spends its time parsing it, and then
the map tries to draw all of it, including details too small to see at that zoom.

Every part of that is the wrong amount of work.

## Vector tiles

Map libraries solved this a long time ago with **tiles**. The world is split into a pyramid of square
tiles: at zoom 0 one tile covers the whole world, at every next zoom level each tile splits into four.
The client asks only for the tiles it's showing, at the zoom it's showing:

```
GET /tiles/buildings/{z}/{x}/{y}.mvt
```

A **vector tile** (Mapbox Vector Tile format, protobuf) contains the geometries for that square,
already:

- **clipped** to the tile, so a huge polygon is sent only in the pieces that are visible,
- **simplified** for that zoom level, so you don't send detail smaller than a pixel,
- **encoded compactly** as integers relative to the tile, not as JSON floats.

The client (Mapbox GL in our case) renders them on the GPU and styles them itself, so the same tiles
can be shown in different colours depending on what the user is looking at.

## Generating tiles from PostGIS

If your geometries are in PostGIS, you don't need a separate tile pipeline to start. PostGIS can
build a tile directly in SQL with `ST_AsMVT`:

```sql
WITH bounds AS (
  SELECT ST_TileEnvelope($1, $2, $3) AS geom      -- z, x, y
),
mvtgeom AS (
  SELECT
    b.id,
    b.use_class,
    ST_AsMVTGeom(ST_Transform(b.geom, 3857), bounds.geom) AS geom
  FROM buildings b, bounds
  WHERE b.geom && ST_Transform(bounds.geom, 4326)
)
SELECT ST_AsMVT(mvtgeom.*, 'buildings') FROM mvtgeom;
```

And the Node side is a thin handler that returns bytes:

```ts
app.get('/tiles/buildings/:z/:x/:y.mvt', async (req, res) => {
  const { z, x, y } = parseTileParams(req.params);
  const { rows } = await pool.query(TILE_SQL, [z, x, y]);
  const tile: Buffer = rows[0].st_asmvt;

  res.setHeader('Content-Type', 'application/vnd.mapbox-vector-tile');
  res.setHeader('Cache-Control', 'public, max-age=3600');
  res.send(tile);
});
```

Three things make this fast enough:

- A **spatial index** (GiST) on the geometry column, so the `&&` bounding box filter is an index scan.
- Only the **attributes the map needs for styling** go in the tile: an id and a class. Everything else
  is loaded by id when the user clicks a building.
- At low zoom levels, a **minimum size filter** or a pre-simplified table, so zoomed out you don't
  query every shed in the city.

## Caching is the real win

A tile for a given `z/x/y` is the same for every user until the underlying data changes. That makes
tiles perfect for HTTP caching: a CDN in front of the tile endpoint serves most requests without
touching Node or Postgres at all.

The question is invalidation: when a building changes, which tiles are now wrong? It's one tile per
zoom level that contains the building, which is easy to compute. For data that changes rarely, a
modest `max-age` and accepting a bit of staleness is simpler and good enough. Same question as
[always](/blog/elasticsearch-read-model-from-replica/): how stale is OK, for whom?

## The pattern

Don't send what the client can't show. Split the data so that the client asks for exactly what's on
screen, at the detail it can display, and make those pieces cacheable. That's what tiles are, and the
idea works far beyond maps.
