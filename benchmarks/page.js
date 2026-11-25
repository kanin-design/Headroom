// Headroom's benchmark page: the record (results.jsonl) and the log (log.jsonl), as data.js holds them. Four views, each
// with an address of its own so it can be linked: #metrics (and #metrics/<name> with its chart), #log, #runs,
// #compare/<run>/<run>.

const data = window.BENCHMARKS || { catalogue: {}, records: [], log: [] };
const cat = data.catalogue;
const log = data.log || [];
const tip = document.getElementById("tip");
const shownVerdict = v => (data.verdicts || {})[v] || v;
const shownSource = s => ({ noted: "documented", logged: "logged" })[s] || s;

// In the order the code was written: by commit date, a working tree after its commit, then by when it was run.
const records = data.records.slice().sort((a, b) =>
  (a.committed || "").localeCompare(b.committed || "") || ((a.dirty ? 1 : 0) - (b.dirty ? 1 : 0)) || a.when.localeCompare(b.when));
const ids = new Set();
for (const r of records) {
  let id = `${r.when.slice(0, 16)}~${(r.commit || "none").slice(0, 7)}${r.dirty ? "+" : ""}`;
  while (ids.has(id)) id += "'";
  ids.add(id);
  r.id = id;
}
const byId = Object.fromEntries(records.map(r => [r.id, r]));

// MARK: What a record and a metric are

const isRun = r => (r.source || "run") === "run";
// Taken while something else used the Mac: its timings can't be judged against another run's.
const isBusy = r => !!((r.environment && r.environment.busy) || r.busy);
// Made with the screen locked or the display asleep: nothing was drawn, so memory reads lower and short work slower.
const screenOff = r => !!(r.environment && r.environment.screen && r.environment.screen !== "on");
const screenText = r => r.environment.screen === "locked" ? "screen locked" : "display asleep";
const runs = records.filter(isRun);
const history = records.filter(r => !isRun(r));

