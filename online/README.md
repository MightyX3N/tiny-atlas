# Tiny Atlas online service

The small service the games talk to for leaderboards, ghosts, shared routes, friends and finding riders nearby. It runs
on Cloudflare's free plan (a Worker with a D1 database), so there is no machine to keep running. The game works
fully without it: everything online is optional.

- `src/index.js` the service (every call is a POST of JSON to `/v1/<name>`)
- `schema.sql` the database's tables
- `test/api_test.mjs` checks every call against a running copy

Riding live together never goes through here: games connect to each other directly (the standalone through
playit.gg when someone hosts; GMod through its own server).

## Putting it online

GitHub Actions does it (`.github/workflows/online.yml`): whenever something in `online/` changes on `main` (or when
it is started by hand from the Actions tab), it tests the service against a local copy and then deploys it to
Cloudflare. It needs two repository secrets: `CLOUDFLARE_API_TOKEN` (a token with Workers and D1 edit rights) and
`CLOUDFLARE_ACCOUNT_ID`.

The deployed address (`https://tinyatlas.<account>.workers.dev`) goes in the game: `O.DEFAULT_URL` in
`game/gamemodes/tinyatlas/gamemode/cl_online.lua` (players can also set `ta_online_url`).

Optional, for taking a shared route down or renaming a player: `npx wrangler secret put ADMIN_KEY`, then POST
`/v1/admin` with `{"admin": "<key>", "remove_route": "<route id>"}`.

## Trying it locally

```
npx wrangler d1 execute tinyatlas --local --file=schema.sql
npx wrangler dev                      # http://127.0.0.1:8787
node test/api_test.mjs                # in another terminal
```

The game's own online test (fake GMod) runs against it too:
`python3 ../tools/luajit.py ../game/tests/test_online.lua <map cache> http://127.0.0.1:8787` (from `game/tests`).

## Limits (free plan)

100,000 requests a day, 5 GB stored, 5 million rows read and 100,000 written a day. A game riding says where it is
once a minute; leaderboards and ghosts are a few requests per ride.
