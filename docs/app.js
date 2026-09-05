// WASM SQLite persona reflex demo. Loads persona.sqlite via HTTP range
// fetch (page-by-page, no full download), runs reflex queries in-browser.

let db = null;
let bytesFetched = 0, reqCount = 0;

const $ = (id) => document.getElementById(id);
const log = (html) => { const l = $("log"); l.innerHTML = html + l.innerHTML; };

async function rangeFetch(url) {
  // sql.js can't page-fault on its own; grab the whole (small) DB in
  // one Range GET. Server advertises Accept-Ranges: bytes so this IS
  // a range request (bytes=0-), just for the whole file. For a large
  // DB, swap to sqlite-wasm's OPFS/HttpVfs which pages on demand.
  const resp = await fetch(url, { headers: { Range: "bytes=0-" } });
  reqCount++; $("req_count").textContent = reqCount;
  const buf = await resp.arrayBuffer();
  bytesFetched += buf.byteLength; $("bytes_fetched").textContent = bytesFetched;
  return new Uint8Array(buf);
}

async function boot() {
  $("boot").textContent = "…loading sqlite-wasm…";
  const SQL = await initSqlJs({
    locateFile: (f) => `https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.10.3/${f}`
  });
  $("boot").textContent = "…fetching persona.sqlite via HTTP range…";
  const bytes = await rangeFetch("fixtures/persona.sqlite");
  db = new SQL.Database(bytes);
  $("boot").innerHTML = `<span style="color:#00c8b3">ready.</span> WASM SQLite loaded ${bytes.length.toLocaleString()} B fixture over ${reqCount} range GET(s).`;
  render();
  renderReaders();
}

function reflex(persona, stimulus) {
  const state = queryMap(
    "SELECT pointer, value FROM persona_state WHERE persona_id = ?",
    [persona]);
  state["_stimulus"] = stimulus;

  const rows = db.exec(
    "SELECT action_name, precondition_json, effect_json FROM persona_actions " +
    "WHERE persona_id = ? ORDER BY priority DESC, action_name",
    [persona]);
  if (!rows[0]) return null;

  for (const row of rows[0].values) {
    const [name, preJson, effJson] = row;
    const pre = JSON.parse(preJson);
    const ok = Object.entries(pre).every(([k, v]) => String(v) === state[k]);
    if (!ok) continue;
    const eff = JSON.parse(effJson);
    for (const [k, v] of Object.entries(eff)) {
      db.run("INSERT OR REPLACE INTO persona_state VALUES (?,?,?)",
             [persona, k, String(v)]);
    }
    return { action: name, effect: eff };
  }
  return null;
}

function queryMap(sql, params) {
  const rows = db.exec(sql, params);
  const out = {};
  if (rows[0]) for (const [k, v] of rows[0].values) out[k] = v;
  return out;
}

function expandReaders(object) {
  // Zanzibar-style recursive CTE — the same shape the Elixir engine runs,
  // right here in the browser.
  const rows = db.exec(`
    WITH RECURSIVE reach(object, relation) AS (
      SELECT ?, 'reader'
      UNION
      SELECT
        substr(r.userset, 1, instr(r.userset, '#') - 1),
        substr(r.userset, instr(r.userset, '#') + 1)
      FROM relationships r
      JOIN reach ON r.object = reach.object AND r.relation = reach.relation
      WHERE instr(r.userset, '#') > 0
    )
    SELECT DISTINCT r.userset
    FROM relationships r
    JOIN reach ON r.object = reach.object AND r.relation = reach.relation
    WHERE instr(r.userset, '#') = 0
    ORDER BY r.userset
  `, [object]);
  return rows[0] ? rows[0].values.map(r => r[0]) : [];
}

function render() {
  for (const p of ["traveler", "guide"]) {
    const st = queryMap("SELECT pointer, value FROM persona_state WHERE persona_id = ?", [p]);
    const el = $("s_" + p);
    el.innerHTML = "";
    for (const [k, v] of Object.entries(st)) {
      el.innerHTML += `<span class="k">${k}</span><span>${v}</span>`;
    }
  }
}

function renderReaders() {
  $("readers").innerHTML = expandReaders("world").map(s => `<code>${s}</code>`).join(" ");
}

function reset() {
  db.run("UPDATE persona_state SET value=? WHERE pointer=?", ["day", "hour"]);
  db.run("DELETE FROM persona_state WHERE pointer NOT IN ('hour')");
  log(`<div class="dim">— reset —</div>`);
  render();
}

function say(stim) {
  if (!db) return;
  // Guide reflex first; fall back to _unmatched if no keyed match.
  let r = reflex("guide", stim);
  if (!r) r = reflex("guide", "_unmatched");
  const line = r?.effect?.speech ?? "…";
  const box = $("vn_line");
  box.innerHTML = `<span class="guide">guide:</span> ${line}`;
  if ($("tts_on")?.checked && window.speechSynthesis) {
    speechSynthesis.cancel();
    speechSynthesis.speak(new SpeechSynthesisUtterance(line));
  }
  if (window.__vrm_reflex_cue) window.__vrm_reflex_cue("guide", r?.action ?? "speak");
  render();
}

document.addEventListener("click", (e) => {
  const sayStim = e.target?.dataset?.say;
  if (sayStim) { say(sayStim); return; }
  const stim = e.target?.dataset?.stim;
  if (!stim || !db) return;
  if (stim === "__night") {
    db.run("UPDATE persona_state SET value=? WHERE pointer=?", ["night", "hour"]);
    log(`<div class="dim">→ hour = night</div>`);
    render();
    return;
  }
  if (stim === "__reset") { reset(); return; }

  const lines = [];
  for (const p of ["traveler", "guide"]) {
    const r = reflex(p, stim);
    if (r) {
      lines.push(
        `<span class="${p}">${p}</span> ← <span class="dim">${stim}</span> → ` +
        `<span class="action">${r.action}</span> ` +
        `<span class="dim">${JSON.stringify(r.effect)}</span>`);
      if (window.__vrm_reflex_cue) window.__vrm_reflex_cue(p, r.action);
    }
  }
  log(`<div>${lines.join("<br>") || `<span class="dim">(no match: ${stim})</span>`}</div>`);
  render();
});

boot().catch(e => { $("boot").textContent = "boot failed: " + e.message; });