function info(name) {
  return cat[name] || { unit: "ms", better: "lower", group: name.split(".")[0], what: name, noted: null };
}
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const what = name => esc(info(name).what).replace(/`([^`]+)`/g, "<code>$1</code>");
const range = m => m.n > 1 && m.min !== m.max ? `${fmt(m.min)}–${fmt(m.max)}` : "";
function fmt(v, unit) {
  if (v == null) return "–";
  const a = Math.abs(v);
  // Counts are whole; a time or a size keeps its decimals, so "7.00 ms" sits beside "7.90 ms".
  const s = Number.isInteger(v) && (!unit || unit === "frames") ? String(v) : a >= 100 ? v.toFixed(0) : a >= 10 ? v.toFixed(1) : a >= 1 ? v.toFixed(2) : v.toFixed(3);
  return s + (unit ? " " + unit : "");
}
const short = r => r.commit ? r.commit.slice(0, 7) + (r.dirty ? "+" : "") : "–";
const day = r => r.when.slice(0, 10);
const series = name => records.filter(r => r.metrics[name]).map(r => ({ r, m: r.metrics[name] }));
const measured = name => series(name).filter(p => isRun(p.r));

/// Worse or better beyond noise: more than 10% apart and the two runs' ranges don't overlap. Two runs taken apart, one of
/// them on a busy Mac, can't be judged; two alternated in one session can, as they shared whatever the Mac was doing. Nor
/// can two taken apart where only one had the screen on, memory included.
function verdict(name, now, before, a, b) {
  if (!now || !before || !before.median) return { cls: "same", text: "" };
  const change = (now.median - before.median) / before.median * 100;
  const text = (change > 0 ? "+" : "") + change.toFixed(0) + "%";
  const together = a && b && a.when === b.when;
  if (a && b && !together && screenOff(a) !== screenOff(b)) return { cls: "screentext", text, busy: true, note: "display off" };
  if (a && b && !together && (isBusy(a) || isBusy(b)) && info(name).unit !== "MB") return { cls: "busytext", text, busy: true, note: "under load" };
  const apart = Math.abs(change) > 10 && (now.min > before.max || now.max < before.min);
  const worse = info(name).better === "lower" ? change > 0 : change < 0;
  return { cls: apart ? (worse ? "worse" : "better") : "same", text };
}

function others(r) {
  const e = r.environment;
  if (!e) return r.busy ? r.busy.join(", ") : "";
  const list = (e.others || []).map(o => `${o.name} ${o.cpu}%`).join(", ");
  return [screenOff(r) ? screenText(r) : "", list || "no other process above 20% CPU", e.load && e.load.length ? `load ${e.load[0]}–${e.load[1]}` : "", e.power,
    e.thermal && e.thermal !== "nominal" ? "thermal " + e.thermal : "", e.low_power ? "Low Power Mode" : ""].filter(Boolean).join(" · ");
}

// MARK: Charts

/// A metric over every record: runs filled, numbers from before the suite hollow, a run on a busy Mac ringed in yellow, one
/// with nothing on screen ringed in blue, and
/// a flag wherever the log says something about it.
function chart(name, width, height, big) {
  const pts = series(name), noted = info(name).noted;
  if (!pts.length) return "";
  const pad = big ? { l: 52, r: 36, t: 30, b: 34 } : { l: 2, r: 2, t: 3, b: 3 };
  let lo = Math.min(...pts.map(p => p.m.min)), hi = Math.max(...pts.map(p => p.m.max));
  if (noted != null && big) { lo = Math.min(lo, noted); hi = Math.max(hi, noted); }
  if (hi === lo) { hi += Math.abs(hi) * 0.1 + 1; lo -= Math.abs(lo) * 0.1; }
  const span = hi - lo; lo -= span * 0.08; hi += span * 0.08;
  const x = i => pad.l + (pts.length === 1 ? (width - pad.l - pad.r) / 2 : i * (width - pad.l - pad.r) / (pts.length - 1));
  const y = v => pad.t + (1 - (v - lo) / (hi - lo)) * (height - pad.t - pad.b);
  let s = `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`;
  if (big) {
    for (let k = 0; k <= 4; k++) {
      const v = lo + (hi - lo) * k / 4;
      s += `<line x1="${pad.l}" x2="${width - pad.r}" y1="${y(v)}" y2="${y(v)}" stroke="#26262d"/>`;
      s += `<text x="${pad.l - 6}" y="${y(v) + 3}" text-anchor="end">${fmt(v)}</text>`;
    }
    if (noted != null) {
      s += `<line x1="${pad.l}" x2="${width - pad.r}" y1="${y(noted)}" y2="${y(noted)}" stroke="var(--noted)" stroke-dasharray="4 4"/>`;
      s += `<text x="${width - pad.r}" y="${y(noted) - 4}" text-anchor="end">reference (DESIGN.md)</text>`;
    }
    // The log's word on this metric, at the first record on or after its date.
    // At its commit when the metric was measured there ("after abc1234" is that commit's working tree), else at the
    // first record on or after its date; several at one point stack.
    const stacked = {};
    log.forEach((e, k) => {
      if (!e.metrics.includes(name)) return;
      const after = (e.commit || "").startsWith("after "), commit = (e.commit || "").replace("after ", "");
      // A working tree changes after its commit, so an "after" entry speaks of its latest run there.
      const there = p => p.r.commit && p.r.commit.startsWith(commit) && !!p.r.dirty === after;
      let at = !commit ? -1 : after ? pts.findLastIndex(there) : pts.findIndex(there);
      if (at < 0) at = pts.findIndex(p => day(p.r) >= e.date);
      if (at < 0) at = pts.length - 1;
      const row = stacked[at] = (stacked[at] || 0) + 1;
      const top = pad.t - 12 + (row - 1) * 8;
      if (row === 1) s += `<line x1="${x(at)}" x2="${x(at)}" y1="${pad.t - 10}" y2="${height - pad.b}" stroke="var(--line)" stroke-dasharray="2 3"/>`;
      s += `<path d="M${x(at)} ${top} l7 3.5 l-7 3.5 z" fill="${e.verdict === "open" ? "var(--worse)" : e.verdict === "proposal" ? "var(--accent)" : "var(--soft)"}" data-log="${k}"/>`;
    });
  }
  s += `<polyline fill="none" stroke="var(--accent)" stroke-opacity=".7" stroke-width="${big ? 2 : 1.5}" points="${pts.map((p, i) => x(i) + "," + y(p.m.median)).join(" ")}"/>`;
  pts.forEach((p, i) => {
    const before = pts.slice(0, i).reverse().find(q => isRun(q.r));
    const v = isRun(p.r) && before ? verdict(name, p.m, before.m, p.r, before.r) : { cls: "same" };
    const colour = v.cls === "worse" ? "var(--worse)" : v.cls === "better" ? "var(--better)" : "var(--accent)";
    if (big) s += `<line x1="${x(i)}" x2="${x(i)}" y1="${y(p.m.min)}" y2="${y(p.m.max)}" stroke="${colour}" stroke-opacity=".5" stroke-width="3"/>`;
    const r = big ? 4 : 2;
    const look = !isRun(p.r) ? `fill="var(--bg)" stroke="${colour}" stroke-width="1.5"`
      : screenOff(p.r) ? `fill="${colour}" stroke="var(--screen)" stroke-width="2"`
      : isBusy(p.r) ? `fill="${colour}" stroke="var(--busy)" stroke-width="2"` : `fill="${colour}"`;
    s += `<circle cx="${x(i)}" cy="${y(p.m.median)}" r="${r}" ${look} data-name="${name}" data-id="${p.r.id}"/>`;
    if (big) s += `<text x="${x(i)}" y="${height - 18}" text-anchor="middle">${short(p.r)}</text><text x="${x(i)}" y="${height - 6}" text-anchor="middle">${p.r.when.slice(5, 10)}</text>`;
  });
  return s + "</svg>";
}

// MARK: Pieces shared by the views

const tag = e => `<span class="tag v-${e.verdict.replace(" ", "-")}">${esc(shownVerdict(e.verdict))}</span>`;
const metricLink = n => `<a class="metric-link" href="#metrics/${encodeURIComponent(n)}">${esc(n)}</a>`;
function card(e) {
  return `<div class="card"><div class="top">${tag(e)}${e.source === "history" ? ` <span class="tag">historical</span>` : ""}
    <span class="meta">${esc(e.date)}${e.commit ? " · " + esc(e.commit) : ""}${e.branch ? " on " + esc(e.branch) : ""}</span> ${e.metrics.map(metricLink).join(" ")}</div>
    <div class="moved">${esc(e.moved)}</div><div class="why">${esc(e.why)}</div></div>`;
}
const groupsOf = names => {
  const known = ["Launch", "Memory", "Search", "Rendering", "Checks", "Microbenchmarks"];
  const present = new Set(names.map(n => info(n).group));
  return [...known.filter(g => present.has(g)), ...[...present].filter(g => !known.includes(g))];
};

// MARK: Metrics

const state = { group: "All", changed: false, open: false, find: "" };

function metricsView(opened) {
  const names = [...new Set(records.flatMap(r => Object.keys(r.metrics)))];
  const openNames = new Set(log.filter(e => e.verdict === "open" || e.verdict === "proposal").flatMap(e => e.metrics));
  const groups = groupsOf(names);
  let rows = "";
  for (const g of groups) {
    if (state.group !== "All" && g !== state.group) continue;
    let body = "";
    const order = n => (measured(n).length ? "0" : "1") + n;
    for (const n of names.filter(n => info(n).group === g).sort((a, b) => order(a).localeCompare(order(b)))) {
      const i = info(n);
      if (state.find && !(n + " " + i.what).toLowerCase().includes(state.find.toLowerCase())) continue;
      if (state.open && !openNames.has(n)) continue;
      const s = measured(n), now = s[s.length - 1], before = s[s.length - 2];
      const v = verdict(n, now && now.m, before && before.m, now && now.r, before && before.r);
      if (state.changed && (v.cls === "same" || v.busy)) continue;
      const last = series(n).slice(-1)[0];
      const latest = now ? fmt(now.m.median, i.unit) : `<span class="same">${fmt(last.m.median, i.unit)} ${esc(shownSource(last.r.source))}</span>`;
      const flags = log.filter(e => e.metrics.includes(n) && (e.verdict === "open" || e.verdict === "proposal"));
      body += `<tr class="click" data-metric="${n}"><td><div class="name">${what(n)} ${flags.map(tag).join(" ")}</div><div class="key">${esc(n)}</div></td>
        <td>${chart(n, 140, 30, false)}</td><td class="num">${latest}</td>
        <td class="num ${v.cls}">${v.note ? v.note + " " : ""}${v.text}</td>
        <td class="num">${before ? fmt(before.m.median, i.unit) : "–"}</td>
        <td class="num">${i.noted != null ? fmt(i.noted, i.unit) : ""}</td></tr>`;
      if (opened === n) {
        const notes = log.filter(e => e.metrics.includes(n));
        body += `<tr class="detail"><td colspan="6">${chart(n, Math.min(document.body.clientWidth - 110, 1100), 250, true)}
          ${notes.length ? `<div class="flags">${notes.map(e => `<div class="flag">${tag(e)} <b>${esc(e.moved)}</b> · ${esc(e.why)} <span class="meta">${esc(e.date)}${e.commit ? " · " + esc(e.commit) : ""}</span></div>`).join("")}</div>` : ""}</td></tr>`;
      }
    }
    if (body) rows += `<tr class="group"><td colspan="6">${g}</td></tr>` + body;
  }
  return `<div class="bar">${["All", ...groups].map(g => `<button class="${g === state.group ? "on" : ""}" data-group="${g}">${g}</button>`).join("")}
      <label><input type="checkbox" data-toggle="changed" ${state.changed ? "checked" : ""}> Changed only</label>
      <label><input type="checkbox" data-toggle="open" ${state.open ? "checked" : ""}> Open items only</label>
      <input type="search" placeholder="Filter metrics" value="${esc(state.find)}" id="find"></div>
    <main><table><thead><tr><th>Metric</th><th>History</th><th class="num">Latest</th><th class="num">Change</th>
      <th class="num">Previous</th><th class="num">Reference</th></tr></thead><tbody>${rows || `<tr><td colspan="6" class="empty">No matching metrics.</td></tr>`}</tbody></table></main>`;
}

// MARK: Log

let logFilter = "All";

function logView() {
  const shown = e => logFilter === "All" || e.verdict === logFilter;
  const open = log.filter(e => (e.verdict === "open" || e.verdict === "proposal") && shown(e));
  const done = log.filter(e => e.verdict !== "open" && e.verdict !== "proposal" && shown(e))
    .map((e, k) => ({ e, k })).sort((a, b) => b.e.date.localeCompare(a.e.date) || b.k - a.k).map(x => x.e);
  const verdicts = ["All", ...new Set(log.map(e => e.verdict))];
  return `<div class="bar">${verdicts.map(v => `<button class="${v === logFilter ? "on" : ""}" data-verdict="${v}">${v === "All" ? v : esc(shownVerdict(v))}</button>`).join("")}</div>
    <main>${open.length ? `<h2>Open <span class="count">${open.length}</span></h2><div class="cards">${open.map(card).join("")}</div>` : ""}
    ${done.length ? `<h2>Resolved <span class="count">${done.length}</span></h2><div class="cards">${done.map(card).join("")}</div>` : ""}
    ${!open.length && !done.length ? `<p class="empty">No entries${logFilter === "All" ? "" : " with this verdict"}.</p>` : ""}
    <p class="env">Source: <code>benchmarks/log.jsonl</code>. After editing it, run <code>benchmarks/run.py --log</code>.</p></main>`;
}

// MARK: Runs

const picked = [];

function runsView(opened) {
  const rows = records.slice().sort((a, b) => b.when.localeCompare(a.when)).map(r => {
    const kind = !isRun(r) ? `<span class="tag">${esc(shownSource(r.source))}</span>`
      : (screenOff(r) ? `<span class="tag screen">display off</span> ` : "") + (isBusy(r) ? `<span class="tag busy">under load</span>` : screenOff(r) ? "" : `<span class="tag">run</span>`);
    let html = `<tr class="click" data-run="${esc(r.id)}"><td><input type="checkbox" data-pick="${esc(r.id)}" ${picked.includes(r.id) ? "checked" : ""}></td>
      <td class="when">${r.when.replace("T", " ").slice(0, 16)}</td><td><code>${short(r)}</code></td><td>${kind}</td>
      <td>${esc(r.subject || "no commit")}${r.label ? `<div class="label">${esc(r.label)}</div>` : ""}${r.evidence ? `<div class="env">Source: ${esc(r.evidence)}</div>` : ""}
      ${isRun(r) ? `<div class="env">${esc(others(r))}</div>` : ""}</td>
      <td class="num">${Object.keys(r.metrics).length}</td></tr>`;
    if (opened === r.id) {
      const names = Object.keys(r.metrics);
      html += `<tr class="detail"><td colspan="6"><table>${groupsOf(names).map(g => `<tr class="group"><td colspan="3">${g}</td></tr>` +
        names.filter(n => info(n).group === g).sort().map(n => { const m = r.metrics[n], i = info(n);
          return `<tr><td>${what(n)} <span class="key">${esc(n)}</span></td><td class="num">${fmt(m.median, i.unit)}</td>
            <td class="num same">${range(m) ? `${range(m)}, n = ${m.n}` : ""}</td></tr>`; }).join("")).join("")}</table></td></tr>`;
    }
    return html;
  }).join("");
  return `<div class="bar"><span class="sub">Select two runs to compare.</span>
      <button data-compare ${picked.length === 2 ? "" : "disabled"}>Compare ${picked.length}/2</button></div>
    <main><table><thead><tr><th></th><th>Date</th><th>Commit</th><th>Type</th><th>Description</th><th class="num">Metrics</th></tr></thead>
    <tbody>${rows}</tbody></table></main>`;
}

// MARK: Compare

function compareView(aId, bId) {
  const latest = runs.slice(-2);
  const a = byId[aId] || latest[0], b = byId[bId] || latest[1];
  if (!a || !b) return `<main><p class="empty">Not enough runs to compare.</p></main>`;
  const pick = (which, sel) => `<select data-side="${which}">${records.slice().reverse().map(r =>
    `<option value="${esc(r.id)}" ${r === sel ? "selected" : ""}>${r.when.slice(0, 16).replace("T", " ")} · ${short(r)} · ${esc(isRun(r) ? (r.label || r.subject) : shownSource(r.source) + ": " + r.label).slice(0, 70)}</option>`).join("")}</select>`;
  const names = Object.keys(a.metrics).filter(n => b.metrics[n]);
  let worse = 0, better = 0, rows = "";
  for (const g of groupsOf(names)) {
    rows += `<tr class="group"><td colspan="5">${g}</td></tr>`;
    for (const n of names.filter(n => info(n).group === g).sort()) {
      const i = info(n), v = verdict(n, b.metrics[n], a.metrics[n], b, a);
      if (v.cls === "worse") worse++; if (v.cls === "better") better++;
      const cell = m => `${fmt(m.median, i.unit)}${range(m) ? ` <span class="same">${range(m)}</span>` : ""}`;
      rows += `<tr class="click" data-metric="${n}"><td>${what(n)} <span class="key">${esc(n)}</span></td><td class="num">${cell(a.metrics[n])}</td>
        <td class="num">${cell(b.metrics[n])}</td><td class="num ${v.cls}">${v.note ? v.note + " " : ""}${v.text}</td>
        <td class="num ${v.cls}">${v.cls === "worse" ? "regression" : v.cls === "better" ? "improvement" : ""}</td></tr>`;
    }
  }
  const together = a.when === b.when;
  const note = !isRun(a) || !isRun(b) ? "One side is a historical data point, measured another way: not comparable."
    : together ? "Interleaved runs: both had the same system conditions."
    : screenOff(a) !== screenOff(b) ? "Separate runs, one with the display off (memory about 190 MB lower, short tasks slower): not judged."
    : isBusy(a) || isBusy(b) ? "Separate runs, one under load: timings not judged, memory and sizes only."
    : "Separate runs: system conditions may differ. For a verdict, run both interleaved with --compare.";
  return `<div class="bar">${pick("a", a)} → ${pick("b", b)}</div>
    <main><div class="split"><div class="card"><b>Baseline</b><div>${esc(a.label || a.subject)}</div><div class="env">${esc(others(a) || a.evidence || "")}</div></div>
      <div class="card"><b>Candidate</b><div>${esc(b.label || b.subject)}</div><div class="env">${esc(others(b) || b.evidence || "")}</div></div></div>
    <p class="sub"><span class="worse">${worse} regression${worse === 1 ? "" : "s"}</span> · <span class="better">${better} improvement${better === 1 ? "" : "s"}</span> outside noise, ${names.length} metrics compared. ${note}</p>
    <table><thead><tr><th>Metric</th><th class="num">Baseline</th><th class="num">Candidate</th><th class="num">Change</th><th class="num"></th></tr></thead>
    <tbody>${rows}</tbody></table></main>`;
}

// MARK: Routing and events

function render() {
  const [view = "metrics", ...rest] = location.hash.slice(1).split("/").map(decodeURIComponent);
  const openCount = log.filter(e => e.verdict === "open" || e.verdict === "proposal").length;
  // The newest run by time: runs are in code order, and a working tree's run sorts under its HEAD commit.
  const newest = runs.reduce((a, b) => (b.when > a.when ? b : a), runs[0]);
  document.getElementById("sub").textContent = runs.length
    ? `${runs.length} runs · ${history.length} historical · ${newest.machine.chip}, ${newest.machine.cores}, macOS ${newest.machine.macos} · last run ${day(newest)}`
    : "No runs. Run benchmarks/run.py.";
  document.getElementById("tabs").innerHTML = [["metrics", "Metrics"], ["log", "Log", openCount ? `${openCount} open` : ""], ["runs", "Runs", records.length], ["compare", "Compare"]]
    .map(([id, title, count]) => `<a href="#${id}" class="${view === id ? "on" : ""}">${title}${count ? `<span class="count">${count}</span>` : ""}</a>`).join("");
  const el = document.getElementById("view");
  el.innerHTML = view === "log" ? logView() : view === "runs" ? runsView(rest[0]) : view === "compare" ? compareView(rest[0], rest[1]) : metricsView(rest[0]);
}

document.addEventListener("click", e => {
  const t = e.target;
  if (t.dataset.group) { state.group = t.dataset.group; render(); return; }
  if (t.dataset.verdict) { logFilter = t.dataset.verdict; render(); return; }
  if (t.dataset.toggle) { state[t.dataset.toggle] = t.checked; render(); return; }
  if (t.dataset.pick !== undefined) {
    const id = t.dataset.pick, at = picked.indexOf(id);
    if (at >= 0) picked.splice(at, 1); else { picked.push(id); if (picked.length > 2) picked.shift(); }
    render(); return;
  }
  if (t.closest("[data-compare]") && picked.length === 2) {
    const [x, y] = picked.map(id => byId[id]).sort((p, q) => records.indexOf(p) - records.indexOf(q));
    location.hash = `compare/${encodeURIComponent(x.id)}/${encodeURIComponent(y.id)}`; return;
  }
  if (t.closest("a, select, input")) return;
  const metric = t.closest("tr[data-metric]");
  if (metric) {
    const [view, open] = location.hash.slice(1).split("/").map(decodeURIComponent);
    location.hash = view === "metrics" && open === metric.dataset.metric ? "metrics" : `metrics/${encodeURIComponent(metric.dataset.metric)}`;
    return;
  }
  const run = t.closest("tr[data-run]");
  if (run) {
    const [, open] = location.hash.slice(1).split("/").map(decodeURIComponent);
    location.hash = open === run.dataset.run ? "runs" : `runs/${encodeURIComponent(run.dataset.run)}`;
  }
});
document.addEventListener("change", e => {
  const side = e.target.dataset.side;
  if (!side) return;
  const [, a, b] = location.hash.slice(1).split("/").map(decodeURIComponent);
  const latest = runs.slice(-2);
  const pair = [a || latest[0].id, b || latest[1].id];
  pair[side === "a" ? 0 : 1] = e.target.value;
  location.hash = `compare/${encodeURIComponent(pair[0])}/${encodeURIComponent(pair[1])}`;
});
document.addEventListener("input", e => {
  if (e.target.id !== "find") return;
  state.find = e.target.value;
  const at = e.target.selectionStart;
  render();
  const box = document.getElementById("find");
  box.focus(); box.setSelectionRange(at, at);
});
document.addEventListener("mousemove", e => {
  const c = e.target.closest("circle[data-id]"), f = e.target.closest("path[data-log]");
  if (f) {
    const entry = log[+f.dataset.log];
    tip.innerHTML = `${tag(entry)} <b>${esc(entry.moved)}</b><div>${esc(entry.why)}</div><div>${esc(entry.date)}${entry.commit ? " · " + esc(entry.commit) : ""}</div>`;
  } else if (c) {
    const r = byId[c.dataset.id], m = r.metrics[c.dataset.name], i = info(c.dataset.name);
    tip.innerHTML = `<b>${fmt(m.median, i.unit)}</b> <span class="same">${isRun(r) ? (range(m) ? `(${range(m)}, n = ${m.n})` : "") : esc(shownSource(r.source))}</span>
      ${screenOff(r) ? `<div class="screentext">Display off (${screenText(r)}): memory reads lower, short tasks slower</div>` : ""}
      ${isBusy(r) ? `<div class="busytext">Under load: ${esc(others(r))}</div>` : ""}
      <div><code>${short(r)}</code> ${esc(r.subject || "")}</div>${r.label ? `<div>${esc(r.label)}</div>` : ""}${r.evidence ? `<div>Source: ${esc(r.evidence)}</div>` : ""}
      <div>${r.when.replace("T", " ").slice(0, 16)}</div>`;
  } else { tip.style.display = "none"; return; }
  tip.style.display = "block";
  tip.style.left = Math.min(e.clientX + 14, innerWidth - 400) + "px";
  tip.style.top = (e.clientY + 14) + "px";
});
addEventListener("hashchange", render);
addEventListener("resize", () => location.hash.includes("/") && render());
render();
