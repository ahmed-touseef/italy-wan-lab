"use strict";
// Italy WAN lab status page. Reads status.json (written by the collector every
// 15 s) and draws the map, the path, the tables and the change log.

const GEO = {            // latitude, longitude of each city
  milan: [45.464, 9.190], turin: [45.070, 7.687], genoa: [44.405, 8.946],
  florence: [43.770, 11.256], rome: [41.903, 12.496], naples: [40.852, 14.268],
};
const LABEL_AT = { milan: "n", turin: "sw", genoa: "s", florence: "sw", rome: "w", naples: "se" };
const SUBNET_BELOW = { "rome-naples": 1 };   // subnet label on the lower side of this cable
const CURVED = { "naples-milan": 1 };   // the long backbone bends east so it clears Florence
const K = 88, COSLAT = Math.cos(43.2 * Math.PI / 180);
const SVGNS = "http://www.w3.org/2000/svg";
const REFRESH_MS = 10000, STALE_S = 60;

let status = null;
let picked = "rome";
let fetchError = false;

const $ = (id) => document.getElementById(id);
const xy = (city) => {
  const [lat, lon] = GEO[city];
  return [Math.round((lon - 7.2) * K * COSLAT + 60), Math.round((45.9 - lat) * K + 30)];
};

function h(tag, props, ...kids) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else node.setAttribute(k, v);
  }
  for (const kid of kids) if (kid != null) node.append(kid);
  return node;
}
function s(tag, attrs, text) {
  const node = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, v);
  if (text != null) node.textContent = text;
  return node;
}

const cityLabel = (name) => status.cities.find((c) => c.name === name)?.label || name;
const labOn = () => status && status.devices.running > 0;
const joinCities = (list) => list.map(cityLabel).join(" and ");

function linkGeometry(link) {
  const [x1, y1] = xy(link.a), [x2, y2] = xy(link.b);
  if (CURVED[`${link.a}-${link.b}`]) {
    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, len = Math.hypot(x2 - x1, y2 - y1);
    let nx = (y2 - y1) / len, ny = -(x2 - x1) / len;
    if (nx < 0) { nx = -nx; ny = -ny; }               // bend towards the east
    const cx = mx + nx * 110, cy = my + ny * 110;
    return { d: `M${x1} ${y1} Q${cx} ${cy} ${x2} ${y2}`,
             mid: [0.25 * x1 + 0.5 * cx + 0.25 * x2, 0.25 * y1 + 0.5 * cy + 0.25 * y2], n: [nx, ny] };
  }
  return { d: `M${x1} ${y1} L${x2} ${y2}`, mid: [(x1 + x2) / 2, (y1 + y2) / 2], n: null };
}

function subnetLabel(link, g) {
  // Written along the cable, on its upper side (or the side named in SUBNET_BELOW).
  const [x1, y1] = xy(link.a), [x2, y2] = xy(link.b);
  const len = Math.hypot(x2 - x1, y2 - y1);
  let [nx, ny] = g.n || [-(y2 - y1) / len, (x2 - x1) / len];
  const below = SUBNET_BELOW[`${link.a}-${link.b}`];
  if (!g.n && ((ny > 0) !== Boolean(below))) { nx = -nx; ny = -ny; }
  let angle = Math.atan2(y2 - y1, x2 - x1) * 180 / Math.PI;
  if (angle > 90) angle -= 180;
  if (angle < -90) angle += 180;
  const x = Math.round(g.mid[0] + nx * 12), y = Math.round(g.mid[1] + ny * 12);
  return s("text", { class: "subnet", x, y, "text-anchor": "middle", "dominant-baseline": "middle",
                     transform: `rotate(${angle.toFixed(1)} ${x} ${y})` }, link.subnet);
}

function pathCities(path) {
  const seq = ["milan"];
  for (const hop of path?.hops || []) {
    if (hop.node && GEO[hop.node] && seq[seq.length - 1] !== hop.node) seq.push(hop.node);
  }
  return seq;
}

function findLink(a, b) {
  return status.links.find((l) => (l.a === a && l.b === b) || (l.a === b && l.b === a));
}

