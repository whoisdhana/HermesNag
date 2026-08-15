"""Mobile web widget — HermesNag on the iPhone, served over the tailnet.

One self-contained page, no build tooling, no framework. The page itself is
unauthenticated (it's an empty shell); every data call carries the bearer
token, which the page asks for once and keeps in localStorage. Reachable only
inside the tailnet via `tailscale serve`, so the localhost-only binding of the
API is unchanged.
"""

MOBILE_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>HermesNag</title>
<link rel="apple-touch-icon" href="/m/icon.png">
<link rel="icon" type="image/png" href="/m/icon.png">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin: 0; font: 16px/1.4 -apple-system, system-ui, sans-serif;
         background: #111; color: #eee;
         padding: env(safe-area-inset-top) 14px calc(env(safe-area-inset-bottom) + 90px); }
  h1 { font-size: 17px; display: flex; align-items: center; gap: 8px; margin: 14px 2px 6px; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #e33; }
  .dot.ok { background: #3c6; }
  .sec { font-size: 11px; font-weight: 700; letter-spacing: .08em; color: #888;
         margin: 18px 4px 6px; }
  .sec.force { color: #f66; }
  .row { display: flex; align-items: center; gap: 12px; padding: 12px 10px;
         background: #1b1b1b; border-radius: 12px; margin-bottom: 6px; }
  .row .tick { width: 26px; height: 26px; border: 2px solid #666; border-radius: 50%;
               flex: none; display: grid; place-items: center; font-size: 15px; color: transparent; }
  .row.due .tick { border-color: #f90; }
  .row.done { opacity: .55; }
  .row.done .title { text-decoration: line-through; }
  .row.done .tick { border-color: #3c6; color: #3c6; }
  .title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { font-size: 12px; color: #999; flex: none; font-variant-numeric: tabular-nums; }
  .meta.late { color: #f66; }
  .meta.due { color: #f90; }
  #addbar { position: fixed; left: 0; right: 0; bottom: 0; display: flex; gap: 8px;
            padding: 10px 14px calc(env(safe-area-inset-bottom) + 10px);
            background: rgba(17,17,17,.92); backdrop-filter: blur(12px); }
  #addbar input { flex: 1; font: inherit; padding: 12px 14px; border-radius: 12px;
                  border: 1px solid #333; background: #1b1b1b; color: #eee; outline: none; }
  #addbar button { font: inherit; padding: 12px 16px; border: 0; border-radius: 12px;
                   background: #f90; color: #000; font-weight: 700; }
  #login { padding: 40px 10px; text-align: center; }
  #login input { width: 100%; font: inherit; padding: 12px; border-radius: 12px;
                 border: 1px solid #333; background: #1b1b1b; color: #eee; margin: 12px 0; }
  #login button { font: inherit; padding: 12px 24px; border: 0; border-radius: 12px;
                  background: #f90; color: #000; font-weight: 700; }
  .empty { text-align: center; color: #777; padding: 34px 0 10px; }
  .flame { color: #f90; font-size: 13px; margin-left: auto; }
  #undobar, #snoozebar { position: fixed; left: 14px; right: 14px;
    bottom: calc(env(safe-area-inset-bottom) + 78px); display: flex; gap: 8px;
    align-items: center; padding: 10px 14px; background: #262626;
    border: 1px solid #3a3a3a; border-radius: 12px; z-index: 10; }
  #undobar span, #snoozebar span { flex: 1; min-width: 0; overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
  #undobar button, #snoozebar button { font: inherit; font-size: 13px;
    padding: 7px 12px; border: 0; border-radius: 9px; background: #f90;
    color: #000; font-weight: 700; }
  #snoozebar button:last-child { background: #444; color: #ccc; }
</style>
</head>
<body>
<div id="app"></div>
<div id="addbar" hidden>
  <input id="raw" placeholder="Add task… or habit: meditate daily" autocomplete="off">
  <button onclick="addTask()">Add</button>
</div>
<script>
const $ = s => document.querySelector(s);
let token = localStorage.getItem('hn_token') || '';
// QR handoff: token arrives in the fragment (#t=...), which browsers never
// send to any server. Store it and scrub the address bar.
if (location.hash.startsWith('#t=')) {
  token = decodeURIComponent(location.hash.slice(3));
  localStorage.setItem('hn_token', token);
  history.replaceState(null, '', location.pathname);
}

function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

async function api(path, opts = {}) {
  const r = await fetch(path, { ...opts,
    headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
               ...(opts.headers || {}) } });
  if (r.status === 401) { localStorage.removeItem('hn_token'); token = ''; render(); throw 0; }
  return r.json();
}

function loginView() {
  $('#addbar').hidden = true;
  $('#app').innerHTML = `<div id="login">
    <h1 style="justify-content:center">🔔 HermesNag</h1>
    <p style="color:#999">Paste your token once — it stays on this phone.</p>
    <input id="tok" placeholder="bearer token" autocomplete="off">
    <br><button onclick="saveTok()">Connect</button></div>`;
}
function saveTok() {
  token = $('#tok').value.trim();
  if (token) { localStorage.setItem('hn_token', token); render(); }
}

function dueLabel(t, now) {
  if (!t.due_at) return '';
  const d = new Date(t.due_at), mins = Math.round((d - now) / 60000);
  if (mins < -1440) return Math.round(-mins/1440) + 'd late';
  if (mins < -60)   return Math.round(-mins/60) + 'h late';
  if (mins < 0)     return -mins + 'm late';
  if (mins < 60)    return 'in ' + mins + 'm';
  if (mins < 1440)  return 'in ' + Math.round(mins/60) + 'h';
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });
}

function taskRow(t, now, done = false) {
  if (done) return `<div class="row done">
    <div class="tick">✓</div><div class="title">${esc(t.title)}</div></div>`;
  const late = t.due_at && new Date(t.due_at) < now;
  return `<div class="row ${late ? 'due' : ''}" data-id="${t.id}" onclick="completeTask('${t.id}')">
    <div class="tick">✓</div><div class="title">${esc(t.title)}</div>
    <div class="meta ${late ? 'late' : ''}">${t.recurrence ? '↻ ' : ''}${dueLabel(t, now)}</div></div>`;
}

function habitRow(h) {
  const mins = Math.round(h.seconds_until_due / 60);
  const label = h.is_due ? 'now' : (mins < 60 ? 'in ' + mins + 'm' : 'in ' + Math.round(mins/60) + 'h');
  return `<div class="row ${h.is_due ? 'due' : ''}" onclick="completeHabit('${h.id}')">
    <div class="tick">✓</div><div class="title">${esc(h.name)}</div>
    ${h.streak ? '<span class="flame">🔥' + h.streak + '</span>' : ''}
    <div class="meta ${h.is_due ? 'due' : ''}">${label}</div></div>`;
}

async function render() {
  if (!token) return loginView();
  $('#addbar').hidden = false;
  const now = new Date();
  try {
    const [tk, hb, health, st] = await Promise.all([
      api('/tasks'), api('/habits?active=true'), fetch('/health').then(r => r.json()),
      api('/stats').catch(() => null)]);
    const open = tk.tasks.filter(t => ['pending','snoozed'].includes(t.status));
    const force = open.filter(t => t.priority === 'must');
    const pending = open.filter(t => t.priority !== 'must')
      .sort((a,b) => (a.due_at||'9') < (b.due_at||'9') ? -1 : 1);
    const today = now.toDateString();
    const done = tk.tasks.filter(t => t.status === 'done' && t.completed_at
      && new Date(t.completed_at).toDateString() === today)
      .sort((a,b) => a.completed_at < b.completed_at ? 1 : -1).slice(0, 6);
    const habits = hb.habits.filter(h => h.enabled && h.in_active_hours)
      .sort((a,b) => (b.is_due - a.is_due) || (a.seconds_until_due - b.seconds_until_due));

    $('#app').innerHTML = `
      <h1><span class="dot ${health.ok ? 'ok' : ''}"></span> Today
          ${st && st.level ? `<span style="font-size:12px;font-weight:700;color:#f90">
            Lv${st.level} ${st.level_name}${st.points_today ? ' · +' + st.points_today : ''}</span>` : ''}
          <span style="margin-left:auto;color:#777;font-weight:400;font-size:13px">
          ${now.toLocaleTimeString('en-IN', {hour:'2-digit', minute:'2-digit'})}</span></h1>
      ${force.length ? '<div class="sec force">FORCE</div>' + force.map(t => taskRow(t, now)).join('') : ''}
      ${pending.length ? '<div class="sec">PENDING</div>' + pending.map(t => taskRow(t, now)).join('') : ''}
      ${habits.length ? '<div class="sec">HABITS</div>' + habits.map(habitRow).join('') : ''}
      ${done.length ? '<div class="sec">COMPLETED</div>' + done.map(t => taskRow(t, now, true)).join('') : ''}
      ${!force.length && !pending.length && !habits.length ? '<div class="empty">All clear ✓</div>' : ''}`;
    attachLongPress();
  } catch (e) { /* 401 already re-rendered */ }
}

let undoTimer = null;
function showUndo(id, title) {
  clearTimeout(undoTimer);
  let bar = $('#undobar');
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'undobar';
    document.body.appendChild(bar);
  }
  bar.innerHTML = `<span>Done: ${esc(title)}</span><button>Undo</button>`;
  bar.querySelector('button').onclick = async () => {
    bar.remove();
    await api('/tasks/' + id + '/reopen', { method: 'POST' }).catch(() => {});
    render();
  };
  undoTimer = setTimeout(() => bar.remove(), 6000);
}

async function completeTask(id) {
  const row = [...document.querySelectorAll('.row')].find(r => r.dataset.id === id);
  const title = row ? row.querySelector('.title').textContent : 'task';
  await api('/tasks/' + id + '/complete', { method: 'POST' }).catch(() => {});
  showUndo(id, title);
  render();
}

// Long-press a task row -> snooze options.
let pressTimer = null;
function attachLongPress() {
  document.querySelectorAll('.row[data-id]').forEach(row => {
    row.addEventListener('touchstart', () => {
      pressTimer = setTimeout(() => showSnooze(row.dataset.id,
        row.querySelector('.title').textContent), 550);
    }, { passive: true });
    ['touchend', 'touchmove', 'touchcancel'].forEach(ev =>
      row.addEventListener(ev, () => clearTimeout(pressTimer), { passive: true }));
  });
}

function minutesUntilHour(h) {
  const now = new Date(), t = new Date(now);
  t.setHours(h, 0, 0, 0);
  if (t <= now) t.setDate(t.getDate() + 1);
  return Math.max(1, Math.round((t - now) / 60000));
}

function showSnooze(id, title) {
  const old = $('#snoozebar'); if (old) old.remove();
  const bar = document.createElement('div');
  bar.id = 'snoozebar';
  bar.innerHTML = `<span>${esc(title)}</span>
    <button data-m="60">1h</button>
    <button data-m="${minutesUntilHour(21)}">Tonight</button>
    <button data-m="${minutesUntilHour(9)}">Tmrw</button>
    <button data-m="0">✕</button>`;
  bar.querySelectorAll('button').forEach(b => b.onclick = async () => {
    bar.remove();
    const mins = +b.dataset.m;
    if (mins > 0) {
      await api('/tasks/' + id + '/snooze', { method: 'POST',
        body: JSON.stringify({ minutes: mins }) }).catch(() => {});
      render();
    }
  });
  document.body.appendChild(bar);
}
async function completeHabit(id) {
  await api('/habits/' + id + '/done', { method: 'POST' }).catch(() => {});
  render();
}
async function addTask() {
  const raw = $('#raw').value.trim();
  if (!raw) return;
  $('#raw').value = '';
  if (raw.toLowerCase().startsWith('habit:')) {
    await api('/habits', { method: 'POST',
      body: JSON.stringify({ raw: raw.slice(6).trim() }) }).catch(() => {});
  } else {
    await api('/tasks', { method: 'POST', body: JSON.stringify({ raw }) }).catch(() => {});
  }
  render();
}

render();
setInterval(render, 30000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) render(); });
</script>
</body>
</html>"""
