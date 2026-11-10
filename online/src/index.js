// Tiny Atlas online service: a Cloudflare Worker with a D1 database (free plan). The games (GMod and the
// standalone) talk to it with web requests. It keeps:
//   - players: an ID made from a secret only their game knows (no accounts, no passwords), a name, their kit
//   - friends: the players you added by their friend code
//   - who is riding where right now (a rough area or the route, and their playit address if they host), so games
//     can find riders nearby and connect to each other directly - the riding itself never comes here
//   - leaderboards per route, each with the ghost of the ride (where the rider was every second)
//   - shared routes (GPX), with the first and last few hundred metres cut off by the game before sharing
// Every call is a POST of JSON to /v1/<name>, answered with JSON: { ok: true, ... } or { ok: false, error }.
const VERSION = 1;
const MAX_BODY = 1500000;           // D1 keeps strings up to 2 MB: a ghost of a very long ride, or a big GPX file
const PRESENCE_TTL = 90;            // seconds a rider stays listed after their game last said where it is
const AREA_DEG = 0.05;              // the size of an area riders are matched in (about 5 km)
const BOARD = 10;                   // leaderboard places sent
const GHOSTS = 8;                   // ghosts offered for a route

class Fail extends Error {}
const fail = (m) => { throw new Fail(m); };
const now = () => Date.now() / 1000;

// ---- route IDs: the same as the game's (atlas/route.lua M.id) ----
// every point's latitude and longitude to 5 decimals, hashed twice (two bases, mod 2^31 - 1), as 16 hex digits
export function routeId(points) {
  let h1 = 7, h2 = 11;
  const M = 2147483647;
  for (const [lat, lon] of points) {
    const s = `${lat.toFixed(5)},${lon.toFixed(5)};`;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      h1 = (h1 * 131 + c) % M;
      h2 = (h2 * 1000003 + c) % M;
    }
  }
  return h1.toString(16).padStart(8, "0") + h2.toString(16).padStart(8, "0");
}

function attr(tag, name) {
  const m = tag.match(new RegExp(`(?:^|[^\\w])${name}\\s*=\\s*"([^"]*)"`)) || tag.match(new RegExp(`(?:^|[^\\w])${name}\\s*=\\s*'([^']*)'`));
  const v = m ? parseFloat(m[1]) : NaN;
  return Number.isFinite(v) ? v : null;
}
export function gpxPoints(text) {
  for (const kind of ["trkpt", "rtept"]) {
    const pts = [];
    const re = new RegExp(`<${kind}(\\s[^>]*)>`, "g");
    let m;
    while ((m = re.exec(text))) {
      const lat = attr(m[1], "lat"), lon = attr(m[1], "lon");
      if (lat !== null && lon !== null) pts.push([lat, lon]);
    }
    if (pts.length) return pts;
  }
  return [];
}
function routeFacts(points, text) {
  let length = 0, climb = 0;
  for (let i = 1; i < points.length; i++) {
    const [a, b] = points[i - 1], [c, d] = points[i];
    const k = 111320 * Math.cos(c * Math.PI / 180);
    length += Math.hypot((c - a) * 110540, (d - b) * k);
  }
  const eles = [...text.matchAll(/<ele>\s*([-\d.eE]+)\s*<\/ele>/g)].map((m) => parseFloat(m[1]));
  if (eles.length === points.length) {
    const sm = eles.map((_, i) => { const w = eles.slice(Math.max(0, i - 5), i + 6); return w.reduce((x, y) => x + y, 0) / w.length; });
    for (let i = 1; i < sm.length; i++) climb += Math.max(0, sm[i] - sm[i - 1]);
  }
  return [length, climb];
}

// ---- players ----
const B32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";   // no 0/O, 1/I: easy to read out and type
export async function playerId(key) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("tinyatlas:" + key)));
  let n = 0n;
  for (let i = 0; i < 5; i++) n = (n << 8n) | BigInt(d[i]);
  let out = "";
  for (let i = 0; i < 8; i++) out += B32[Number((n >> BigInt(5 * i)) & 31n)];
  return out;
}
function cleanName(s, n = 24) {
  s = String(s ?? "").replace(/[\x00-\x1f\x7f<>]/g, "").trim();
  return s.slice(0, n) || "Rider";
}
const str = (v, n) => String(v ?? "").slice(0, n);

