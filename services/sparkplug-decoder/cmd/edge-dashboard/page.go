package main

// indexHTML is the entire board — one self-contained document. No external
// fonts, scripts, or stylesheets: when this page matters there is NO internet,
// so every byte must ship from the box. It polls /api/state and re-renders a
// per-machine view, computing freshness against the server clock the API
// echoes back (the panel's own clock is not to be trusted).
const indexHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Packiot — On-Prem Live Board</title>
<style>
  :root {
    --bg: #0d1117; --panel: #161b22; --panel-2: #1c232c;
    --ink: #e6edf3; --muted: #8b949e; --line: #30363d;
    --live: #3fb950; --stale: #d29922; --dead: #f85149;
    --accent: #58a6ff;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: var(--bg); color: var(--ink);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  .num { font-variant-numeric: tabular-nums;
    font-family: ui-monospace, "SF Mono", "Cascadia Code", Menlo, Consolas, monospace; }
  header { position: sticky; top: 0; z-index: 5; background: var(--panel);
    border-bottom: 1px solid var(--line); padding: 14px 20px;
    display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
  header .title { font-weight: 700; letter-spacing: .3px; font-size: 18px; }
  header .tenant { color: var(--accent); text-transform: uppercase; letter-spacing: .5px; }
  .pill { display: inline-flex; align-items: center; gap: 8px;
    padding: 6px 12px; border-radius: 999px; font-weight: 700; font-size: 13px;
    letter-spacing: .4px; text-transform: uppercase; }
  .pill .dot { width: 9px; height: 9px; border-radius: 50%; }
  .pill.live  { background: rgba(63,185,80,.14);  color: var(--live); }
  .pill.live .dot  { background: var(--live); box-shadow: 0 0 0 0 rgba(63,185,80,.6);
    animation: pulse 1.8s infinite; }
  .pill.stale { background: rgba(210,153,34,.14); color: var(--stale); }
  .pill.stale .dot { background: var(--stale); }
  .pill.dead  { background: rgba(248,81,73,.14);  color: var(--dead); }
  .pill.dead .dot  { background: var(--dead); }
  @keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(63,185,80,.5); }
    70% { box-shadow: 0 0 0 8px rgba(63,185,80,0); } 100% { box-shadow: 0 0 0 0 rgba(63,185,80,0); } }
  header .spacer { flex: 1; }
  header .clock { color: var(--muted); font-size: 13px; }
  .banner { background: rgba(248,81,73,.10); color: var(--dead);
    border-bottom: 1px solid var(--line); padding: 8px 20px; font-size: 13px;
    font-weight: 600; display: none; }
  .banner.show { display: block; }
  main { padding: 20px; display: grid; gap: 16px;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); }
  .card { background: var(--panel); border: 1px solid var(--line);
    border-radius: 10px; overflow: hidden; }
  .card.stale { opacity: .62; }
  .card h2 { margin: 0; padding: 12px 14px; font-size: 14px; font-weight: 700;
    border-bottom: 1px solid var(--line); background: var(--panel-2);
    display: flex; align-items: center; gap: 8px; word-break: break-all; }
  .card h2 .sdot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 8px 14px; border-top: 1px solid var(--line); font-size: 14px; vertical-align: baseline; }
  tr:first-child td { border-top: none; }
  td.metric { color: var(--muted); }
  td.value { text-align: right; font-weight: 700; }
  td.value .sub { display: block; color: var(--muted); font-weight: 400; font-size: 11px; }
  .age { color: var(--muted); font-size: 11px; }
  .empty { color: var(--muted); padding: 40px 20px; text-align: center;
    grid-column: 1 / -1; }
  footer { color: var(--muted); font-size: 12px; padding: 8px 20px 24px;
    text-align: center; }
</style>
</head>
<body>
<header>
  <span class="title">Packiot <span class="tenant" id="tenant">—</span> Live Board</span>
  <span id="status" class="pill dead"><span class="dot"></span><span id="status-text">connecting</span></span>
  <span class="spacer"></span>
  <span class="clock" id="clock">—</span>
</header>
<div class="banner" id="banner"></div>
<main id="grid"><div class="empty" id="empty">Waiting for the first reading…</div></main>
<footer>On-prem live-state — served from this box. Cloud remains the system of record; this view keeps working with no internet.</footer>

<script>
(function () {
  var STALE_MS = 30000; // overwritten by the API's stale_seconds
  var grid = document.getElementById('grid');
  var statusEl = document.getElementById('status');
  var statusText = document.getElementById('status-text');
  var banner = document.getElementById('banner');

  function setStatus(kind, text) {
    statusEl.className = 'pill ' + kind;
    statusText.textContent = text;
  }
  function fmtAge(ms) {
    var s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + 's ago';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    return Math.floor(m / 60) + 'h ago';
  }
  function esc(v) { return String(v).replace(/[&<>"]/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  function render(data) {
    STALE_MS = (data.stale_seconds || 30) * 1000;
    document.getElementById('tenant').textContent = data.tenant || '';
    var now = data.now_millis;

    // Group rows by source (machine).
    var groups = {};
    (data.rows || []).forEach(function (r) {
      (groups[r.source] = groups[r.source] || []).push(r);
    });
    var sources = Object.keys(groups).sort();

    if (sources.length === 0) {
      grid.innerHTML = '<div class="empty">No readings yet. The local pipeline is up but no PLC data has arrived.</div>';
    } else {
      var html = '';
      var freshest = Infinity;
      sources.forEach(function (src) {
        var rows = groups[src];
        // Machine freshness = its most-recently-updated metric.
        var newest = Math.max.apply(null, rows.map(function (r) { return r.updated_at; }));
        var age = now - newest;
        freshest = Math.min(freshest, age);
        var stale = age > STALE_MS;
        var dotColor = stale ? 'var(--stale)' : 'var(--live)';
        html += '<div class="card' + (stale ? ' stale' : '') + '">';
        html += '<h2><span class="sdot" style="background:' + dotColor + '"></span>' + esc(src) + '</h2><table>';
        rows.sort(function (a, b) { return a.metric < b.metric ? -1 : 1; });
        rows.forEach(function (r) {
          var sub = '';
          if (r.curspeed != null) sub += 'speed ' + esc(r.curspeed);
          html += '<tr><td class="metric">' + esc(r.metric) + '</td>' +
            '<td class="value num">' + esc(r.value) +
            (sub ? '<span class="sub">' + sub + '</span>' : '') + '</td>' +
            '<td class="age num">' + fmtAge(now - r.updated_at) + '</td></tr>';
        });
        html += '</table></div>';
      });
      grid.innerHTML = html;

      // Overall status from the freshest machine on the whole board.
      if (freshest <= STALE_MS) { setStatus('live', 'live'); banner.classList.remove('show'); }
      else if (freshest <= STALE_MS * 10) {
        setStatus('stale', 'stale'); banner.textContent = 'No fresh PLC data for a while — the line may be stopped or the local pipeline stalled.'; banner.classList.add('show');
      } else {
        setStatus('dead', 'no live data'); banner.textContent = 'No live production data. Last reading ' + fmtAge(freshest) + '.'; banner.classList.add('show');
      }
    }
    document.getElementById('clock').textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function poll() {
    fetch('/api/state', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); })
      .then(render)
      .catch(function () {
        // We couldn't even reach the local board API — that's a LOCAL fault
        // (the box/dashboard), distinct from "no PLC data".
        setStatus('dead', 'board offline');
        banner.textContent = 'Cannot reach the local board service on this box.';
        banner.classList.add('show');
      });
  }
  poll();
  setInterval(poll, 3000);
})();
</script>
</body>
</html>`
