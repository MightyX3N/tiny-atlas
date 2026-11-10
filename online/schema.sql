-- Tiny Atlas online service: the D1 database (SQLite). Run once:
--   npx wrangler d1 execute tinyatlas --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS players (id TEXT PRIMARY KEY, name TEXT, kit TEXT, created REAL, seen REAL);
CREATE TABLE IF NOT EXISTS friends (a TEXT, b TEXT, created REAL, PRIMARY KEY (a, b));
-- who is riding where right now (rows older than a minute or so are ignored, and cleared now and then)
CREATE TABLE IF NOT EXISTS presence (player TEXT PRIMARY KEY, t REAL, name TEXT, kit TEXT, route TEXT, route_name TEXT,
  addr TEXT, visible INTEGER, game TEXT, roam INTEGER, ax INTEGER, ay INTEGER);
CREATE INDEX IF NOT EXISTS presence_route ON presence (route);
CREATE INDEX IF NOT EXISTS presence_area ON presence (ax, ay);
CREATE TABLE IF NOT EXISTS routes (id TEXT PRIMARY KEY, name TEXT, owner TEXT, gpx TEXT, length REAL, climb REAL,
  lat REAL, lon REAL, created REAL, removed INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS route_rides (route TEXT PRIMARY KEY, n INTEGER);
-- the best ride per rider, per route, per way of riding (trainer / keys), with its ghost
CREATE TABLE IF NOT EXISTS rides (id INTEGER PRIMARY KEY AUTOINCREMENT, route TEXT, player TEXT, time REAL, length REAL,
  source TEXT, avg_power REAL, kg REAL, kit TEXT, ghost TEXT, created REAL);
CREATE INDEX IF NOT EXISTS rides_route ON rides (route, source, time);
CREATE INDEX IF NOT EXISTS rides_player ON rides (player, route, source);