async function me(db, req) {
  const key = String(req.key ?? "");
  if (key.length < 16 || key.length > 128) fail("no player key");
  const pid = await playerId(key);
  await db.prepare("INSERT OR IGNORE INTO players (id, name, kit, created, seen) VALUES (?,?,?,?,?)")
    .bind(pid, cleanName(req.name), str(req.kit, 200), now(), now()).run();
  return pid;
}

const CALLS = {};

CALLS.hello = async (db, req) => {
  const pid = await me(db, req);
  await db.prepare("UPDATE players SET name=?, kit=?, seen=? WHERE id=?").bind(cleanName(req.name), str(req.kit, 200), now(), pid).run();
  return { id: pid, version: VERSION };
};

async function friendsOf(db, pid) {
  const rows = (await db.prepare(`SELECT p.id, p.name, p.seen, pr.t, pr.route, pr.route_name, pr.addr, pr.roam
    FROM friends f JOIN players p ON p.id=f.b LEFT JOIN presence pr ON pr.player=p.id WHERE f.a=? ORDER BY p.name`).bind(pid).all()).results;
  const t = now();
  return rows.map((r) => {
    const live = r.t && t - r.t < PRESENCE_TTL;
    const f = { id: r.id, name: r.name, seen: r.seen, riding: !!live };
    if (live) Object.assign(f, { route: r.route, route_name: r.route_name, addr: r.addr, roam: !!r.roam });
    return f;
  });
}

// where you are riding (a rough area or a route) and your playit address if you host; answers with the riders
// you can connect to (on your route or in the areas around yours), and your friends
CALLS.presence = async (db, req) => {
  const pid = await me(db, req);
  const t = now();
  if (req.riding === false) {
    await db.prepare("DELETE FROM presence WHERE player=?").bind(pid).run();
    return { riders: [], friends: await friendsOf(db, pid) };
  }
  let ax = null, ay = null;
  if (typeof req.lat === "number" && typeof req.lon === "number") {
    ax = Math.floor(req.lat / AREA_DEG); ay = Math.floor(req.lon / AREA_DEG);
  }
  const addr = typeof req.addr === "string" && req.addr.length < 100 ? req.addr : null;
  const route = typeof req.route === "string" && /^[0-9a-f]{16}$/.test(req.route) ? req.route : null;
  const visible = req.visible !== false;
  await db.prepare(`INSERT INTO presence (player, t, name, kit, route, route_name, addr, visible, game, roam, ax, ay)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(player) DO UPDATE SET t=excluded.t, name=excluded.name, kit=excluded.kit,
    route=excluded.route, route_name=excluded.route_name, addr=excluded.addr, visible=excluded.visible, game=excluded.game,
    roam=excluded.roam, ax=excluded.ax, ay=excluded.ay`)
    .bind(pid, t, cleanName(req.name), str(req.kit, 200), route, req.route_name ? cleanName(req.route_name, 60) : null, addr,
      visible ? 1 : 0, str(req.game, 10), req.roam ? 1 : 0, ax, ay).run();
  if (Math.random() < 0.05) await db.prepare("DELETE FROM presence WHERE t<?").bind(t - PRESENCE_TTL * 4).run();
  let riders = [];
  if (visible) {
    // the others on the same route, or in the 3 x 3 areas around yours; one of the two must host (playit)
    const rows = (await db.prepare(`SELECT player, name, kit, addr, route FROM presence
      WHERE player<>? AND visible=1 AND t>? AND (addr IS NOT NULL OR ? IS NOT NULL)
      AND ((? IS NOT NULL AND route=?) OR (? IS NOT NULL AND ax BETWEEN ?-1 AND ?+1 AND ay BETWEEN ?-1 AND ?+1)) LIMIT 20`)
      .bind(pid, t - PRESENCE_TTL, addr, route, route, ax, ax, ax, ay, ay).all()).results;
    riders = rows.map((r) => ({ id: r.player, name: r.name, kit: r.kit, addr: r.addr, route: r.route }));
  }
  const online = (await db.prepare("SELECT COUNT(*) AS n FROM presence WHERE t>?").bind(t - PRESENCE_TTL).first()).n;
  return { riders, friends: await friendsOf(db, pid), online };
};

