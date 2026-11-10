// Checks the online service end to end against a running copy (npx wrangler dev):
//   node test/api_test.mjs [http://127.0.0.1:8787]
// Two players: names, friends, presence (finding each other, a playit address), sharing a route, rides with ghosts,
// the leaderboard and the checks that turn away impossible rides.
import { readFileSync } from "node:fs";
import { gpxPoints, routeId } from "../src/index.js";

const BASE = process.argv[2] || "http://127.0.0.1:8787";
let bad = 0;
const check = (what, ok, detail) => {
  if (!ok) bad++;
  console.log(`${what.padEnd(58)} ${ok ? "ok" : "WRONG"}${detail !== undefined ? "  (" + detail + ")" : ""}`);
};
const call = async (name, body) => {
  const r = await fetch(`${BASE}/v1/${name}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return r.json();
};
const rnd = () => [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");

const A = { key: rnd(), name: "Anna", kit: "11|" }, B = { key: rnd(), name: "Bo", kit: "222|" };
const ha = await call("hello", A), hb = await call("hello", B);
check("players get an ID", ha.ok && /^[A-Z2-9]{8}$/.test(ha.id), ha.id);
check("the same key gives the same ID", (await call("hello", A)).id === ha.id);
check("adding a friend by code", (await call("friend_add", { ...A, code: hb.id.toLowerCase() })).friend?.name === "Bo");
check("a wrong code is turned away", (await call("friend_add", { ...A, code: "ZZZZZZZZ" })).ok === false);

// a route: the game's Rold Skov, shared
// (with one more point at the end, different every run: its own route ID, so earlier runs are not on its leaderboard)
const gpx = readFileSync(new URL("../../game/gamemodes/tinyatlas/routes/rold-skov.gpx", import.meta.url), "utf8")
  .replace(/<\/trkseg>/, `<trkpt lat="56.83${Math.floor(Math.random() * 9000 + 1000)}" lon="9.8900"></trkpt></trkseg>`);
const pts = gpxPoints(gpx);
const rid = routeId(pts);
const sh = await call("share", { ...A, gpx, name: "Rold Skov loop", route: rid });
check("sharing a route", sh.ok && sh.route === rid, rid);
check("a route ID that does not match is turned away", (await call("share", { ...A, gpx, route: "0123456789abcdef" })).ok === false);
const list = await call("routes", { sort: "popular" });
check("the shared route is listed", list.routes?.some((r) => r.id === rid && r.length > 15000), list.routes?.[0]?.length);
check("and can be downloaded", (await call("route_gpx", { route: rid })).gpx === gpx);

// rides: a ghost a second, 20 km in about 50 minutes
const ghost = (secs, len) => "v1;" + Array.from({ length: secs + 1 }, (_, i) => `${Math.min(len, (len * i) / secs).toFixed(1)},70,85`).join(";");
const r1 = await call("ride", { ...A, route: rid, time: 3000, length: 20000, source: "trainer", avg_power: 200, kg: 70, ghost: ghost(3000, 20000), kit: "11|" });
check("a ride goes on the leaderboard", r1.ok && r1.rank === 1, JSON.stringify(r1));
const r2 = await call("ride", { ...B, route: rid, time: 2900, length: 20000, source: "trainer", avg_power: 220, kg: 72, ghost: ghost(2900, 20000) });
check("a faster ride goes above it", r2.rank === 1);
check("a slower ride of your own keeps your best",
  (await call("ride", { ...A, route: rid, time: 3100, length: 20000, source: "trainer", ghost: ghost(3100, 20000) })).best === false);
check("an impossible speed is turned away", (await call("ride", { ...A, route: rid, time: 500, length: 20000, ghost: ghost(500, 20000) })).ok === false);
check("too many watts per kilo is turned away",
  (await call("ride", { ...A, route: rid, time: 3000, length: 20000, source: "trainer", avg_power: 900, kg: 60, ghost: ghost(3000, 20000) })).ok === false);
check("a ghost that doesn't finish is turned away", (await call("ride", { ...A, route: rid, time: 3000, length: 20000, ghost: ghost(3000, 15000) })).ok === false);
const info = await call("route", { ...A, route: rid, source: "trainer" });
check("the leaderboard", info.board?.length === 2 && info.board[0].name === "Bo", info.board?.map((b) => b.name).join(", "));
check("your own place", info.me?.rank === 2);
check("ghosts: the best and a friend's", info.ghosts?.some((g) => g.why === "best" && g.name === "Bo"), info.ghosts?.map((g) => g.why).join(", "));
check("keyboard rides have their own board", (await call("route", { ...A, route: rid, source: "keys" })).board.length === 0);
const g = await call("ghost", { ride: info.ghosts[0].ride });
check("a ghost downloads", g.ghost?.startsWith("v1;") && g.name === "Bo");

// presence: Bo hosts (playit address), Anna rides the same route without hosting
const pb = await call("presence", { ...B, route: rid, route_name: "Rold Skov", addr: "abc.joinmc.link:12345", lat: 56.8, lon: 9.84 });
const pa = await call("presence", { ...A, route: rid, route_name: "Rold Skov", lat: 56.8, lon: 9.84 });
check("riders on your route are found, with their address", pa.riders?.some((r) => r.name === "Bo" && r.addr === "abc.joinmc.link:12345"));
check("a friend riding is shown", pa.friends?.some((f) => f.name === "Bo" && f.riding && f.route === rid));
check("riders nearby in roam are found", (await call("presence", { ...A, lat: 56.81, lon: 9.86, roam: true })).riders?.some((r) => r.name === "Bo"));
check("riders far away are not", (await call("presence", { ...A, lat: 55.6, lon: 12.5, roam: true })).riders?.length === 0);
check("hidden riders are not listed", (await call("presence", { ...B, route: rid, addr: "x:1", visible: false })).ok &&
  (await call("presence", { ...A, route: rid })).riders.length === 0);
await call("presence", { ...B, riding: false });
check("a rider who stops is no longer listed", (await call("presence", { ...A, route: rid })).friends.find((f) => f.name === "Bo").riding === false);
check("bad requests get an answer, not a crash", (await (await fetch(`${BASE}/v1/ride`, { method: "POST", body: "{" })).json()).ok === false);
console.log(bad ? `FAILED: ${bad} checks` : "ALL ONLINE CHECKS PASSED");
process.exit(bad ? 1 : 0);