function drawMap() {
  const svg = $("map");
  svg.querySelectorAll(":scope > :not(title)").forEach((n) => n.remove());

  const grid = s("g");
  for (let lat = 41; lat <= 45; lat++) {
    const y = Math.round((45.9 - lat) * K + 30);
    grid.append(s("line", { class: "grid", x1: 40, x2: 536, y1: y, y2: y }));
    grid.append(s("text", { class: "geo", x: 2, y: y + 4 }, `${lat}°N`));
  }
  for (let lon = 8; lon <= 14; lon++) {
    const x = Math.round((lon - 7.2) * K * COSLAT + 60);
    grid.append(s("line", { class: "grid", x1: x, x2: x, y1: 14, y2: 512 }));
    grid.append(s("text", { class: "geo", x: x - 10, y: 532 }, `${lon}°E`));
  }
  svg.append(grid);

  const cables = s("g"), routes = s("g"), labels = s("g");
  for (const link of status.links) {
    const g = linkGeometry(link);
    const cls = !labOn() ? "off" : link.cable === "up" ? "" : "down";
    const p = s("path", { class: `cable ${cls}`, d: g.d });
    p.append(s("title", {}, `${cityLabel(link.a)} to ${cityLabel(link.b)}: ${link.subnet}, cable ${link.cable}, OSPF ${link.ospf}`));
    cables.append(p);
    labels.append(subnetLabel(link, g));
  }
  const seq = labOn() ? pathCities(status.paths[picked]) : [];
  for (let i = 1; i < seq.length; i++) {
    const link = findLink(seq[i - 1], seq[i]);
    if (link) routes.append(s("path", { class: "route", d: linkGeometry(link).d }));
  }
  svg.append(cables, routes, labels);
  drawRemoteOnMap(svg);

  for (const c of status.cities) {
    const [x, y] = xy(c.name);
    const reachable = c.sites.filter((st) => st.pc.ok).length;
    const health = !labOn() ? "" : reachable === 4 ? "" : reachable === 0 ? "bad" : "warn";
    const classes = ["node", health, c.name === picked ? "picked" : "", c.name === "milan" ? "origin" : ""].join(" ");
    const g = s("g", { class: classes, tabindex: c.name === "milan" ? -1 : 0, role: "button",
                      "aria-label": `${c.label}, router ${c.rid}, ${reachable} of 4 sites reachable` });
    g.append(s("circle", { class: "halo", cx: x, cy: y, r: 12 }));
    g.append(s("circle", { class: "dot", cx: x, cy: y, r: 7 }));
    const at = LABEL_AT[c.name];
    let tx = x, ty = y, anchor = "middle";
    if (at === "n") ty = y - 30;
    if (at === "s") ty = y + 26;
    if (at === "w") { tx = x - 16; ty = y - 2; anchor = "end"; }
    if (at === "sw") { tx = x - 12; ty = y + 24; anchor = "end"; }
    if (at === "se") { tx = x + 12; ty = y + 26; anchor = "end"; }
    const name = c.name === "milan" ? `${c.label} (origin)` : c.label;
    g.append(s("text", { class: "city", x: tx, y: ty, "text-anchor": anchor }, name));
    g.append(s("text", { class: "rid", x: tx, y: ty + 14, "text-anchor": anchor }, c.rid));
    if (c.name !== "milan") {
      g.addEventListener("click", () => pick(c.name));
      g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(c.name); } });
    }
    svg.append(g);
  }
}

function fmtBytes(n) {
  if (n < 1000) return `${n} B`;
  if (n < 1e6) return `${(n / 1e3).toFixed(0)} kB`;
  if (n < 1e9) return `${(n / 1e6).toFixed(1)} MB`;
  return `${(n / 1e9).toFixed(2)} GB`;
}
function fmtAge(epoch) {
  if (!epoch) return "never";
  const age = Math.max(0, Math.round(Date.now() / 1000 - epoch));
  return age < 90 ? `${age} s ago` : age < 5400 ? `${Math.round(age / 60)} min ago`
    : age < 172800 ? `${Math.round(age / 3600)} h ago` : `${Math.round(age / 86400)} days ago`;
}
const remote = () => (status && status.remote) || { enabled: false, peers: [], known_by: [] };

function drawRemoteOnMap(svg) {
  if (!labOn() || !remote().enabled) return;
  const [mx, my] = xy(remote().router || "milan");
  remote().peers.forEach((p, i) => {
    const x = 352, y = 44 + i * 40, idle = p.connected ? "" : "idle";
    const line = s("path", { class: `tunnel ${idle}`, d: `M${mx} ${my} L${x - 8} ${y}` });
    line.append(s("title", {}, `${p.name}: WireGuard tunnel to ${cityLabel(remote().router || "milan")} wg0, ${p.connected ? "connected" : "not connected"}`));
    const g = s("g", { class: `pc ${idle}` });
    g.append(s("rect", { x: x - 8, y: y - 6, width: 16, height: 12, rx: 2 }));
    g.append(s("text", { class: "city", x: x + 14, y: y + 1 }, p.name));
    g.append(s("text", { class: "rid", x: x + 14, y: y + 15 }, `${p.address} ${p.connected ? "connected" : "offline"}`));
    svg.append(line, g);
  });
}