async function board(db, route, source, pid) {
  const top = (await db.prepare(`SELECT r.id, r.player, r.time, r.kit, p.name FROM rides r JOIN players p ON p.id=r.player
    WHERE r.route=? AND r.source=? ORDER BY r.time LIMIT ?`).bind(route, source, BOARD).all()).results
    .map((r, i) => ({ rank: i + 1, id: r.player, name: r.name, time: r.time, ride: r.id, kit: r.kit }));
  let mine = null;
  if (pid) {
    const m = await db.prepare("SELECT id, time FROM rides WHERE route=? AND source=? AND player=?").bind(route, source, pid).first();
    if (m) {
      const n = (await db.prepare("SELECT COUNT(*) AS n FROM rides WHERE route=? AND source=? AND time<?").bind(route, source, m.time).first()).n;
      mine = { rank: n + 1, time: m.time, ride: m.id };
    }
  }
  const total = (await db.prepare("SELECT COUNT(*) AS n FROM rides WHERE route=? AND source=?").bind(route, source).first()).n;
  return { top, mine, total };
}

// a route's leaderboard, your place, the ghosts to ride with, and whether it is shared
CALLS.route = async (db, req) => {
  const pid = await me(db, req);
  const rid = String(req.route ?? "");
  const source = req.source === "trainer" ? "trainer" : "keys";
  const { top, mine, total } = await board(db, rid, source, pid);
  const ghosts = [], seen = new Set();
  const add = (r, why) => {
    if (r && !seen.has(r.id) && ghosts.length < GHOSTS) {
      seen.add(r.id);
      ghosts.push({ ride: r.id, player: r.player, name: r.name, time: r.time, kit: r.kit, why });
    }
  };
  const sel = `SELECT r.id, r.player, r.time, r.kit, p.name FROM rides r JOIN players p ON p.id=r.player WHERE r.route=? AND r.source=?`;
  add(await db.prepare(sel + " ORDER BY r.time LIMIT 1").bind(rid, source).first(), "best");
  if (mine) {
    for (const r of (await db.prepare(sel + " AND r.time<? ORDER BY r.time DESC LIMIT 2").bind(rid, source, mine.time).all()).results) add(r, "just faster");
    add(await db.prepare(sel + " AND r.player=?").bind(rid, source, pid).first(), "you");
  }
  for (const r of (await db.prepare(sel + " AND r.player IN (SELECT b FROM friends WHERE a=?) ORDER BY r.time LIMIT 4").bind(rid, source, pid).all()).results) add(r, "friend");
  if (!mine) for (const r of (await db.prepare(sel + " ORDER BY r.time DESC LIMIT 3").bind(rid, source).all()).results) add(r, "rider");
  // a quiet board: riders of the other kind (trainer / keys) keep you company too (their times stay on their board)
  if (ghosts.length < 3) {
    for (const r of (await db.prepare(sel + " ORDER BY r.time LIMIT 3").bind(rid, source === "keys" ? "trainer" : "keys").all()).results) add(r, "rider");
  }
  const rr = await db.prepare("SELECT name, removed FROM routes WHERE id=?").bind(rid).first();
  const n = await db.prepare("SELECT n FROM route_rides WHERE route=?").bind(rid).first();
  return { board: top, me: mine, riders: total, ghosts, source, shared: !!(rr && !rr.removed), name: rr ? rr.name : null, rides: n ? n.n : 0 };
};

