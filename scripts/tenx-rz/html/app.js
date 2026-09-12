/* ============================================================
   NAIJA 2046 Red Zone control panel
   The panel never decides anything. It renders whatever the
   server sends and posts intent back. Every action is validated
   server-side, exactly like the commands are.
   ============================================================ */

const RES = 'tenx-rz';
const root = document.getElementById('root');

let state = {
  open: false,
  active: false,
  preview: false,
  radius: 0,
  startRadius: 0,
  minRadius: 40,
  step: 0.15,
  maxRadius: 1000,
  defaultRadius: 1000,
  elapsed: 0,
  nextCloseIn: null,
  nextDropIn: null,
  players: [],
  records: [],
  lobby: { count: 0, names: [] },
  piles: 0,
  drops: 0
};

let opts = { loot: true, airdrop: true, shrink: true };

/* ── plumbing ──────────────────────────────────────────── */

async function post(name, data = {}) {
  try {
    const res = await fetch(`https://${RES}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data)
    });
    return await res.json().catch(() => ({}));
  } catch (err) {
    flash('Could not reach the server.', true);
    return {};
  }
}

function close() {
  state.open = false;
  root.classList.add('hidden');
  post('close');
}

/* ── footer messages ───────────────────────────────────── */

let flashTimer = null;
function flash(msg, isError) {
  const foot = document.querySelector('.foot');
  const el = document.getElementById('footMsg');
  el.textContent = msg;
  foot.classList.remove('is-flash', 'is-error');
  foot.classList.add(isError ? 'is-error' : 'is-flash');
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => {
    foot.classList.remove('is-flash', 'is-error');
    el.textContent = state.active ? 'Round running' : 'Ready';
  }, 3600);
}

/* ── the dial ──────────────────────────────────────────── */

const R_MAX = 116;      // svg radius of the outer ring
const CX = 130, CY = 130;

function paintTicks() {
  const g = document.getElementById('dialTicks');
  g.innerHTML = '';
  if (!state.startRadius || !state.step) return;

  // One ring per remaining close, so the dial shows how many are left.
  let r = state.startRadius;
  const cut = state.startRadius * state.step;
  let guard = 0;

  while (r > state.minRadius && guard++ < 24) {
    r = Math.max(state.minRadius, r - cut);
    const svgR = (r / state.startRadius) * R_MAX;
    const c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    c.setAttribute('cx', CX);
    c.setAttribute('cy', CY);
    c.setAttribute('r', svgR.toFixed(2));
    c.setAttribute('class', 'dial-tick');
    c.setAttribute('fill', 'none');
    g.appendChild(c);
  }
}

function paintDial() {
  const zone = document.getElementById('dialZone');
  const edge = document.getElementById('dialEdge');
  const val  = document.getElementById('dialRadius');
  const sub  = document.getElementById('dialSub');
  const fig  = document.querySelector('.dial');

  if (!state.active) {
    fig.classList.add('dial-idle');
    zone.setAttribute('r', R_MAX);
    edge.setAttribute('r', R_MAX);
    val.textContent = '—';
    sub.textContent = 'No round running';
    return;
  }

  fig.classList.remove('dial-idle');

  const frac = state.startRadius > 0
    ? Math.max(0.04, state.radius / state.startRadius)
    : 1;
  const svgR = (frac * R_MAX).toFixed(2);

  zone.setAttribute('r', svgR);
  edge.setAttribute('r', svgR);
  val.textContent = Math.round(state.radius);

  if (state.preview) {
    sub.textContent = 'Dry run — nobody is being touched';
  } else if (state.radius <= state.minRadius) {
    sub.textContent = 'Fully closed';
  } else if (state.nextCloseIn != null && state.nextCloseIn >= 0) {
    sub.textContent = `Closes again in ${fmt(state.nextCloseIn)}`;
  } else {
    sub.textContent = 'Ring is closing';
  }
}

function fmt(sec) {
  sec = Math.max(0, Math.round(sec));
  const m = Math.floor(sec / 60), s = sec % 60;
  return m > 0 ? `${m}m ${String(s).padStart(2, '0')}s` : `${s}s`;
}

/* ── render ────────────────────────────────────────────── */

function render() {
  // status pill
  const pill = document.getElementById('statusPill');
  const text = document.getElementById('statusText');
  pill.className = 'pill ' + (state.preview ? 'pill-preview' : state.active ? 'pill-live' : 'pill-idle');
  text.textContent = state.preview ? 'Preview' : state.active ? 'Live' : 'Idle';

  // rail meta
  document.getElementById('railRound').textContent =
    state.active ? (state.preview ? 'Preview running' : `${Math.round(state.radius)}m · ${fmt(state.elapsed)}`) : 'Not running';

  const alive = state.players.filter(p => p.alive).length;
  document.getElementById('railPlayers').textContent =
    state.players.length ? `${alive} of ${state.players.length} alive` : '—';
  document.getElementById('railSupplies').textContent =
    state.active ? `${state.piles} piles` : '—';
  document.getElementById('railRecords').textContent =
    state.records.length ? `${state.records.length} held` : 'All clear';

  // buttons
  const startBtn = document.getElementById('startBtn');
  const endBtn = document.getElementById('endBtn');
  const liveActions = document.getElementById('liveActions');
  const previewBox = document.getElementById('previewBox');
  const previewBtn = document.getElementById('previewBtn');
  const previewStop = document.getElementById('previewStopBtn');

  startBtn.classList.toggle('hidden', state.active);
  endBtn.classList.toggle('hidden', !state.active);
  endBtn.textContent = state.preview ? 'Stop preview' : 'End round';
  liveActions.classList.toggle('hidden', !state.active || state.preview);
  previewBox.classList.toggle('hidden', state.active && !state.preview);
  previewBtn.classList.toggle('hidden', state.preview);
  previewStop.classList.toggle('hidden', !state.preview);

  // lobby
  document.getElementById('lobbyCount').textContent = state.lobby.count;
  document.getElementById('lobbyNames').textContent =
    state.lobby.count > 0
      ? state.lobby.names.slice(0, 6).join(', ') + (state.lobby.count > 6 ? ` +${state.lobby.count - 6} more` : '')
      : 'Nobody is standing in the pickup area.';

  paintDial();
  renderPlayers();
  renderSupplies();
  renderRecords();
}

function renderPlayers() {
  const table = document.getElementById('playerTable');
  const alive = state.players.filter(p => p.alive).length;

  document.getElementById('playerTally').textContent =
    state.players.length ? `${alive} alive · ${state.players.length} total` : 'nobody in';

  if (!state.players.length) {
    table.innerHTML = `<p class="empty">${state.active
      ? 'Round is running but nobody was swept in. Check who was standing in the lobby.'
      : 'No round running. Start one and the roster appears here.'}</p>`;
    return;
  }

  table.innerHTML = state.players.map(p => `
    <div class="row ${p.alive ? 'row-alive' : 'row-out'}">
      <div>
        <span class="row-name">${esc(p.name)}</span>
        <span class="row-sub">id ${p.id ?? 'offline'}${p.online ? '' : ' · disconnected'}</span>
      </div>
      <span class="row-state ${p.alive ? 'state-alive' : 'state-out'}">${p.alive ? 'Alive' : 'Out'}</span>
      <div class="row-actions">
        ${p.alive && p.online ? `<button class="mini mini-danger" data-kill="${p.id}">Knock out</button>` : ''}
        <button class="mini" data-restore="${esc(p.identifier)}">Give items back</button>
      </div>
    </div>
  `).join('');
}

function renderSupplies() {
  document.getElementById('pileCount').textContent = state.piles;
  document.getElementById('dropCount').textContent = state.drops;
  document.getElementById('nextDrop').textContent =
    state.nextDropIn != null && state.nextDropIn >= 0 ? fmt(state.nextDropIn) : '—';
  document.getElementById('lootTally').textContent =
    state.active ? `${state.piles + state.drops} on the map` : 'round not running';
}

function renderRecords() {
  const table = document.getElementById('recordTable');
  document.getElementById('recordTally').textContent =
    state.records.length ? `${state.records.length} outstanding` : 'all returned';

  if (!state.records.length) {
    table.innerHTML = `<p class="empty">Nothing outstanding. Every inventory has been returned.</p>`;
    return;
  }

  table.innerHTML = state.records.map(r => `
    <div class="row row-owed">
      <div>
        <span class="row-name">${esc(r.name || 'Unknown player')}</span>
        <span class="row-sub">${esc(r.identifier)}</span>
      </div>
      <span class="row-state state-owed">${r.status === 'pending' ? 'Waiting' : 'Held'}</span>
      <div class="row-actions">
        <button class="mini" data-restore="${esc(r.identifier)}">Give items back</button>
      </div>
    </div>
  `).join('');
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ── events ────────────────────────────────────────────── */

document.querySelectorAll('.rail-item').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.rail-item').forEach(b => b.classList.remove('is-active'));
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('is-active'));
    btn.classList.add('is-active');
    document.querySelector(`[data-panel="${btn.dataset.tab}"]`).classList.add('is-active');
  });
});

document.getElementById('closeBtn').addEventListener('click', close);

document.addEventListener('keyup', e => {
  if (e.key === 'Escape' && state.open) close();
});

// radius: slider and number stay in step
const range = document.getElementById('radiusRange');
const num = document.getElementById('radiusInput');
range.addEventListener('input', () => { num.value = range.value; });
num.addEventListener('input', () => {
  let v = Math.min(state.maxRadius, Math.max(5, Number(num.value) || 5));
  range.value = v;
});

document.querySelectorAll('.chip').forEach(chip => {
  chip.addEventListener('click', () => {
    const key = chip.dataset.toggle;
    opts[key] = !opts[key];
    chip.classList.toggle('is-on', opts[key]);
  });
});

document.getElementById('startBtn').addEventListener('click', async () => {
  const radius = Math.min(state.maxRadius, Math.max(5, Number(num.value) || state.defaultRadius));
  const res = await post('start', { radius, options: opts });
  flash(res.message || 'Starting the round.', !res.ok);
});

document.getElementById('endBtn').addEventListener('click', async () => {
  const res = await post(state.preview ? 'previewStop' : 'end');
  flash(res.message || 'Round ended.', !res.ok);
});

document.getElementById('previewBtn').addEventListener('click', async () => {
  const radius = Math.min(state.maxRadius, Math.max(5, Number(num.value) || state.defaultRadius));
  const res = await post('previewStart', { radius, speed: 5 });
  flash(res.message || 'Preview running.', !res.ok);
});

document.getElementById('previewStopBtn').addEventListener('click', async () => {
  const res = await post('previewStop');
  flash(res.message || 'Preview stopped.', !res.ok);
});

document.addEventListener('click', async e => {
  const act = e.target.closest('[data-act]');
  if (act) {
    const res = await post('action', { action: act.dataset.act });
    flash(res.message || 'Done.', !res.ok);
    return;
  }

  const kill = e.target.closest('[data-kill]');
  if (kill) {
    const res = await post('knockOut', { id: Number(kill.dataset.kill) });
    flash(res.message || 'Player knocked out.', !res.ok);
    return;
  }

  const restore = e.target.closest('[data-restore]');
  if (restore) {
    const res = await post('restore', { identifier: restore.dataset.restore });
    flash(res.message || 'Inventory returned.', !res.ok);
  }
});

/* ── inbound from the client script ────────────────────── */

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'open') {
    state.open = true;
    root.classList.remove('hidden');
    Object.assign(state, d.state || {});
    syncInputs();
    paintTicks();
    render();
  }

  if (d.action === 'close') {
    state.open = false;
    root.classList.add('hidden');
  }

  if (d.action === 'update') {
    const hadStart = state.startRadius;
    Object.assign(state, d.state || {});
    if (state.startRadius !== hadStart) paintTicks();
    render();
  }
});

function syncInputs() {
  range.max = state.maxRadius;
  num.max = state.maxRadius;
  const v = state.active ? Math.round(state.startRadius) : state.defaultRadius;
  range.value = v;
  num.value = v;
  document.getElementById('radiusHint').textContent = `max ${state.maxRadius}m`;
}

/* ============================================================
   SETUP TAB
   Reads whatever the server reports as live settings, edits a
   local copy, and posts the whole shape back on save. Nothing
   is applied until Save is pressed.
   ============================================================ */

let settings = null;

const LIST_COLS = {
  loadout: ['name', 'count'],
  loot:    ['name', 'count', 'piles'],
  airdrop: ['name', 'count']
};

const LIST_LABELS = {
  name:  'Item name',
  count: 'How many',
  piles: 'Piles'
};

function getPath(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function setPath(obj, path, val) {
  const keys = path.split('.');
  const last = keys.pop();
  let cur = obj;
  for (const k of keys) {
    if (typeof cur[k] !== 'object' || cur[k] === null) cur[k] = {};
    cur = cur[k];
  }
  cur[last] = val;
}

function paintItemList(key) {
  const host = document.querySelector(`[data-list="${key}"]`);
  if (!host) return;

  const cols = LIST_COLS[key];
  const rows = getPath(settings, `${key}.items`) || [];
  const cls = cols.length === 2 ? ' cols-2' : '';

  host.innerHTML =
    `<div class="itemlist-head${cls}">${cols.map(c => `<span>${LIST_LABELS[c]}</span>`).join('')}<span></span></div>` +
    rows.map((row, i) => `
      <div class="item-row${cls}">
        ${cols.map(c => `<input type="${c === 'name' ? 'text' : 'number'}"
             value="${esc(row[c] ?? (c === 'name' ? '' : 1))}"
             placeholder="${LIST_LABELS[c]}"
             data-list-input="${key}" data-idx="${i}" data-key="${c}">`).join('')}
        <button class="row-del" data-del="${key}" data-idx="${i}" title="Remove">&#10005;</button>
      </div>`).join('');
}

function paintSettings() {
  if (!settings) return;

  document.querySelectorAll('[data-set]').forEach(el => {
    const path = el.dataset.set;
    let v = getPath(settings, path);

    if (path === 'airdrop.spawnAfter') {
      v = Array.isArray(v) ? v.join(', ') : v;
    }

    if (el.type === 'checkbox') el.checked = !!v;
    else if (v !== undefined && v !== null) el.value = v;
  });

  Object.keys(LIST_COLS).forEach(paintItemList);
}

async function loadSettings() {
  const res = await post('getSettings');
  if (res && res.settings) {
    settings = res.settings;
    paintSettings();
    document.getElementById('railSetup').textContent = 'Ready to edit';
  }
}

document.addEventListener('input', e => {
  if (!settings) return;

  const set = e.target.closest('[data-set]');
  if (set) {
    const path = set.dataset.set;
    let v;
    if (set.type === 'checkbox') v = set.checked;
    else if (set.type === 'number') v = set.value === '' ? '' : Number(set.value);
    else v = set.value;

    if (path === 'airdrop.spawnAfter') {
      v = String(v).split(',').map(x => Number(x.trim())).filter(x => !isNaN(x) && x > 0);
    }

    setPath(settings, path, v);
    paintZoneTimer();
    return;
  }

  const li = e.target.closest('[data-list-input]');
  if (li) {
    const key = li.dataset.listInput;
    const idx = Number(li.dataset.idx);
    const field = li.dataset.key;
    const rows = getPath(settings, `${key}.items`) || [];
    if (rows[idx]) {
      rows[idx][field] = field === 'name' ? li.value : Number(li.value) || 1;
    }
  }
});

document.addEventListener('click', e => {
  const fold = e.target.closest('.fold-head');
  if (fold) {
    fold.parentElement.classList.toggle('is-open');
    return;
  }

  const add = e.target.closest('[data-add]');
  if (add && settings) {
    const key = add.dataset.add;
    const rows = getPath(settings, `${key}.items`) || [];
    const blank = { name: '', count: 1 };
    if (LIST_COLS[key].includes('piles')) blank.piles = 1;
    rows.push(blank);
    setPath(settings, `${key}.items`, rows);
    paintItemList(key);
    return;
  }

  const del = e.target.closest('[data-del]');
  if (del && settings) {
    const key = del.dataset.del;
    const rows = getPath(settings, `${key}.items`) || [];
    rows.splice(Number(del.dataset.idx), 1);
    paintItemList(key);
  }
});

document.getElementById('saveSettingsBtn').addEventListener('click', async () => {
  if (!settings) return;
  const res = await post('saveSettings', { settings });
  if (res.settings) { settings = res.settings; paintSettings(); }
  flash(res.message || 'Settings saved.', !res.ok);
});

document.getElementById('resetSettingsBtn').addEventListener('click', async () => {
  const res = await post('resetSettings');
  if (res.settings) { settings = res.settings; paintSettings(); }
  flash(res.message || 'Back to defaults.', !res.ok);
});

// Pull settings once the panel opens.
window.addEventListener('message', ev => {
  if ((ev.data || {}).action === 'open' && !settings) loadSettings();
});

/* ============================================================
   QUEUE + NO-SPAWN AREAS
   ============================================================ */

function renderQueue() {
  const table = document.getElementById('queueTable');
  const tally = document.getElementById('queueTally');
  const q = state.queue || [];

  tally.textContent = state.queueEnabled
    ? (q.length ? `${q.length} signed up` : 'nobody yet')
    : 'sign-up ped is off';

  if (!q.length) {
    table.innerHTML = `<p class="empty">${state.queueEnabled
      ? 'Nobody has signed up yet. Players join at the ped.'
      : 'The sign-up ped is switched off in Setup.'}</p>`;
    return;
  }

  table.innerHTML = q.map((p, i) => `
    <div class="row row-queued">
      <div>
        <span class="row-name">${esc(p.name)}</span>
        <span class="row-sub">#${i + 1} in line${p.online ? '' : ' · disconnected'}</span>
      </div>
      <span class="row-state state-queued">Waiting</span>
      <div class="row-actions">
        <button class="mini mini-danger" data-kickq="${esc(p.identifier)}">Remove</button>
      </div>
    </div>
  `).join('');
}

function renderZones() {
  const host = document.getElementById('zoneList');
  if (!host) return;

  const zones = state.noSpawn || [];
  if (!zones.length) {
    host.innerHTML = `<p class="empty">No areas marked. Water is still avoided automatically.</p>`;
    return;
  }

  host.innerHTML = zones.map((z, i) => `
    <div class="zone-row">
      <span class="zone-name">${esc(z.label || `Zone ${i + 1}`)}</span>
      <span class="zone-meta">${Math.round(z.x)}, ${Math.round(z.y)} · ${Math.round(z.radius)}m</span>
      <button class="row-del" data-delzone="${i + 1}" title="Remove">&#10005;</button>
    </div>
  `).join('');
}

// hook into the main render pass
const _baseRender = render;
render = function () {
  _baseRender();
  renderQueue();
  renderZones();
  const rs = document.getElementById('railPlayers');
  if (rs && state.queue && state.queue.length && !state.active) {
    rs.textContent = `${state.queue.length} signed up`;
  }
};

document.addEventListener('click', async e => {
  const act2 = e.target.closest('[data-act2]');
  if (act2) {
    const res = await post(act2.dataset.act2);
    flash(res.message || 'Done.', !res.ok);
    return;
  }

  const kickq = e.target.closest('[data-kickq]');
  if (kickq) {
    const res = await post('kickQueue', { identifier: kickq.dataset.kickq });
    flash(res.message || 'Removed.', !res.ok);
    return;
  }

  const delzone = e.target.closest('[data-delzone]');
  if (delzone) {
    const res = await post('removeNoSpawn', { index: Number(delzone.dataset.delzone) });
    flash(res.message || 'Removed.', !res.ok);
    return;
  }

  const mark = e.target.closest('#markZoneBtn');
  if (mark) {
    const res = await post('addNoSpawn', {
      radius: Number(document.getElementById('zoneRadius').value) || 50,
      label: document.getElementById('zoneLabel').value.trim()
    });
    if (res.ok) document.getElementById('zoneLabel').value = '';
    flash(res.message || 'Marked.', !res.ok);
    return;
  }

  // "use where I'm standing" fills the coordinate fields from the admin's ped
  const pos = e.target.closest('[data-pos]');
  if (pos && settings) {
    const res = await post('myPosition');
    if (!res.ok || !res.coords) {
      flash(res.message || 'Could not read your position.', true);
      return;
    }
    const base = pos.dataset.pos;
    ['x', 'y', 'z', 'w'].forEach(k => {
      const el = document.querySelector(`[data-set="${base}.${k}"]`);
      if (el && res.coords[k] !== undefined) {
        el.value = res.coords[k];
        setPath(settings, `${base}.${k}`, res.coords[k]);
      }
    });
    flash('Filled in from where you are standing. Save to keep it.');
  }
});

/* ============================================================
   IN-ROUND HUD
   Separate from the admin panel: never focused, never blocks
   input, and renders nothing until there's something to show.
   ============================================================ */

const hudEl = document.getElementById('hud');
const bannerEl = document.getElementById('banner');
const feedEl = document.getElementById('feed');

let bannerTimer = null;
let bannerBarAnim = null;

const BANNERS = {
  announced: d => ({
    accent: '#F5D77A',
    eyebrow: d.totalCloses ? `Zone ${d.closeNo} of ${d.totalCloses}` : 'Zone',
    title: d.isLast ? 'FINAL ZONE MARKED' : 'NEXT ZONE MARKED',
    sub: (d.moved > 40 ? `It moves — check your map` : `Down to ${d.target}m`)
         + (d.damage ? ` · ${d.damage}/sec outside` : ''),
    hold: Math.min(9000, (d.duration || 8) * 1000),
    bar: (d.duration || 8) * 1000
  }),
  closing: () => ({
    accent: '#E4483C',
    eyebrow: 'Move',
    title: 'THE ZONE IS CLOSING',
    sub: 'Get inside the marked circle',
    hold: 5000
  }),
  closed: () => ({
    accent: '#E4483C',
    eyebrow: 'Zone',
    title: 'FULLY CLOSED',
    sub: 'Last one standing takes it',
    hold: 6000
  }),
  fight: () => ({
    accent: '#16E45F',
    eyebrow: 'Red Zone',
    title: 'FIGHT',
    sub: 'You have been dropped in',
    hold: 4000
  }),
  starting: d => ({
    accent: '#16E45F',
    eyebrow: 'Red Zone',
    title: 'ROUND STARTING',
    sub: `Pulling you in — ${d.seconds}s`,
    hold: (d.seconds || 5) * 1000,
    bar: (d.seconds || 5) * 1000
  }),
  eliminated: () => ({
    accent: '#E4483C',
    eyebrow: 'You are out',
    title: 'ELIMINATED',
    sub: 'Your inventory comes back when the round ends',
    hold: 5500
  }),
  over: () => ({
    accent: '#C9A227',
    eyebrow: 'Red Zone',
    title: 'ROUND OVER',
    sub: 'Everything has been returned',
    hold: 5500
  }),
  airdrop: () => ({
    accent: '#E4483C',
    eyebrow: 'Supply drop',
    title: 'AIRDROP INCOMING',
    sub: 'Marked in red on your map',
    hold: 5000
  }),
  crate: () => ({
    accent: '#C9A227',
    eyebrow: 'Supply drop',
    title: 'CRATE SECURED',
    sub: '',
    hold: 3500
  }),
  chute: () => ({
    accent: '#16E45F',
    eyebrow: 'Parachute',
    title: 'OPENED FOR YOU',
    sub: 'You left it late',
    hold: 3000
  }),
  finalstand: d => ({
    accent: '#E4483C',
    eyebrow: 'Zone',
    title: 'FINAL STAND',
    sub: `${d.seconds} seconds`,
    hold: (d.seconds || 10) * 1000,
    bar: (d.seconds || 10) * 1000
  })
};

function showBanner(kind, data) {
  const build = BANNERS[kind];
  if (!build) return;
  const b = build(data || {});

  clearTimeout(bannerTimer);
  if (bannerBarAnim) { bannerBarAnim.cancel(); bannerBarAnim = null; }

  bannerEl.style.setProperty('--accent', b.accent);
  document.getElementById('bannerEyebrow').textContent = b.eyebrow || '';
  document.getElementById('bannerTitle').textContent = b.title || '';
  document.getElementById('bannerSub').textContent = b.sub || '';

  const barWrap = bannerEl.querySelector('.banner-bar');
  const bar = document.getElementById('bannerBar');

  if (b.bar) {
    barWrap.classList.remove('hidden');
    bar.style.transform = 'scaleX(1)';
    bannerBarAnim = bar.animate(
      [{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }],
      { duration: b.bar, easing: 'linear', fill: 'forwards' }
    );
  } else {
    barWrap.classList.add('hidden');
  }

  hudEl.classList.remove('hidden');
  // force reflow so the transition runs even on a back-to-back banner
  void bannerEl.offsetWidth;
  bannerEl.classList.add('is-in');

  bannerTimer = setTimeout(() => bannerEl.classList.remove('is-in'), b.hold || 4000);
}

function addKill(d) {
  let inner;
  if (d.cause === 'zone') {
    inner = `<span class="feed-victim">${esc(d.victim)}</span>
             <span class="feed-verb">lost to the zone</span>`;
  } else if (d.killer) {
    inner = `<span class="feed-killer">${esc(d.killer)}</span>
             <span class="feed-verb">killed</span>
             <span class="feed-victim">${esc(d.victim)}</span>
             ${d.kills > 1 ? `<span class="feed-streak">${d.kills}</span>` : ''}`;
  } else {
    inner = `<span class="feed-victim">${esc(d.victim)}</span>
             <span class="feed-verb">died</span>`;
  }

  const line = document.createElement('div');
  line.className = `feed-line kind-${d.cause === 'zone' ? 'zone' : 'kill'}`;
  line.innerHTML = inner;
  feedEl.prepend(line);

  while (feedEl.children.length > 5) feedEl.lastElementChild.remove();

  setTimeout(() => {
    line.classList.add('is-out');
    setTimeout(() => line.remove(), 320);
  }, d.ttl || 8000);
}

function showWinner(d) {
  document.querySelectorAll('.winner').forEach(el => el.remove());

  const card = document.createElement('div');
  card.className = 'winner';
  card.innerHTML = `
    <span class="winner-eyebrow">${d.shared ? 'Round ended' : 'Last one standing'}</span>
    <span class="winner-name">${esc(d.name)}</span>
    <span class="winner-sub">${d.kills} kill${d.kills === 1 ? '' : 's'} · ${d.players} in the round</span>`;
  hudEl.appendChild(card);

  hudEl.classList.remove('hidden');
  void card.offsetWidth;
  card.classList.add('is-in');

  setTimeout(() => {
    card.classList.remove('is-in');
    setTimeout(() => card.remove(), 500);
  }, 9000);
}

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'hud:visible') {
    if (d.visible) {
      hudEl.classList.remove('hidden');
    } else {
      hudEl.classList.add('hidden');
      bannerEl.classList.remove('is-in');
      feedEl.innerHTML = '';
      const kn = document.getElementById('killNum');
      if (kn) kn.textContent = '0';
      const dh = document.getElementById('dropHelp');
      if (dh) dh.classList.add('hidden');
    }
  }

  if (d.action === 'hud:alive') {
    hudEl.classList.remove('hidden');
    document.getElementById('aliveNum').textContent = d.alive;
    document.getElementById('aliveTotal').textContent = d.total;
    document.getElementById('alive').classList.toggle('is-low', d.alive <= 3);
  }

  if (d.action === 'hud:kills') {
    hudEl.classList.remove('hidden');
    const el = document.getElementById('killNum');
    if (el) el.textContent = d.kills || 0;
  }

  if (d.action === 'hud:drop') {
    hudEl.classList.remove('hidden');
    const help = document.getElementById('dropHelp');
    if (help) {
      help.classList.remove('hidden');
      clearTimeout(window.__dropTimer);
      window.__dropTimer = setTimeout(() => help.classList.add('hidden'), (d.seconds || 12) * 1000);
    }
  }

  if (d.action === 'hud:dropEnd') {
    const help = document.getElementById('dropHelp');
    if (help) help.classList.add('hidden');
    clearTimeout(window.__dropTimer);
  }

  if (d.action === 'hud:kill') {
    hudEl.classList.remove('hidden');
    addKill(d);
  }

  if (d.action === 'hud:banner') {
    showBanner(d.kind, d);
  }

  if (d.action === 'hud:winner') {
    showWinner(d);
  }
});

/* ── winners board ─────────────────────────────────────── */

function fmtDuration(sec) {
  sec = Math.max(0, Math.round(sec || 0));
  const m = Math.floor(sec / 60), s = sec % 60;
  return `${m}m ${String(s).padStart(2, '0')}s`;
}

function fmtWhen(ts) {
  if (!ts) return '';
  const d = new Date(String(ts).replace(' ', 'T'));
  if (isNaN(d)) return String(ts);
  return d.toLocaleString(undefined, {
    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
  });
}

async function loadRounds() {
  const res = await post('getRounds');
  if (!res || !res.ok) return;

  const top = res.top || [];
  const rounds = res.rounds || [];

  document.getElementById('winnerTally').textContent =
    rounds.length ? `${rounds.length} round${rounds.length === 1 ? '' : 's'}` : 'nothing yet';
  document.getElementById('railWinners').textContent =
    rounds.length ? `${rounds.length} recorded` : 'Round history';

  const board = document.getElementById('topBoard');
  board.innerHTML = top.length
    ? top.map((t, i) => `
        <div class="board-row">
          <span class="board-rank">${i + 1}</span>
          <span class="board-name">${esc(t.name)}</span>
          <span class="board-stat"><strong>${t.wins}</strong> win${t.wins == 1 ? '' : 's'}</span>
          <span class="board-stat">${t.kills || 0} kills</span>
        </div>`).join('')
    : `<p class="empty">Nobody has won a round yet.</p>`;

  const table = document.getElementById('roundTable');
  table.innerHTML = rounds.length
    ? rounds.map(r => `
        <div class="round-row${r.winner_name ? '' : ' no-winner'}">
          <div>
            <span class="row-name">${r.winner_name ? esc(r.winner_name) : 'No survivor'}</span>
            <span class="row-sub">${r.winner_name ? `${r.winner_kills || 0} kill${r.winner_kills == 1 ? '' : 's'}` : esc(r.end_reason || 'ended')}</span>
          </div>
          <span class="board-stat">${r.players} in</span>
          <span class="board-stat">${fmtDuration(r.duration)}</span>
          <span class="round-when">${fmtWhen(r.ended_at)}</span>
        </div>`).join('')
    : `<p class="empty">No rounds recorded yet. The first one that finishes shows up here.</p>`;
}

// refresh the board whenever the tab is opened
document.querySelectorAll('.rail-item').forEach(btn => {
  if (btn.dataset.tab === 'winners') {
    btn.addEventListener('click', loadRounds);
  }
});

window.addEventListener('message', ev => {
  if ((ev.data || {}).action === 'open') loadRounds();
});

/* ============================================================
   ZONE TIMER + PHASE EDITOR
   One number drives the whole close. The phases say what size to
   shrink to and how hard the zone bites while that phase is live.
   ============================================================ */

function ttd(damage) {
  // 100 usable health points (QBCore runs 100-200), one tick a second.
  const d = Number(damage) || 0;
  if (d <= 0) return '—';
  const secs = 100 / d;
  if (secs >= 60) return `${Math.floor(secs / 60)}m ${String(Math.round(secs % 60)).padStart(2, '0')}s`;
  return `${secs.toFixed(secs < 10 ? 1 : 0)}s`;
}

function renderPhases() {
  const host = document.getElementById('phaseList');
  if (!host || !settings) return;

  const rows = getPath(settings, 'shrink.phases') || [];

  host.innerHTML =
    `<div class="phase-head">
       <span>#</span><span>Shrinks to</span><span>Damage/sec</span><span>Kills in</span><span></span>
     </div>` +
    rows.map((r, i) => {
      const final = Number(r.radius) <= 0;
      const harsh = Number(r.damage) >= 20;
      return `<div class="phase-row ${final ? 'is-final' : ''}">
        <span class="phase-no">${i + 1}</span>
        <input type="number" step="0.01" min="0" max="1" value="${r.radius ?? 0.5}" data-ph="${i}" data-pk="radius">
        <input type="number" step="0.5" min="0.1" value="${r.damage ?? 1}" data-ph="${i}" data-pk="damage">
        <span class="phase-ttd ${harsh ? 'is-harsh' : ''}">${ttd(r.damage)}</span>
        <button class="row-del" data-phdel="${i}" title="Remove">&#10005;</button>
      </div>`;
    }).join('');

  paintZoneTimer();
}

// Live readout of what the numbers actually produce, so "30 minutes across
// 7 phases" isn't something you have to work out in your head.
function paintZoneTimer() {
  const el = document.getElementById('zoneTimerNote');
  if (!el || !settings) return;

  const total = Number(getPath(settings, 'shrink.totalDuration')) || 0;
  const delay = Number(getPath(settings, 'shrink.startDelay')) || 0;
  const hold = Number(getPath(settings, 'shrink.holdFraction'));
  const phases = getPath(settings, 'shrink.phases') || [];

  if (!total || !phases.length) { el.textContent = ''; return; }

  const slice = (total - delay) / phases.length;
  const hf = isNaN(hold) ? 0.6 : hold;
  const last = phases[phases.length - 1];
  const closesFully = Number(last?.radius) <= 0;

  el.innerHTML =
    `That's <strong>${phases.length} phases</strong> of about <strong>${Math.round(slice)}s</strong> each ` +
    `&mdash; roughly ${Math.round(slice * hf)}s standing still, then ${Math.round(slice * (1 - hf))}s closing. ` +
    (closesFully
      ? `The last phase shuts the ring completely, so the whole map goes lethal.`
      : `<strong>The last phase does not close fully</strong> &mdash; set its size to 0 if you want the whole map to go lethal.`);
}

// minutes field <-> seconds in the settings
const zoneMinutes = document.getElementById('zoneMinutes');
if (zoneMinutes) {
  zoneMinutes.addEventListener('input', () => {
    if (!settings) return;
    const mins = Math.max(1, Number(zoneMinutes.value) || 1);
    setPath(settings, 'shrink.totalDuration', Math.round(mins * 60));
    paintZoneTimer();
  });
}

document.addEventListener('input', e => {
  if (!settings) return;

  const ph = e.target.closest('[data-ph]');
  if (ph) {
    const i = Number(ph.dataset.ph);
    const key = ph.dataset.pk;
    const rows = getPath(settings, 'shrink.phases') || [];
    if (rows[i]) {
      rows[i][key] = Number(ph.value) || (key === 'radius' ? 0 : 0.1);
      // only the time-to-die cell needs repainting; a full redraw would
      // steal focus from the field being typed into
      const cell = ph.closest('.phase-row').querySelector('.phase-ttd');
      if (cell && key === 'damage') {
        cell.textContent = ttd(rows[i].damage);
        cell.classList.toggle('is-harsh', Number(rows[i].damage) >= 20);
      }
      paintZoneTimer();
    }
    return;
  }

  const s = e.target.closest('[data-set]');
  if (s && (s.dataset.set === 'shrink.startDelay' || s.dataset.set === 'shrink.holdFraction')) {
    paintZoneTimer();
  }
});

document.addEventListener('click', e => {
  if (!settings) return;

  const del = e.target.closest('[data-phdel]');
  if (del) {
    const rows = getPath(settings, 'shrink.phases') || [];
    rows.splice(Number(del.dataset.phdel), 1);
    renderPhases();
    return;
  }

  if (e.target.closest('#addPhase')) {
    const rows = getPath(settings, 'shrink.phases') || [];
    const lastR = rows.length ? Number(rows[rows.length - 1].radius) : 1;
    rows.push({ radius: Math.max(0, +(lastR * 0.6).toFixed(2)), damage: 5 });
    setPath(settings, 'shrink.phases', rows);
    renderPhases();
  }
});

// hook the phase editor into the settings paint
const _basePaintSettings = paintSettings;
paintSettings = function () {
  _basePaintSettings();
  if (settings && zoneMinutes) {
    const total = Number(getPath(settings, 'shrink.totalDuration')) || 0;
    zoneMinutes.value = Math.round(total / 60);
  }
  renderPhases();
};