function drawRemote() {
  const r = remote(), body = $("remote").tBodies[0], note = $("remote-note");
  if (!labOn() || !r.enabled) {
    body.replaceChildren(h("tr", {}, h("td", { colspan: 6, class: "state-off", text: labOn() ? "Remote access is not set up right now." : "The lab is switched off." })));
    note.textContent = "";
    return;
  }
  if (!r.peers.length) {
    body.replaceChildren(h("tr", {}, h("td", { colspan: 6, class: "state-off", text: "The tunnel is up but no PC is allowed yet." })));
  } else {
    body.replaceChildren(...r.peers.map((p) => h("tr", {},
      h("td", { text: p.name }),
      h("td", {}, h("span", { class: "ip", text: p.address })),
      h("td", {}, h("span", { class: p.connected ? "state-ok" : "state-off", text: p.connected ? "connected" : "not connected" })),
      h("td", { text: fmtAge(p.last_seen || p.handshake) }),
      h("td", { text: `${fmtBytes(p.rx)} from PC, ${fmtBytes(p.tx)} to PC` }),
      h("td", {}, h("span", { class: p.ping ? "state-ok" : "state-off", text: p.ping ? "replies" : "no reply" })))));
  }
  const others = status.cities.map((c) => c.name);
  const missing = others.filter((c) => !r.known_by.includes(c));
  let text = missing.length === 0
    ? `OSPF: all ${others.length} routers have a route to 10.9.0.0/24.`
    : `OSPF: ${others.length - missing.length} of ${others.length} routers have a route to 10.9.0.0/24 (missing: ${joinCities(missing)}).`;
  if (r.peers.some((p) => p.connected && !p.ping)) {
    text += " A connected PC that does not answer ping is usually its own firewall: Windows blocks incoming ping by default.";
  }
  note.textContent = text;
}

function pick(name) {
  picked = name;
  render();
}

function drawPath() {
  const picker = $("picker");
  picker.replaceChildren(...status.cities.filter((c) => c.name !== "milan").map((c) => {
    const b = h("button", { type: "button", "aria-pressed": String(c.name === picked), text: c.label });
    b.addEventListener("click", () => pick(c.name));
    return b;
  }));

  const path = status.paths[picked];
  const hops = $("hops");
  const note = $("path-note");
  if (!labOn() || !path) {
    $("path-from").textContent = "";
    hops.replaceChildren();
    note.textContent = "No path to show while the lab is switched off.";
    return;
  }
  $("path-from").textContent = "Traceroute from the PC in Milan site 1 (10.1.1.2):";
  hops.replaceChildren(...path.hops.map((hop) => {
    const who = hop.ip === null ? "no reply"
      : hop.node && GEO[hop.node] ? `${cityLabel(hop.node)} router`
      : hop.node && hop.node.endsWith("pc") ? `${cityLabel(status.cities.find((c) => hop.node.startsWith(c.code)).name)} site ${hop.node.charAt(3)} PC`
      : "unknown device";
    return h("li", { class: hop.ip === null ? "lost" : "" },
      h("span", { class: "ip", text: hop.ip || "*" }), h("span", { class: "who", text: who }));
  }));

  const row = status.routes.find((r) => r.city === picked);
  if (!path.complete) {
    note.textContent = `The trace did not reach ${cityLabel(picked)}: right now Milan has no working path to it.`;
  } else if (row && row.via.length > 1) {
    note.textContent = `Milan has two equal cost paths to ${cityLabel(picked)}, via ${joinCities(row.via)}. OSPF shares traffic between them; this trace shows the path one flow took.`;
  } else {
    note.textContent = "";
  }
}

function drawRoutes() {
  $("routes").tBodies[0].replaceChildren(...status.routes.map((r) => {
    const via = !labOn() ? h("span", { class: "state-off", text: "lab off" })
      : r.via.length ? document.createTextNode(joinCities(r.via))
      : h("span", { class: "state-bad", text: "no route" });
    return h("tr", {},
      h("td", { text: cityLabel(r.city) }), h("td", {}, via),
      h("td", { class: "num", text: r.cost ?? "" }), h("td", { class: "num", text: `${r.sites}/4` }));
  }));
}