CALLS.ghost = async (db, req) => {
  const r = await db.prepare(`SELECT r.ghost, r.kit, r.time, r.player, p.name FROM rides r JOIN players p ON p.id=r.player WHERE r.id=?`)
    .bind(Number(req.ride) || 0).first();
  if (!r) fail("no such ride");
  return { ghost: r.ghost, kit: r.kit, time: r.time, name: r.name, player: r.player };
};

// a ghost must be a whole ride that matches its time: "v1;" then one sample a second, each "s,speed,cadence"
// (metres along, dm/s, rpm), the distance growing
export function checkGhost(text, time, length) {
  if (!text.startsWith("v1;")) fail("bad ghost");
  const parts = text.slice(3).split(";");
  if (parts.length < 2) fail("ghost too short");
  let last = -1;
  for (const p of parts) {
    const f = p.split(",");
    if (f.length !== 3) fail("bad ghost sample");
    const s = parseFloat(f[0]);
    if (!Number.isFinite(s)) fail("bad ghost sample");
    if (s < last - 0.5) fail("the ghost goes backwards");
    if (last >= 0 && s - last > 30) fail("the ghost jumps");
    last = s;
  }
  if (Math.abs((parts.length - 1) - time) > Math.max(5, time * 0.02)) fail("the ghost does not match the time");
  if (last < length * 0.97) fail("the ghost does not finish the route");
}

// a finished ride: its time, how it was ridden and its ghost; the best per rider (per way of riding) stays
CALLS.ride = async (db, req) => {
  const pid = await me(db, req);
  const rid = String(req.route ?? "");
  if (!/^[0-9a-f]{16}$/.test(rid)) fail("bad route");
  const t = Number(req.time) || 0, length = Number(req.length) || 0;
  const source = req.source === "trainer" ? "trainer" : "keys";
  const kg = Number(req.kg) || 75, power = Number(req.avg_power) || 0;
  if (t < 10 || length < 50) fail("too short");
  if (length / t > 25) fail("faster than possible");
  if (source === "trainer" && t > 600 && power / Math.max(40, kg) > 7) fail("more watts per kilo than possible for that long");
  const g = String(req.ghost ?? "");
  if (g.length > MAX_BODY) fail("ghost too big");
  checkGhost(g, t, length);
  await db.prepare("INSERT INTO route_rides (route, n) VALUES (?, 1) ON CONFLICT(route) DO UPDATE SET n=n+1").bind(rid).run();
  const old = await db.prepare("SELECT id, time FROM rides WHERE route=? AND player=? AND source=?").bind(rid, pid, source).first();
  let best = false;
  if (!old || t < old.time) {
    best = true;
    if (old) await db.prepare("DELETE FROM rides WHERE id=?").bind(old.id).run();
    await db.prepare(`INSERT INTO rides (route, player, time, length, source, avg_power, kg, kit, ghost, created)
      VALUES (?,?,?,?,?,?,?,?,?,?)`).bind(rid, pid, t, length, source, power, kg, str(req.kit, 200), g, now()).run();
  }
  const { mine, total } = await board(db, rid, source, pid);
  return { best, rank: mine && mine.rank, riders: total, time: mine && mine.time };
};

// share a route: the game has cut its ends off and kept only the track; the ID must match the points
CALLS.share = async (db, req) => {
  const pid = await me(db, req);
  const gpx = String(req.gpx ?? "");
  if (gpx.length > MAX_BODY) fail("route too big");
  const pts = gpxPoints(gpx);
  if (pts.length < 2) fail("not a route");
  const rid = routeId(pts);
  if (req.route && req.route !== rid) fail("the route ID does not match its points");
  const old = await db.prepare("SELECT removed FROM routes WHERE id=?").bind(rid).first();
  if (old && old.removed) fail("this route was taken down");
  if (old) return { route: rid, already: true };
  const [length, climb] = routeFacts(pts, gpx);
  if (length < 200) fail("too short to share");
  await db.prepare("INSERT INTO routes (id, name, owner, gpx, length, climb, lat, lon, created) VALUES (?,?,?,?,?,?,?,?,?)")
    .bind(rid, cleanName(req.name, 60), pid, gpx, length, climb, pts[0][0], pts[0][1], now()).run();
  return { route: rid };
};