function drawLinks() {
  $("links").tBodies[0].replaceChildren(...status.links.map((l) => {
    const cable = !labOn() ? h("span", { class: "state-off", text: "off" })
      : h("span", { class: l.cable === "up" ? "state-ok" : "state-bad", text: l.cable });
    const ospf = !labOn() ? h("span", { class: "state-off", text: "off" })
      : h("span", { class: l.ospf === "full" ? "state-ok" : "state-bad", text: l.ospf === "full" ? "FULL" : "down" });
    return h("tr", {},
      h("td", { text: `${cityLabel(l.a)} to ${cityLabel(l.b)}` }),
      h("td", {}, h("span", { class: "ip", text: l.subnet })),
      h("td", {}, h("span", { class: "ip", text: `${l.a_port} / ${l.b_port}` })),
      h("td", {}, cable), h("td", {}, ospf));
  }));
}

function drawSites() {
  $("sites").tBodies[0].replaceChildren(...status.cities.map((c) => h("tr", {},
    h("td", { text: c.label }),
    ...c.sites.map((st) => {
      const mk = (label, dev) => h("span", {
        class: !labOn() ? "off" : dev.ok ? "" : "fail",
        title: `${dev.ip} ${dev.ok ? "replies" : "does not reply"}`,
        text: label,
      });
      return h("td", {}, h("span", { class: "reach" }, mk("PC", st.pc), mk("Switch", st.switch)));
    }))));
}

function fmtTime(t) {
  const d = new Date(t * 1000), now = new Date();
  const time = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  return d.toDateString() === now.toDateString() ? time
    : `${d.toLocaleDateString([], { day: "numeric", month: "short" })} ${time.slice(0, 5)}`;
}

function drawEvents() {
  const list = status.events || [];
  $("events").replaceChildren(...(list.length ? list.map((e) => h("li", {},
    h("time", { datetime: new Date(e.t * 1000).toISOString(), text: fmtTime(e.t) }),
    h("span", { text: e.text }))) : [h("li", { class: "empty", text: "Nothing has changed recently." })]));
}

function drawOverall() {
  const mark = $("overall-mark"), text = $("overall-text"), sub = $("overall-sub");
  if (!status) {
    mark.className = "mark warn";
    text.textContent = "Status not available";
    sub.textContent = "The status file could not be loaded. It is retried every 10 seconds.";
    return;
  }
  const age = Math.max(0, Math.round(Date.now() / 1000 - status.generated));
  const ageText = age < 60 ? `${age} s ago` : age < 3600 ? `${Math.round(age / 60)} min ago` : `${Math.round(age / 3600)} h ago`;
  if (!labOn()) {
    mark.className = "mark";
    text.textContent = "The lab is switched off";
    sub.textContent = `The routers are not running right now. Checked ${ageText}.`;
    return;
  }
  const pcs = status.cities.flatMap((c) => c.sites).filter((st) => st.pc.ok).length;
  const up = status.links.filter((l) => l.cable === "up" && l.ospf === "full").length;
  const ring = status.links.length;
  mark.className = `mark ${pcs === 0 ? "bad" : pcs < 24 || up < ring ? "warn" : "ok"}`;
  text.textContent = pcs === 24 ? "All 24 sites reachable from Milan" : `${pcs} of 24 sites reachable from Milan`;
  const ringText = up === ring ? `All ${ring} ring cables up.`
    : up === ring - 1 ? `${up} of ${ring} ring cables up: the ring has no backup path right now.`
    : `${up} of ${ring} ring cables up: part of the network is cut off.`;
  const online = remote().peers.filter((p) => p.connected).length;
  const remoteText = online ? ` ${online} remote PC${online > 1 ? "s" : ""} connected over WireGuard.` : "";
  sub.replaceChildren(document.createTextNode(`${ringText}${remoteText} Updated ${ageText}.`));
  if (age > STALE_S || fetchError) {
    sub.append(" ", h("span", { class: "problem", text: "The data is not refreshing: the status collector may be stopped." }));
  }
}

function render() {
  drawOverall();
  if (!status) return;
  drawMap();
  drawPath();
  drawRoutes();
  drawRemote();
  drawLinks();
  drawSites();
  drawEvents();
}

async function load() {
  try {
    const r = await fetch("status.json", { cache: "no-store" });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    status = await r.json();
    fetchError = false;
  } catch (e) {
    fetchError = true;
  }
  render();
}

load();
setInterval(load, REFRESH_MS);
setInterval(drawOverall, 1000);