// shared routes: the most ridden, the newest, or the nearest to a place
CALLS.routes = async (db, req) => {
  const sql = `SELECT r.id, r.name, r.length, r.climb, r.lat, r.lon, r.created, COALESCE(n.n, 0) AS rides, p.name AS owner
    FROM routes r LEFT JOIN route_rides n ON n.route=r.id LEFT JOIN players p ON p.id=r.owner WHERE r.removed=0`;
  const rows = (await db.prepare(sql + (req.sort === "new" ? " ORDER BY r.created DESC" : " ORDER BY rides DESC, r.created DESC") + " LIMIT 200").all()).results;
  if (req.sort === "near" && typeof req.lat === "number" && typeof req.lon === "number") {
    const c = Math.cos(req.lat * Math.PI / 180);
    rows.sort((a, b) => ((a.lat - req.lat) ** 2 + ((a.lon - req.lon) * c) ** 2) - ((b.lat - req.lat) ** 2 + ((b.lon - req.lon) * c) ** 2));
  }
  return { routes: rows.slice(0, 60) };
};

CALLS.route_gpx = async (db, req) => {
  const r = await db.prepare("SELECT gpx, name FROM routes WHERE id=? AND removed=0").bind(String(req.route ?? "")).first();
  if (!r) fail("no such route");
  return { gpx: r.gpx, name: r.name };
};

CALLS.friend_add = async (db, req) => {
  const pid = await me(db, req);
  const code = String(req.code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code === pid) fail("that is your own code");
  const f = await db.prepare("SELECT id, name FROM players WHERE id=?").bind(code).first();
  if (!f) fail("no rider with that code");
  await db.prepare("INSERT OR IGNORE INTO friends (a, b, created) VALUES (?,?,?)").bind(pid, code, now()).run();
  return { friend: { id: f.id, name: f.name }, friends: await friendsOf(db, pid) };
};

CALLS.friend_remove = async (db, req) => {
  const pid = await me(db, req);
  await db.prepare("DELETE FROM friends WHERE a=? AND b=?").bind(pid, String(req.id ?? "")).run();
  return { friends: await friendsOf(db, pid) };
};

CALLS.friends = async (db, req) => ({ friends: await friendsOf(db, await me(db, req)) });

// ---- admin: a secret set with `npx wrangler secret put ADMIN_KEY` (takes a shared route down, renames a player) ----
CALLS.admin = async (db, req, env) => {
  if (!env.ADMIN_KEY || req.admin !== env.ADMIN_KEY) fail("not allowed");
  if (req.remove_route) await db.prepare("UPDATE routes SET removed=1 WHERE id=?").bind(String(req.remove_route)).run();
  if (req.rename_player) await db.prepare("UPDATE players SET name=? WHERE id=?").bind(cleanName(req.name), String(req.rename_player)).run();
  const count = async (t) => (await db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).first()).n;
  return { players: await count("players"), routes: await count("routes"), rides: await count("rides") };
};

const json = (status, obj) => new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/v1/status")) {
      return json(200, { ok: true, service: "tinyatlas", version: VERSION });
    }
    if (request.method !== "POST") return json(404, { ok: false, error: "not found" });
    const m = url.pathname.match(/^\/v1\/(\w+)$/);
    const fn = m && CALLS[m[1]];
    if (!fn) return json(404, { ok: false, error: "no such call" });
    const len = Number(request.headers.get("Content-Length") || 0);
    if (len > MAX_BODY + 4096) return json(413, { ok: false, error: "too big" });
    try {
      const req = await request.json();
      if (!req || typeof req !== "object" || Array.isArray(req)) fail("bad request");
      const res = await fn(env.DB, req, env);
      res.ok = true;
      return json(200, res);
    } catch (e) {
      if (e instanceof Fail || e instanceof SyntaxError) return json(400, { ok: false, error: e.message });
      console.error(m[1], e && e.stack);
      return json(500, { ok: false, error: "server error" });
    }
  },
};
