/* ============================================================
   NAIJA 2046 Arena builder
   The panel renders what the server sends and posts intent back.
   Nothing is decided here; every action is validated server side.
   ============================================================ */

const RES = 'tenx-arena';
const root = document.getElementById('root');
const minibar = document.getElementById('minibar');

let state = { arenas: [], occupants: [], defaultLoadout: [] };
let selected = null;      // arena id being edited
let loadoutRows = [];     // local copy while editing

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

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

let flashTimer = null;
function flash(msg, isError) {
  const foot = document.querySelector('.foot');
  document.getElementById('footMsg').textContent = msg;
  foot.classList.remove('is-flash', 'is-error');
  foot.classList.add(isError ? 'is-error' : 'is-flash');
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => {
    foot.classList.remove('is-flash', 'is-error');
    document.getElementById('footMsg').textContent = 'Ready';
  }, 3600);
}

function current() {
  return state.arenas.find(a => a.id === selected) || null;
}

/* ── rendering ─────────────────────────────────────────── */

function renderList() {
  const host = document.getElementById('arenaList');

  if (!state.arenas.length) {
    host.innerHTML = `<p class="empty" style="margin:12px">No arenas yet.</p>`;
    return;
  }

  host.innerHTML = state.arenas.map(a => {
    const cls = [
      'arena-item',
      a.id === selected ? 'is-active' : '',
      !a.enabled ? 'is-off' : '',
      !a.hasBounds ? 'is-nobounds' : '',
      a.occupants > 0 ? 'is-live' : ''
    ].filter(Boolean).join(' ');

    const meta = !a.hasBounds
      ? 'No boundary yet'
      : `${a.spawnsA}v${a.spawnsB} spawns · ${a.running || 0}/${a.instances || 1} running`;

    return `<button class="${cls}" data-arena="${a.id}">
      <span class="arena-item-name">${esc(a.name)}</span>
      <span class="arena-item-meta">${meta}</span>
      <span class="arena-item-dot"></span>
    </button>`;
  }).join('');
}

// Which view the admin chose. renderEdit runs on every repaint -- every two
// seconds -- and used to force the panel back to the arena editor, so
// clicking Live or Players showed them for a moment before they were snatched
// away again.
let adminView = 'live';

function renderEdit() {
  const a = current();

  // Only touch the panels if the arena editor is the chosen view. Otherwise
  // leave whatever the admin is looking at alone.
  if (adminView === 'arena') {
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('is-active'));
    document.querySelector(`[data-panel="${a ? 'edit' : 'empty'}"]`).classList.add('is-active');
  }

  if (!a) return;

  document.getElementById('editName').textContent = a.name;
  // Don't overwrite what someone is typing. The panel repaints every two
  // seconds while it's open, so setting this unconditionally wiped the field
  // mid-word -- which is why renaming appeared to do nothing.
  const nameField = document.getElementById('arenaName');
  if (document.activeElement !== nameField) nameField.value = a.name;

  // boundary
  const bs = document.getElementById('boundsState');
  const bn = document.getElementById('boundsNote');
  if (a.hasBounds && a.bounds) {
    // Zones are polygons -- there is no minX/maxX any more, which is why this
    // read "NaNm across". Size comes from the marked points instead.
    const pts = a.bounds.points || [];
    const xs = pts.map(p => p.x);
    const ys = pts.map(p => p.y);

    const w = xs.length ? Math.round(Math.max(...xs) - Math.min(...xs)) : 0;
    const d = ys.length ? Math.round(Math.max(...ys) - Math.min(...ys)) : 0;
    const h = Math.round((a.bounds.maxZ || 0) - (a.bounds.minZ || 0));

    // Real area, not the bounding box -- a long thin zone and a square one
    // can have the same width and depth and be nothing alike.
    let area = 0;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      area += (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y);
    }
    area = Math.abs(Math.round(area / 2));

    bs.textContent = 'Set';
    bs.className = 'card-state is-ok';
    bn.textContent = `${pts.length} points, about ${area.toLocaleString()}m² `
      + `— ${w}m by ${d}m, ${h}m tall.`;
  } else {
    bs.textContent = 'Not set';
    bs.className = 'card-state is-bad';
    bn.textContent = 'Walk the shape and press E at each point. Three or more, any shape.';
  }

  // spawns
  document.getElementById('countA').textContent = a.spawnsA;
  document.getElementById('countB').textContent = a.spawnsB;
  const ss = document.getElementById('spawnState');
  const ready = a.spawnsA > 0 && a.spawnsB > 0;
  ss.textContent = ready ? 'Ready' : 'Incomplete';
  ss.className = `card-state ${ready ? 'is-ok' : 'is-bad'}`;

  // loadout
  const ls = document.getElementById('loadoutState');
  ls.textContent = a.usesDefaultLoadout ? 'Default' : 'Custom';
  ls.className = 'card-state';
  document.getElementById('useDefaultLoadout').checked = a.usesDefaultLoadout;
  document.getElementById('loadoutEditor').style.display = a.usesDefaultLoadout ? 'none' : '';

  if (!loadoutRows.length || loadoutRows.__arena !== a.id) {
    loadoutRows = (a.loadout || []).map(i => ({ name: i.name, count: i.count }));
    loadoutRows.__arena = a.id;
  }
  renderLoadout();

  // settings — these show STATE. New arenas are created switched on, so this
  // should read ON the moment you make one.
  // Instances matter more than the raw bucket number now.
  document.getElementById('bucketState').textContent =
    `${a.running || 0} of ${a.instances || 1} running`;

  const enableBtn = document.getElementById('enableBtn');
  enableBtn.classList.toggle('is-on', !!a.enabled);
  document.getElementById('enableValue').textContent = a.enabled ? 'ON' : 'OFF';

  const wallBtn = document.getElementById('wallBtn');
  wallBtn.classList.toggle('is-on', a.showWall !== false);
  document.getElementById('wallValue').textContent = a.showWall !== false ? 'ON' : 'OFF';

  document.getElementById('editMeta').textContent =
    `${a.enabled ? 'On' : 'Off'} · ${a.occupants} inside · ${a.free ?? 0} free`;
}

function renderLoadout() {
  const host = document.getElementById('loadoutList');
  host.innerHTML = loadoutRows.map((r, i) => `
    <div class="item-row">
      <input type="text" value="${esc(r.name)}" placeholder="Item name" data-li="${i}" data-key="name">
      <input type="number" value="${r.count || 1}" placeholder="How many" data-li="${i}" data-key="count">
      <button class="row-del" data-dl="${i}" title="Remove">&#10005;</button>
    </div>`).join('');
}

function renderOccupants() {
  const host = document.getElementById('occupantTable');
  const list = state.occupants || [];

  if (!list.length) {
    host.innerHTML = `<p class="empty">Nobody is in an arena.</p>`;
    return;
  }

  host.innerHTML = list.map(o => {
    const arena = state.arenas.find(a => a.id === o.arenaId);
    return `<div class="row">
      <div>
        <span class="row-name">${esc(o.name)}</span>
        <span class="row-sub">${esc(arena ? arena.name : 'unknown')} · Team ${esc(o.team || '?')}</span>
      </div>
      <span class="row-sub">id ${o.id}</span>
      <button class="mini mini-danger" data-pull="${o.id}">Pull out</button>
    </div>`;
  }).join('');
}

function render() {
  const pill = document.getElementById('statusPill');
  const text = document.getElementById('statusText');
  const live = (state.occupants || []).length;

  pill.className = 'pill ' + (live > 0 ? 'pill-live' : 'pill-idle');
  text.textContent = live > 0
    ? `${live} in play`
    : (state.arenas.length ? `${state.arenas.length} arena${state.arenas.length === 1 ? '' : 's'}` : 'No arenas');

  renderList();
  renderEdit();
  renderOccupants();
}

/* ── actions ───────────────────────────────────────────── */

async function createArena() {
  const name = `Arena ${state.arenas.length + 1}`;
  const res = await post('createArena', { name });
  if (res.id) { selected = res.id; loadoutRows = []; }
  flash(res.message || 'Created.', !res.ok);
}

document.getElementById('newArenaBtn').addEventListener('click', createArena);
document.getElementById('newArenaBtn2').addEventListener('click', createArena);

document.getElementById('closeBtn').addEventListener('click', () => {
  root.classList.add('hidden');
  post('close');
});

// Step out to walk somewhere without the cursor trapping you.
document.getElementById('minBtn').addEventListener('click', () => {
  root.classList.add('hidden');
  minibar.classList.remove('hidden');
  post('minimise');
});

document.getElementById('restoreBtn').addEventListener('click', () => {
  minibar.classList.add('hidden');
  root.classList.remove('hidden');
  post('restore');
});

// Escape is handled centrally at the bottom of this file, in stacking order.
// This was on keyup, so it fired AFTER the keydown handler had already closed
// whatever was on top -- one press, two panels gone.

document.addEventListener('click', async e => {
  // Note: [data-arena] is also the room's arena picker, so this only counts
  // inside the admin rail.
  const pick = e.target.closest('.arena-item[data-arena]');
  if (pick) {
    selected = Number(pick.dataset.arena);
    loadoutRows = [];

    // Clicking an arena means you want the editor, not whatever admin view
    // was up -- and the tab highlight has to follow.
    adminView = 'arena';
    document.querySelectorAll('[data-atab]').forEach(b => b.classList.remove('is-active'));

    render();
    return;
  }

  const spawn = e.target.closest('[data-spawn]');
  if (spawn && selected) {
    const res = await post('addSpawn', { id: selected, team: spawn.dataset.spawn });
    flash(res.message || 'Spawn added.', !res.ok);
    return;
  }

  const clearSp = e.target.closest('[data-clearspawn]');
  if (clearSp && selected) {
    const res = await post('clearSpawns', { id: selected, team: clearSp.dataset.clearspawn });
    flash(res.message || 'Cleared.', !res.ok);
    return;
  }

  const test = e.target.closest('[data-test]');
  if (test && selected) {
    const res = await post('testEnter', { id: selected, team: test.dataset.test, loadout: true });
    flash(res.message || 'Sent in.', !res.ok);
    if (res.ok) {
      root.classList.add('hidden');
      minibar.classList.remove('hidden');
      post('minimise');
    }
    return;
  }

  const pull = e.target.closest('[data-pull]');
  if (pull) {
    const res = await post('pullOut', { player: Number(pull.dataset.pull) });
    flash(res.message || 'Pulled out.', !res.ok);
    return;
  }

  const del = e.target.closest('#deleteBtn');
  if (del && selected) {
    const res = await post('deleteArena', { id: selected });
    if (res.ok) { selected = null; loadoutRows = []; }
    flash(res.message || 'Deleted.', !res.ok);
    return;
  }

  const dl = e.target.closest('[data-dl]');
  if (dl) {
    loadoutRows.splice(Number(dl.dataset.dl), 1);
    renderLoadout();
    return;
  }

  const addRow = e.target.closest('#addLoadoutRow');
  if (addRow) {
    loadoutRows.push({ name: '', count: 1 });
    renderLoadout();
    return;
  }

  const saveL = e.target.closest('#saveLoadoutBtn');
  if (saveL && selected) {
    const res = await post('setLoadout', {
      id: selected,
      useDefault: document.getElementById('useDefaultLoadout').checked,
      items: loadoutRows
    });
    flash(res.message || 'Saved.', !res.ok);
    return;
  }

  // plain actions that just need the arena id
  const act = e.target.closest('[data-act]');
  if (act) {
    const name = act.dataset.act;

    // Marking happens in the world, not in here -- the panel gets out of the
    // way so you can walk the shape.
    if (name === 'startMarking') {
      if (!selected) { flash('Pick an arena first.', true); return; }
      await fetch(`https://${RES}/startMarking`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: selected })
      });
      return;
    }

    const payload = { id: selected };
    if (name === 'renameArena') payload.name = document.getElementById('arenaName').value.trim();
    const res = await post(name, payload);
    flash(res.message || 'Done.', !res.ok);
  }
});

document.addEventListener('input', e => {
  const li = e.target.closest('[data-li]');
  if (li) {
    const i = Number(li.dataset.li);
    const key = li.dataset.key;
    if (loadoutRows[i]) {
      loadoutRows[i][key] = key === 'name' ? li.value : (Number(li.value) || 1);
    }
  }
});

document.getElementById('useDefaultLoadout').addEventListener('change', e => {
  document.getElementById('loadoutEditor').style.display = e.target.checked ? 'none' : '';
});

/* ── inbound ───────────────────────────────────────────── */

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'open') {
    Object.assign(state, d.state || {});
    minibar.classList.add('hidden');
    root.classList.remove('hidden');
    ctrlWatch(true);
    if (!selected && state.arenas && state.arenas.length) selected = state.arenas[0].id;
    render();
  }

  if (d.action === 'close') {
    root.classList.add('hidden');
    minibar.classList.add('hidden');
  }

  if (d.action === 'minimised') {
    root.classList.add('hidden');
    minibar.classList.remove('hidden');
  }

  if (d.action === 'update') {
    Object.assign(state, d.state || {});
    if (selected && !state.arenas.some(a => a.id === selected)) selected = null;
    render();
  }
});

/* ============================================================
   PLAYER PANEL + IN-MATCH UI
   ============================================================ */

const P = {
  state: null,
  party: null,
  mode: null,
  score: null,
  weapons: { primary: null, sidearm: null },
  pending: null,
  voteFor: null
};

const pRoot = document.getElementById('pRoot');
const aHud = document.getElementById('aHud');

function pFlash(msg, bad) {
  const el = document.getElementById('pFoot');
  if (!el) return;
  el.textContent = msg;
  el.parentElement.classList.remove('is-flash', 'is-error');
  el.parentElement.classList.add(bad ? 'is-error' : 'is-flash');
  setTimeout(() => {
    el.parentElement.classList.remove('is-flash', 'is-error');
    el.textContent = 'Ready';
  }, 3600);
}

async function pPost(name, payload = {}) {
  try {
    const res = await fetch(`https://${RES}/player`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ name, payload })
    });
    return await res.json().catch(() => ({}));
  } catch (e) {
    pFlash('Could not reach the server.', true);
    return {};
  }
}

/* Where an item's picture comes from.
   
   Our own html/items/ first, then ox_inventory's images. That order matters:
   items that only exist in this script (RZ Coin, goggles, smoke juice) ship
   their own picture here, so they work whether or not anyone has added them
   to ox_inventory -- and they never will need to be, because this inventory
   is our own storage, not ox's.
   
   Anything already in ox keeps using ox's image, so weapons and medkits look
   exactly like they do in the city. */
const OWN_IMAGES = new Set([
  'rz_coin',        // shipped
  'naija_slurpy',   // shipped
  'n46_gummies',    // shipped
  // Add the id here once you drop the png in html/items/. Until then they
  // fall through to ox, which is the better default: an item that also
  // exists in the city should look the same in both places, and one that
  // does not just shows its name rather than a broken image.
]);

function oxImage(id, oxPath) {
  if (!id) return '';
  const s = String(id);
  if (s.includes('://') || s.startsWith('assets/')) return s;

  const name = s.includes('.') ? s : `${s}.png`;
  const bare = s.replace(/\.[^.]+$/, '');

  if (OWN_IMAGES.has(bare)) return `items/${name}`;

  return `${oxPath || 'nui://ox_inventory/web/images'}/${name}`;
}

/* ── render ────────────────────────────────────────────── */

function pIsLeader() {
  if (!P.party) return true;              // solo counts as your own leader
  const me = P.party.members.find(m => m.leader);
  return me ? me.name === P.state.name : false;
}

function renderModes() {
  const host = document.getElementById('pModes');
  const st = P.state;
  if (!host || !st) return;

  const locked = P.party && !pIsLeader();

  host.innerHTML = st.modes.map(m => `
    <div class="mode-card ${P.mode === m.id ? 'is-on' : ''}" data-mode="${m.id}"
         style="${locked ? 'pointer-events:none;opacity:.5' : ''}">
      <span class="mode-name">${esc(m.label)}</span>
      <span class="mode-queued">${(st.queue || {})[m.id] || 0} queued</span>
    </div>`).join('');

  const mode = st.modes.find(m => m.id === P.mode) || st.modes[0];
  const scores = document.getElementById('pScores');
  if (scores && mode) {
    scores.innerHTML = (mode.scores || []).map(sc => `
      <div class="score-card ${P.score === sc ? 'is-on' : ''}" data-score="${sc}"
           style="${locked ? 'pointer-events:none;opacity:.5' : ''}">${sc}</div>`).join('');
  }

  document.getElementById('pLeaderNote').textContent =
    locked ? 'Only the party leader can change these.' : '';
}

/* With own-weapons on there is nothing to choose -- you fight with what you
   bought. The section is hidden rather than removed, so flipping the config
   back brings it straight back. */
function weaponsPickable() {
  return !(P.state && P.state.ownWeapons);
}

function renderWeapons() {
  const wrap = document.getElementById('pWeapons');
  const own = document.getElementById('pOwnWeapons');
  if (wrap) wrap.classList.toggle('hidden', !weaponsPickable());
  if (own) own.classList.toggle('hidden', weaponsPickable());
  if (!weaponsPickable()) return;

  const st = P.state;
  if (!st) return;
  const locked = P.party && !pIsLeader();

  ['primary', 'sidearm'].forEach(slot => {
    const host = document.getElementById(slot === 'primary' ? 'pPrimary' : 'pSidearm');
    if (!host) return;
    host.innerHTML = (st.weapons[slot] || []).map(w => `
      <div class="wep-card ${P.weapons[slot] === w.id ? 'is-on' : ''}" data-wep="${w.id}" data-slot="${slot}"
           style="${locked ? 'pointer-events:none;opacity:.5' : ''}">
        <img src="${esc(oxImage(w.id, st.oxPath))}" alt="" onerror="this.style.visibility='hidden'">
        <span>${esc(w.label)}</span>
      </div>`).join('');
  });
}

function renderPlayer() {
  const st = P.state;
  if (!st) return;

  P.party = st.party;

  /* Same guard as the weapon lists below. Config.Modes should never be empty
     -- but if it ever is, an unguarded [0].id here kills the whole panel the
     same way, and a config with no modes should show an empty panel rather
     than a broken one. */
  const modes = st.modes || [];

  if (!P.mode) P.mode = (P.party && P.party.mode) || (modes[0] && modes[0].id);
  if (P.party) P.mode = P.party.mode;

  const mode = modes.find(m => m.id === P.mode) || modes[0];
  if (!P.score) P.score = (P.party && P.party.score) || (mode && mode.defaultScore);
  if (P.party) P.score = P.party.score;

  if (P.party && P.party.weapons) P.weapons = { ...P.weapons, ...P.party.weapons };
  /* Guarded, because either list can legitimately be EMPTY.
     With the rifles gone, Config.Weapons.primary is {} -- so primary[0] is
     undefined and reading .id off it throws. This line runs before the hero
     name, the mode row and the score row, so that one throw took the whole
     panel down: no name, no 1v1/2v2/3v3, no First to, and a Join queue button
     with nothing to queue for. The section headings are static markup, which
     is why the panel still looked half-built rather than empty.

     false means "this slot has nothing", which is what DefaultRoomWeapons
     already uses and what the rest of the code understands. */
  const firstOf = list => (list && list[0] && list[0].id) || false;

  if (!P.weapons.primary) P.weapons.primary = firstOf(st.weapons && st.weapons.primary);
  if (!P.weapons.sidearm) P.weapons.sidearm = firstOf(st.weapons && st.weapons.sidearm);

  const s = st.stats || {};
  document.getElementById('pRecord').textContent = `${s.wins || 0}W · ${s.losses || 0}L`;

  // The hero row. Real numbers only -- an empty record says so rather than
  // showing zeroes dressed up as a rating.
  const wins = s.wins || 0, losses = s.losses || 0;
  const played = wins + losses;

  document.getElementById('heroName').textContent = st.name || '—';
  document.getElementById('heroSub').textContent = played
    ? `${played} match${played === 1 ? '' : 'es'} played`
    : 'No matches yet';

  document.getElementById('heroWins').textContent = wins;
  document.getElementById('heroLosses').textContent = losses;
  document.getElementById('heroRate').textContent =
    played ? `${Math.round((wins / played) * 100)}%` : '0%';
  document.getElementById('heroPoints').textContent = s.points || 0;

  document.getElementById('heroMeter').style.width =
    `${Math.min(100, (played / 10) * 100)}%`;

  // Whether YOU are queued, from the server -- not read off a party, which
  // most people do not have, which is why the Leave button never appeared.
  const queued = !!(st.queuedIn) || (P.party ? P.party.queued : false);
  document.getElementById('pQueueBtn').classList.toggle('hidden', queued);
  document.getElementById('pLeaveQueueBtn').classList.toggle('hidden', !queued);

  const total = Object.values(st.queue || {}).reduce((a, b) => a + b, 0);
  document.getElementById('pQueueTally').textContent =
    total ? `${total} waiting to play` : 'Nobody in the queue';
  document.getElementById('pRailPlay').textContent = queued ? 'In the queue' : mode.label;

  renderModes();
  renderWeapons();
  updateBackBtn();
}

let boardKind = 'pvp';

/* The match leaderboard. */
async function loadBoard() {
  const res = await pPost('leaderboard');

  const host = document.getElementById('pBoard');
  const rows = res.board || [];
  const me = P.state ? P.state.name : null;

  const ratio = (a, b) => (b > 0 ? (a / b) : a).toFixed(2);
  const level = p => Math.max(1, Math.floor(Math.sqrt((p || 0) / 40)) + 1);

  document.getElementById('lbColA').textContent = 'W';
  document.getElementById('lbColB').textContent = 'L';

  document.getElementById('boardNote').textContent =
    'Wins, losses and war points from matches and rooms.';

  host.innerHTML = rows.length
    ? rows.map((r, i) => `
        <div class="lb-row r${i + 1} ${r.name === me ? 'is-you' : ''}">
          <span class="lb-rank">${i + 1}</span>
          <span class="lb-player">
            <span class="lb-lv">Lv ${level(r.points)}</span>
            <span class="lb-name">${esc(r.name || 'Unknown')}</span>
          </span>
          <span class="lb-num k">${r.kills || 0}</span>
          <span class="lb-num d">${r.deaths || 0}</span>
          <span class="lb-num">${ratio(r.kills || 0, r.deaths || 0)}</span>
          <span class="lb-num w">${r.wins || 0}</span>
          <span class="lb-num l">${r.losses || 0}</span>
          <span class="lb-num pts">${r.points || 0}</span>
        </div>`).join('')
    : `<p class="empty">Nobody has finished a match yet.</p>`;

  const y = res.you || {};
  document.getElementById('pYou').textContent =
    `${y.points || 0} pts · ${y.wins || 0}W ${y.losses || 0}L · ${y.kills || 0} kills`;
}

document.addEventListener('click', e => {
  const sw = e.target.closest('[data-board]');
  if (!sw) return;

  boardKind = sw.dataset.board;
  document.querySelectorAll('[data-board]').forEach(b => b.classList.remove('is-on'));
  sw.classList.add('is-on');
  loadBoard();
});

/* ── events ────────────────────────────────────────────── */

document.querySelectorAll('[data-ptab]').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('[data-ptab]').forEach(b => b.classList.remove('is-active'));
    document.querySelectorAll('.ppanel').forEach(p => p.classList.remove('is-active'));
    btn.classList.add('is-active');
    document.querySelector(`[data-ppanel="${btn.dataset.ptab}"]`).classList.add('is-active');
    if (btn.dataset.ptab === 'board') loadBoard();
  });
});

/* Back to lobby.
   In a match this hands the other side the win, so it asks once. Everywhere
   else there's nothing to lose and it just goes. */
const backBtn = document.getElementById('backToLobby');
let backArmed = false;

function resetBack() {
  backArmed = false;
  if (!backBtn) return;
  backBtn.classList.remove('is-confirm');
  backBtn.textContent = 'Back to lobby';
}

function updateBackBtn() {
  if (!backBtn) return;

  const inMatch = !!(P.state && P.state.inMatch);
  const inZone = !!(P.state && P.state.inZone);

  backBtn.classList.toggle('hidden', !inMatch && !inZone);
  if (!inMatch && !inZone) resetBack();
}

if (backBtn) {
  backBtn.addEventListener('click', async () => {
    const inMatch = !!(P.state && P.state.inMatch);

    // Only a match costs anything, so only a match asks.
    if (inMatch && !backArmed) {
      backArmed = true;
      backBtn.classList.add('is-confirm');
      backBtn.textContent = 'They take the win — sure?';
      setTimeout(resetBack, 5000);
      return;
    }

    await fetch(`https://${RES}/backToLobby`, { method: 'POST', body: '{}' });
    resetBack();
    pRoot.classList.add('hidden');
    fetch(`https://${RES}/closePlayer`, { method: 'POST', body: '{}' });
  });
}

document.getElementById('pClose').addEventListener('click', () => {
  pRoot.classList.add('hidden');
  fetch(`https://${RES}/closePlayer`, { method: 'POST', body: '{}' });
});

document.addEventListener('click', async e => {
  const mode = e.target.closest('[data-mode]');
  if (mode) {
    P.mode = mode.dataset.mode;
    const m = P.state.modes.find(x => x.id === P.mode);
    P.score = m ? m.defaultScore : P.score;
    if (P.party) {
      const r = await pPost('setMode', { mode: P.mode });
      if (r.state) { P.state = r.state; }
      pFlash(r.message || '', !r.ok);
    }
    renderPlayer();
    return;
  }

  const sc = e.target.closest('[data-score]');
  if (sc) {
    P.score = Number(sc.dataset.score);
    if (P.party) await pPost('setScore', { score: P.score });
    renderModes();
    return;
  }

  const wep = e.target.closest('[data-wep]');
  if (wep) {
    P.weapons[wep.dataset.slot] = wep.dataset.wep;
    if (P.party) await pPost('setWeapon', { slot: wep.dataset.slot, weapon: wep.dataset.wep });
    renderWeapons();
    return;
  }

  const invite = e.target.closest('[data-invite]');
  if (invite) {
    const r = await pPost('invite', { player: Number(invite.dataset.invite) });
    pFlash(r.message || '', !r.ok);
    return;
  }

  const kick = e.target.closest('[data-kick]');
  if (kick) {
    const r = await pPost('kick', { key: kick.dataset.kick });
    if (r.state) { P.state = r.state; renderPlayer(); }
    pFlash(r.message || '', !r.ok);
  }
});

const pBtn = (id, name, payload) => {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('click', async () => {
    const body = typeof payload === 'function' ? payload() : (payload || {});
    const r = await pPost(name, body);
    if (r.state) { P.state = r.state; renderPlayer(); }
    pFlash(r.message || '', !r.ok);
  });
};

pBtn('pQueueBtn', 'joinQueue', () => ({ mode: P.mode }));
pBtn('pLeaveQueueBtn', 'leaveQueue');

/* ── ready check ───────────────────────────────────────── */

let readyAnim = null;

function showReady(d) {
  P.pending = d.id;
  document.getElementById('readyMode').textContent = d.mode || 'Match';
  document.getElementById('readyCount').textContent = 'Waiting for everyone';
  document.getElementById('readyCheck').classList.remove('hidden');

  const bar = document.getElementById('readyBar');
  if (readyAnim) readyAnim.cancel();
  readyAnim = bar.animate([{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }],
    { duration: (d.seconds || 20) * 1000, easing: 'linear', fill: 'forwards' });
}

function hideReady() {
  document.getElementById('readyCheck').classList.add('hidden');
  document.querySelector('.ready-btns').style.display = '';
  if (readyAnim) { readyAnim.cancel(); readyAnim = null; }
}

function hideVote() {
  document.getElementById('mapVote').classList.add('hidden');
  if (voteAnim) { voteAnim.cancel(); voteAnim = null; }

  // Stop the countdown, or it keeps ticking against a hidden element for the
  // rest of the session.
  if (voteTick) { clearInterval(voteTick); voteTick = null; }
}

// Everything that can hold the screen, closed in one call. Individual paths
// kept missing one -- matchStarting hid the vote but not the ready card, so
// on the common path (one arena, no vote) it sat there for the whole match.
// Closes the transient overlays only. The builder panel (#root) is left
// alone: it's open because an admin opened it, and a match starting is no
// reason to yank it away mid-edit.
function hideAllModals() {
  const found = document.getElementById('matchFound');
  if (found) found.classList.add('hidden');

  hideReady();
  hideVote();
  pRoot.classList.add('hidden');
  const toast = document.getElementById('inviteToast');
  if (toast) toast.classList.add('hidden');
}

document.getElementById('readyAccept').addEventListener('click', () => {
  fetch(`https://${RES}/ready`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: P.pending, accept: true })
  });
  document.getElementById('readyCount').textContent = 'Waiting for the others…';
  document.querySelector('.ready-btns').style.display = 'none';

  // If the server goes quiet, the card must not sit there forever holding
  // the screen. Well past any ready-check timeout.
  clearTimeout(window.__readyGuard);
  window.__readyGuard = setTimeout(hideAllModals, 45000);
});

document.getElementById('readyDecline').addEventListener('click', () => {
  fetch(`https://${RES}/ready`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: P.pending, accept: false })
  });
  clearTimeout(window.__readyGuard);
  hideAllModals();
});

/* ── map vote ──────────────────────────────────────────── */

let voteAnim = null;
let voteTick = null;

function showVote(d) {
  P.pending = d.id;
  P.voteFor = null;

  const grid = document.getElementById('voteGrid');
  const arenas = d.arenas || [];

  // Side by side up to five. Past that they get too narrow to read, so they
  // wrap instead of shrinking into slivers.
  grid.classList.toggle('is-many', arenas.length > 5);

  grid.innerHTML = arenas.map(a => `
    <div class="vote-option" data-vote="${a.id}">
      <div class="vote-thumb">
        ${a.image ? `<img src="${esc(a.image)}" alt="" onerror="this.remove()">`
                  : `<span class="vote-fallback">${esc((a.name || '?').charAt(0).toUpperCase())}</span>`}
        <span class="vote-votes" data-votes="${a.id}">0</span>
        <span class="vote-share"><i data-share="${a.id}"></i></span>
      </div>
      <span class="vote-name">${esc(a.name)}</span>
    </div>`).join('');

  document.getElementById('mapVote').classList.remove('hidden');

  // Seconds remaining, counted down. The bar shows the shape of the wait;
  // the number tells you whether you have time to think.
  const clock = document.getElementById('voteClock');
  let left = Math.max(0, Math.round(d.seconds || 0));

  if (clock) {
    clock.textContent = left + 's';
    clearInterval(voteTick);
    voteTick = setInterval(() => {
      left -= 1;
      if (left <= 0) { clearInterval(voteTick); clock.textContent = '0s'; return; }
      clock.textContent = left + 's';
    }, 1000);
  }

  const bar = document.getElementById('voteBar');
  if (voteAnim) voteAnim.cancel();
  voteAnim = bar.animate([{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }],
    { duration: (d.seconds || 15) * 1000, easing: 'linear', fill: 'forwards' });
}

document.addEventListener('click', e => {
  const v = e.target.closest('[data-vote]');
  if (!v) return;
  P.voteFor = Number(v.dataset.vote);
  document.querySelectorAll('[data-vote]').forEach(x => x.classList.remove('is-on'));
  v.classList.add('is-on');
  document.getElementById('voteHint').textContent = 'Vote cast';
  clearTimeout(window.__voteGuard);
  window.__voteGuard = setTimeout(hideAllModals, 45000);
  fetch(`https://${RES}/vote`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: P.pending, arena: P.voteFor })
  });
});

/* ── in-match ──────────────────────────────────────────── */

let aBannerTimer = null;

function aBanner(eyebrow, title, sub, accent, hold) {
  const el = document.getElementById('aBanner');
  el.style.setProperty('--accent', accent || '#C9A227');
  document.getElementById('aBannerEyebrow').textContent = eyebrow || '';
  document.getElementById('aBannerTitle').textContent = title || '';
  document.getElementById('aBannerSub').textContent = sub || '';

  // A banner alone does not decide what else is on screen -- whoever called
  // it already did that.
  aHud.classList.remove('hidden');
  clearTimeout(aBannerTimer);
  void el.offsetWidth;
  el.classList.add('is-in');
  aBannerTimer = setTimeout(() => el.classList.remove('is-in'), hold || 4000);
}

function renderRoster(host, players, slots) {
  const el = document.getElementById(host);
  if (!el) return;
  const list = players || [];
  let out = '';
  for (let i = 0; i < slots; i++) {
    const p = list[i];
    if (!p) {
      out += `<div class="sb-slot empty"><div class="sb-av"></div><div class="sb-life"><i></i></div></div>`;
    } else {
      out += `<div class="sb-slot ${p.alive === false ? 'dead' : 'alive'}">
        <div class="sb-av">${esc((p.name || '?').charAt(0).toUpperCase())}</div>
        <div class="sb-life"><i></i></div>
      </div>`;
    }
  }
  el.innerHTML = out;
}

/* The HUD is one container holding the banner, the scoreboard, the kill feed
   and the hotbar.
   scoreboard too, still displaying "1v1  TO 7" from whatever match ran last.

   So there is one place that decides what's on, and callers say which mode
   they're in rather than each reaching for the container. */
function showHud(mode) {
  aHud.classList.remove('hidden');

  const board = document.getElementById('scoreboard');
  if (board) board.classList.toggle('hidden', mode !== 'match');
}

function hideHud() {
  aHud.classList.add('hidden');
  const board = document.getElementById('scoreboard');
  if (board) board.classList.add('hidden');
}

/* "You received X" cards.
   One per add, stacked upward, oldest dropped once the stack is full. The
   server decides whether to send one at all -- this only draws what arrives,
   so filtering rules live in config rather than in here. */

/* ============================================================
   WORLD LAYER
   ============================================================
   The client sends screen coordinates as 0-1 fractions of the viewport, so
   nothing in here needs to know the resolution and it survives the player
   changing it mid-session. */

function placeAt(el, x, y) {
  el.style.left = (Number(x) * 100) + '%';
  el.style.top  = (Number(y) * 100) + '%';
}

/* Rebuilt only when the prompt CHANGES -- walking up to a different ped, or
   an option appearing. Moving is just two style writes, because rebuilding
   the markup sixty times a second is what makes a prompt flicker. */
function promptShow(d) {
  const el = document.getElementById('prompt3d');
  if (!el || !d) return;

  document.getElementById('p3Title').textContent = d.title || '';

  const rows = document.getElementById('p3Rows');
  rows.innerHTML = (d.rows || []).map(r => `
    <div class="p3-row">
      <span class="p3-key">${esc(r.key || 'E')}</span>
      <span class="p3-label">${esc(r.label || '')}</span>
    </div>`).join('');

  placeAt(el, d.x, d.y);
  el.classList.remove('hidden');
}

function promptMove(d) {
  const el = document.getElementById('prompt3d');
  if (!el || !d || el.classList.contains('hidden')) return;
  placeAt(el, d.x, d.y);
}

function promptHide() {
  const el = document.getElementById('prompt3d');
  if (el) el.classList.add('hidden');
}

/* Podium labels. At most three, so they are rebuilt wholesale rather than
   diffed -- three elements is cheaper to replace than to reconcile. */
function renderPodium(d) {
  const wrap = document.getElementById('podiumLabels');
  if (!wrap) return;

  const items = (d && d.items) || [];
  if (!items.length) { wrap.innerHTML = ''; return; }

  wrap.innerHTML = items.map(it => `
    <div class="pod-label" data-rank="${Number(it.rank) || 0}"
         style="left:${(Number(it.x) * 100)}%; top:${(Number(it.y) * 100)}%">
      <span class="pod-rank">#${Number(it.rank) || 0}</span>
      <span class="pod-name">${esc(it.name || '')}</span>
      <span class="pod-score">${it.score != null ? esc(it.score) + ' RATING' : ''}</span>
    </div>`).join('');
}

function pushItemToast(d) {
  if (!d || !d.item) return;

  const wrap = document.getElementById('itemToasts');
  if (!wrap) return;

  const el = document.createElement('div');
  el.className = 'itoast';
  el.innerHTML = `
    <div class="itoast-img">
      <img src="${esc(oxImage(d.image || d.item, d.oxPath))}" alt=""
           onerror="this.style.visibility='hidden'">
    </div>
    <div class="itoast-text">
      <span class="itoast-label">${esc(d.label || d.item)}</span>
      <span class="itoast-sub">received</span>
    </div>
    <span class="itoast-count">+${Number(d.count) || 1}</span>`;

  wrap.appendChild(el);

  /* Next frame, so the browser has laid the card out before the class that
     transitions it in. Setting both in one go skips the animation. */
  requestAnimationFrame(() => el.classList.add('in'));

  /* Oldest first -- column-reverse means the first child is the bottom one. */
  const max = Number(d.max) || 4;
  while (wrap.children.length > max) wrap.removeChild(wrap.firstChild);

  const ttl = Number(d.ttl) || 3200;
  setTimeout(() => {
    el.classList.remove('in');
    /* Longer than the transition, so it is gone before it is removed. */
    setTimeout(() => el.remove(), 300);
  }, ttl);
}

function renderHotbar(d) {
  const el = document.getElementById('hotbar');
  if (!el) return;

  if (!d || !d.show) { el.classList.add('hidden'); return; }
  el.classList.remove('hidden');

  // The hotbar is a view of the first inventory slots. An empty slot stays
  // visible so the numbering never shifts under your fingers mid-fight.
  el.innerHTML = (d.slots || []).map(s => `
    <div class="hb-slot ${s.selected ? 'is-sel' : ''} ${s.empty ? 'is-empty' : ''} ${(s.selected && d.holstered) ? 'is-holstered' : ''}"
         data-hb="${s.id}">
      <span class="hb-key">${esc(s.key)}</span>
      ${s.empty
        ? '<span class="hb-none">&#8212;</span>'
        : `<img src="${esc(oxImage(s.image || s.name, d.oxPath))}" alt=""
                onerror="this.style.visibility='hidden'">`}
      ${(!s.empty && !s.weapon && s.charges !== null && s.charges !== undefined)
        ? `<span class="hb-qty">${s.charges}</span>` : ''}
      ${(!s.empty && s.weapon) ? `<span class="hb-ammo" data-ammo="${s.id}"></span>` : ''}
    </div>`).join('');
}


/* ── invites ───────────────────────────────────────────── */

let inviteCode = null;
let inviteTimer = null;

let inviteBarAnim = null;

function showInvite(d) {
  inviteCode = d.code;
  document.getElementById('inviteFrom').textContent = d.from || 'Someone';
  document.getElementById('inviteMode').textContent = d.mode || '';
  document.getElementById('inviteYesKey').textContent = d.acceptLabel || 'Y';
  document.getElementById('inviteNoKey').textContent = d.declineLabel || 'N';

  const toast = document.getElementById('inviteToast');
  toast.classList.remove('hidden');

  // The bar draining is the countdown -- no numbers to read while you're
  // being shot at.
  const bar = document.getElementById('inviteBar');
  if (inviteBarAnim) inviteBarAnim.cancel();
  inviteBarAnim = bar.animate(
    [{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }],
    { duration: (d.seconds || 30) * 1000, easing: 'linear', fill: 'forwards' });

  clearTimeout(inviteTimer);
  inviteTimer = setTimeout(hideInvite, (d.seconds || 30) * 1000);
}

function hideInvite() {
  document.getElementById('inviteToast').classList.add('hidden');
  clearTimeout(inviteTimer);
  if (inviteBarAnim) { inviteBarAnim.cancel(); inviteBarAnim = null; }
}

/* ── inbound ───────────────────────────────────────────── */

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'openPlayer') {
    P.state = d.state;
    pRoot.classList.remove('hidden');
    renderPlayer();
  }

  if (d.action === 'closePlayer') pRoot.classList.add('hidden');

  if (d.action === 'playerUpdate') {
    P.state = d.state;
    if (!pRoot.classList.contains('hidden')) renderPlayer();
  }

  if (d.action === 'party') {
    if (P.state) { P.state.party = d.data; P.party = d.data; }
    if (!pRoot.classList.contains('hidden')) renderPlayer();
  }

  if (d.action === 'invite') showInvite(d.data);
  if (d.action === 'inviteClosed') hideInvite();

  if (d.action === 'readyCheck') {
    pRoot.classList.add('hidden');
    document.querySelector('.ready-btns').style.display = '';
    showReady(d.data);
  }

  if (d.action === 'readyUpdate') {
    document.getElementById('readyCount').textContent =
      `${d.data.ready} of ${d.data.total} accepted`;
  }

  if (d.action === 'matchCancelled') hideAllModals();

  if (d.action === 'matchFound') {
    hideReady();
    document.getElementById('foundMode').textContent = d.data.mode || '';
    document.getElementById('matchFound').classList.remove('hidden');

    // The bar runs down for exactly as long as the card is up, so the wait
    // has a visible end rather than being a guess.
    const bar = document.getElementById('foundBar');
    if (bar && bar.animate) {
      bar.animate([{ transform: 'scaleX(1)' }, { transform: 'scaleX(0)' }],
        { duration: (d.data.seconds || 3) * 1000, easing: 'linear', fill: 'forwards' });
    }
  }

  if (d.action === 'mapVote') {
    hideReady();
    document.getElementById('matchFound').classList.add('hidden');
    showVote(d.data);
  }

  // Hard release, from the /rzunstick failsafe.
  // The backstop. Everything goes, not just the modals -- this fires when
  // the page has stopped responding to Escape, so leaving the main panels up
  // would defeat the point of having a fallback at all.
  if (d.action === 'forceClose') {
    hideAllModals();
    ['pRoot', 'rankedRoot', 'shopRoot', 'invRoot', 'root', 'ctxBox', 'splitBox']
      .forEach(id => {
        const el = document.getElementById(id);
        if (el) el.classList.add('hidden');
      });
  }

  if (d.action === 'voteUpdate') {
    const tally = d.data || {};
    const counts = Object.values(tally).map(Number);
    const total = counts.reduce((a, b) => a + b, 0);
    const best = Math.max(0, ...counts);

    Object.entries(tally).forEach(([id, n]) => {
      const el = document.querySelector(`[data-votes="${id}"]`);
      if (el) el.textContent = n;

      // A bar under each option, so the split reads at a glance rather than
      // having to compare four numbers.
      const share = document.querySelector(`[data-share="${id}"]`);
      if (share) share.style.width = total ? `${(Number(n) / total) * 100}%` : '0%';

      // And mark whichever is winning -- with a tie, nothing is marked,
      // because calling two things "leading" tells you nothing.
      const card = document.querySelector(`[data-vote="${id}"]`);
      if (card) {
        const clear = best > 0 && Number(n) === best && counts.filter(c => c === best).length === 1;
        card.classList.toggle('is-leading', clear);
      }
    });
  }

  if (d.action === 'matchStarting') {
    hideAllModals();
    aBanner('Arena', d.data.arena, `Starting in ${d.data.seconds}s`, '#16E45F', (d.data.seconds || 5) * 1000);
  }

  if (d.action === 'matchBegin') {
    hideAllModals();
    showHud('match');
    document.getElementById('sbMode').textContent = d.data.mode || '';
    document.getElementById('sbTarget').textContent = `to ${d.data.score || 0}`;
    document.getElementById('sbScoreA').textContent = '0';
    document.getElementById('sbScoreB').textContent = '0';

    const per = Math.max(1, (d.data.roster || []).filter(r => r.team === 'A').length);
    renderRoster('sbRosterA', (d.data.roster || []).filter(r => r.team === 'A'), per);
    renderRoster('sbRosterB', (d.data.roster || []).filter(r => r.team === 'B'), per);

    aBanner('Match', 'FIGHT', d.data.arena, '#16E45F', 3500);
  }

  if (d.action === 'matchEnd') {
    // The HUD stays up: the result card lives inside it and is hidden by its
    // own timeout. Hiding it here would take the result with it.
    hideAllModals();
    document.getElementById('hotbar').classList.add('hidden');
    document.getElementById('scoreboard').classList.add('hidden');
  }

  if (d.action === 'hotbar') renderHotbar(d.data);
  if (d.action === 'itemToast') pushItemToast(d.data);
  if (d.action === 'promptShow') promptShow(d.data);
  if (d.action === 'promptMove') promptMove(d.data);
  if (d.action === 'promptHide') promptHide();
  if (d.action === 'podium') renderPodium(d.data);

  if (d.action === 'hotbarAmmo') {
    const el = document.querySelector(`[data-ammo="${d.data.selected}"]`);
    if (el) el.textContent = `${d.data.clip} / ${d.data.reserve}`;
  }
});

/* ============================================================
   IN-MATCH: SCORE, KILL FEED, RESPAWN, RESULT
   ============================================================ */

let respawnTimer = null;

function pushFeed(f) {
  const host = document.getElementById('mfeed');
  if (!host || !f || !f.victim) return;

  let inner;
  if (f.teamkill) {
    inner = `<span class="mfeed-k">${esc(f.killer)}</span>
             <span class="mfeed-x">team killed</span>
             <span class="mfeed-v">${esc(f.victim)}</span>`;
  } else if (f.killer) {
    inner = `<span class="mfeed-k">${esc(f.killer)}</span>
             <span class="mfeed-x">killed</span>
             <span class="mfeed-v">${esc(f.victim)}</span>`;
  } else {
    inner = `<span class="mfeed-v">${esc(f.victim)}</span>
             <span class="mfeed-x">died</span>`;
  }

  const line = document.createElement('div');
  line.className = `mfeed-line ${f.teamkill ? 'is-tk' : (f.team ? 'team-' + f.team.toLowerCase() : '')}`;
  line.innerHTML = inner;
  host.prepend(line);

  while (host.children.length > 5) host.lastElementChild.remove();

  setTimeout(() => {
    line.classList.add('is-out');
    setTimeout(() => line.remove(), 300);
  }, 7000);
}

function applyScore(d) {
  document.getElementById('sbScoreA').textContent = d.scoreA ?? 0;
  document.getElementById('sbScoreB').textContent = d.scoreB ?? 0;
  document.getElementById('sbTarget').textContent = `to ${d.target ?? 0}`;

  const roster = d.roster || [];
  const a = roster.filter(r => r.team === 'A');
  const b = roster.filter(r => r.team === 'B');
  const per = Math.max(1, a.length, b.length);

  renderRoster('sbRosterA', a, per);
  renderRoster('sbRosterB', b, per);

  if (d.feed) pushFeed(d.feed);
}

function showRespawn(seconds) {
  const card = document.getElementById('respawnCard');
  const num = document.getElementById('respawnNum');
  if (!card) return;

  let left = seconds || 5;
  num.textContent = left;
  card.classList.remove('hidden');

  clearInterval(respawnTimer);
  respawnTimer = setInterval(() => {
    left -= 1;
    num.textContent = Math.max(0, left);
    if (left <= 0) clearInterval(respawnTimer);
  }, 1000);

  // Hard stop. The card counts down from the same number the server uses, so
  // if it's still up well past that, something upstream failed and it should
  // not be holding the screen.
  clearTimeout(window.__respawnGuard);
  window.__respawnGuard = setTimeout(hideRespawn, (left + 8) * 1000);
}

function hideRespawn() {
  clearInterval(respawnTimer);
  clearTimeout(window.__respawnGuard);
  const card = document.getElementById('respawnCard');
  if (card) card.classList.add('hidden');
}

function showResult(d) {
  const card = document.getElementById('resultCard');
  if (!card) return;

  card.classList.toggle('is-loss', !d.won);
  document.getElementById('resultTitle').textContent =
    d.winner ? (d.won ? 'VICTORY' : 'DEFEAT') : 'DRAW';

  document.getElementById('resultEyebrow').textContent =
    d.reason === 'forfeit' ? 'Opponent left'
    : d.reason === 'time' ? 'Time up'
    : 'Match over';

  document.getElementById('resultA').textContent = d.scoreA ?? 0;
  document.getElementById('resultB').textContent = d.scoreB ?? 0;

  const rows = (d.roster || [])
    .slice()
    .sort((x, y) => (y.kills || 0) - (x.kills || 0));

  document.getElementById('resultRows').innerHTML = rows.map(r => `
    <div class="result-row team-${(r.team || 'a').toLowerCase()}">
      <span>${esc(r.name)}</span>
      <span>${r.kills || 0} / ${r.deaths || 0}</span>
    </div>`).join('');

  card.classList.remove('hidden');
  void card.offsetWidth;
  card.classList.add('is-in');

  setTimeout(() => {
    card.classList.remove('is-in');
    setTimeout(() => {
      card.classList.add('hidden');
      hideHud();
    }, 450);
  }, ((d.seconds || 10) - 1) * 1000);
}

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'score') applyScore(d.data);

  // Nothing about a match should still be on screen once you're out of one.
  if (d.action === 'hudOff') {
    hideHud();
    hideRespawn();
    document.getElementById('hotbar').classList.add('hidden');
    const p = document.getElementById('protectPill');
    if (p) p.classList.add('hidden');
    const f = document.getElementById('mfeed');
    if (f) f.innerHTML = '';
    const r = document.getElementById('resultCard');
    if (r) { r.classList.add('hidden'); r.classList.remove('is-in'); }
  }

  if (d.action === 'matchDeath') {
    showHud('match');
    showRespawn(d.data.seconds);
  }

  if (d.action === 'matchRespawn') {
    hideRespawn();
    const dc = document.getElementById('downedCard');
    if (dc) dc.classList.add('hidden');
  }

  if (d.action === 'matchDowned') {
    showHud('match');
    hideRespawn();

    const dc = document.getElementById('downedCard');
    const left = d.data.teammatesLeft || 0;

    document.getElementById('downedTitle').textContent =
      left > 0 ? 'Waiting for the round' : 'Round lost';

    const sub = document.getElementById('downedSub');
    sub.textContent = left > 0
      ? `${left} teammate${left === 1 ? '' : 's'} still in it`
      : 'Everyone respawns in a moment';
    sub.classList.toggle('is-last', left === 0);

    dc.classList.remove('hidden');
  }

  if (d.action === 'roundStart') {
    const dc = document.getElementById('downedCard');
    if (dc) dc.classList.add('hidden');
  }

  if (d.action === 'spawnProtection') {
    const p = document.getElementById('protectPill');
    if (p) p.classList.remove('hidden');
  }

  if (d.action === 'spawnProtectionEnd') {
    const p = document.getElementById('protectPill');
    if (p) p.classList.add('hidden');
  }

  if (d.action === 'matchEnd') {
    hideRespawn();
    const p = document.getElementById('protectPill');
    if (p) p.classList.add('hidden');
    const f = document.getElementById('mfeed');
    if (f) f.innerHTML = '';
    if (d.data && d.data.winner !== undefined) showResult(d.data);
  }
});

/* ============================================================
   ROOMS
   A room is a lobby the host controls, with a start button.
   No matchmaking to wait on -- which is also what makes the
   dummies usable, since there is now something to press.
   ============================================================ */

const R = { room: null, rooms: [], arenas: [] };

async function rPost(name, payload = {}) {
  try {
    const res = await fetch(`https://${RES}/room`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ name, payload })
    });
    return await res.json().catch(() => ({}));
  } catch (e) {
    pFlash('Could not reach the server.', true);
    return {};
  }
}

function rApply(res) {
  if (!res) return;
  if (res.room !== undefined) R.room = res.room;
  if (res.rooms) R.rooms = res.rooms;
  // Which arenas are free, for the picker.
  if (res.arenas) R.arenas = res.arenas;
  renderRooms();
  if (res.message) pFlash(res.message, !res.ok);
}

function renderBrowse() {
  const host = document.getElementById('rBrowse');
  if (!host) return;

  document.getElementById('rBrowseTally').textContent =
    R.rooms.length ? `${R.rooms.length} open` : 'none open';

  host.innerHTML = R.rooms.length
    ? R.rooms.map(r => `
        <div class="room-row ${r.size >= r.capacity ? 'is-full' : ''}" data-joinroom="${esc(r.code)}">
          <div>
            <span class="room-row-name">${esc(r.name)}</span>
            <span class="room-row-sub">${esc(r.modeLabel)} · first to ${r.kills}${r.rounds > 1 ? ` · best of ${r.rounds}` : ''} · host ${esc(r.host)}</span>
          </div>
          <span class="room-row-count">${r.size}/${r.capacity}</span>
          <span class="room-row-sub">${esc(r.code)}</span>
        </div>`).join('')
    : `<p class="empty">No public rooms right now. Make one.</p>`;
}

function renderTeam(hostId, side) {
  const el = document.getElementById(hostId);
  if (!el) return;

  const members = (R.room.members || []).filter(m => m.team === side);
  const myName = P.state ? P.state.name : null;

  el.innerHTML = members.length
    ? members.map(m => `
        <div class="room-member ${m.dummy ? 'is-dummy' : ''} ${m.name === myName ? 'is-me' : ''}"
             data-member="${esc(m.key)}">
          <div class="room-member-av">${esc((m.name || '?').charAt(0).toUpperCase())}</div>
          <span class="room-member-name">${esc(m.name)}</span>
          ${m.host ? '<span class="room-member-tag">Host</span>' : ''}
          ${(R.room.isHost && !m.host) ? `<button class="row-del" data-kickroom="${esc(m.key)}">&#10005;</button>` : ''}
        </div>`).join('')
    : `<div class="room-empty">Empty</div>`;
}

function renderRoomSettings() {
  const r = R.room;
  const st = P.state;
  if (!r || !st) return;

  const lock = !r.isHost;
  const dim = lock ? 'pointer-events:none;opacity:.5' : '';

  document.getElementById('rModes').innerHTML = st.modes.map(m => `
    <div class="mode-card ${r.mode === m.id ? 'is-on' : ''}" data-rmode="${m.id}" style="${dim}">
      <span class="mode-name">${esc(m.label)}</span>
      <span class="mode-queued">${m.perTeam}v${m.perTeam}</span>
    </div>`).join('');

  document.getElementById('rRounds').innerHTML = (st.roundOptions || [1, 3, 5]).map(n => `
    <div class="score-card ${r.rounds === n ? 'is-on' : ''}" data-rrounds="${n}" style="${dim}">${n}</div>`).join('');

  document.getElementById('rKills').innerHTML = (st.killOptions || [3, 5, 7]).map(n => `
    <div class="score-card ${r.kills === n ? 'is-on' : ''}" data-rkills="${n}" style="${dim}">${n}</div>`).join('');

  // In rounds mode the number is rounds, not kills, and the best-of setting
  // is meaningless -- so it's hidden rather than left there confusing people.
  const rounds = (st.scoring || 'rounds') === 'rounds';
  const killLabel = document.getElementById('rKillsLabel');
  if (killLabel) {
    killLabel.textContent = rounds
      ? 'Rounds to win the match'
      : 'Kills to win a round';
  }
  const roundsBlock = document.getElementById('rRoundsBlock');
  if (roundsBlock) roundsBlock.style.display = rounds ? 'none' : '';

  const priv = document.getElementById('rPrivate');
  priv.classList.toggle('is-on', !!r.private);
  priv.style.cssText = dim;
  document.getElementById('rPrivateValue').textContent = r.private ? 'ON' : 'OFF';

  // The stake. Amounts you cannot cover are shown but dimmed, so you can see
  // what you would be saving towards rather than having them disappear.
  const wagerHost = document.getElementById('rWagerPick');
  if (wagerHost) {
    // From the player panel state, which is where the server puts it -- R is
    // the room, and the room does not know your balance.
    const amounts = (P.state && P.state.wagerAmounts) || [0];
    const coins = (P.state && P.state.coins) || 0;
    const chosen = r.wager || 0;

    wagerHost.innerHTML = amounts.map(a => `
      <button class="wager-chip ${a === chosen ? 'is-on' : ''} ${a > coins ? 'cant' : ''}"
              data-wager="${a}">${a === 0 ? 'No wager' : a}</button>`).join('');

    const note = document.getElementById('rWagerNote');
    if (note) {
      note.textContent = chosen > 0
        ? `Everyone stakes ${chosen}. The pot is ${chosen} x however many play.`
        : `You have ${coins} to stake.`;
    }
  }

  // Where the match will be played. "Any" is first and is the default --
  // picking a specific one is the exception, not the norm, and a room that
  // insists on a busy arena waits for no reason.
  const pickHost = document.getElementById('rArenaPick');
  if (pickHost) {
    const arenas = R.arenas || [];
    const chosen = r.arenaId;

    pickHost.innerHTML =
      `<button class="arena-chip ${chosen ? '' : 'is-on'}" data-arena="any">
         <span class="arena-chip-name">Any</span>
         <span class="arena-chip-sub">whichever is free</span>
       </button>` +
      arenas.map(a => `
        <button class="arena-chip ${chosen === a.id ? 'is-on' : ''}" data-arena="${a.id}">
          <span class="arena-chip-name">${esc(a.name)}</span>
          <span class="arena-chip-sub">${a.free} of ${a.free + (a.running || 0)} free</span>
        </button>`).join('');
  }

  const rw = document.getElementById('rWeapons');
  const rown = document.getElementById('rOwnWeapons');
  if (rw) rw.classList.toggle('hidden', !weaponsPickable());
  if (rown) rown.classList.toggle('hidden', weaponsPickable());

  ['primary', 'sidearm'].forEach(slot => {
    const el = document.getElementById(slot === 'primary' ? 'rPrimary' : 'rSidearm');
    const chosen = r.weapons[slot];
    const isNone = !chosen || chosen === 'none';

    // "None" first, so rifles-only and pistols-only are one click away.
    const none = `
      <div class="wep-card wep-none ${isNone ? 'is-on' : ''}"
           data-rwep="none" data-rslot="${slot}" style="${dim}">
        <div class="wep-none-mark">&#8212;</div>
        <span>None</span>
      </div>`;

    el.innerHTML = none + (st.weapons[slot] || []).map(w => `
      <div class="wep-card ${chosen === w.id ? 'is-on' : ''}"
           data-rwep="${w.id}" data-rslot="${slot}" style="${dim}">
        <img src="${esc(oxImage(w.id, st.oxPath))}" alt="" onerror="this.style.visibility='hidden'">
        <span>${esc(w.label)}</span>
      </div>`).join('');
  });

  // Both empty is fists only. Allowed, but say so rather than letting someone
  // start a match and wonder where their gun went.
  const noPrimary = !r.weapons.primary || r.weapons.primary === 'none';
  const noSidearm = !r.weapons.sidearm || r.weapons.sidearm === 'none';
  const warn = document.getElementById('rWeaponNote');
  if (warn) {
    warn.textContent = (noPrimary && noSidearm)
      ? 'No weapons selected — this match will be fists only.'
      : '';
  }

  document.getElementById('rItems').innerHTML = (st.items || []).map(it => {
    const n = (r.items || {})[it.id] || 0;
    return `<div class="item-card ${n === 0 ? 'is-off' : ''}">
      <img src="${esc(oxImage(it.image || it.id, st.oxPath))}" alt="" onerror="this.style.visibility='hidden'">
      <span>${esc(it.label)}</span>
      <div class="item-steps" style="${dim}">
        <button data-ritem="${it.id}" data-delta="-1">&minus;</button>
        <b>${n}</b>
        <button data-ritem="${it.id}" data-delta="1">+</button>
      </div>
    </div>`;
  }).join('');
}

function renderRooms() {
  const inRoom = !!R.room;
  document.getElementById('rNone').classList.toggle('hidden', inRoom);
  document.getElementById('rIn').classList.toggle('hidden', !inRoom);
  document.getElementById('pRailRooms').textContent =
    inRoom ? `In ${R.room.code}` : (R.rooms.length ? `${R.rooms.length} open` : 'Create or join');

  if (!inRoom) { renderBrowse(); return; }

  const r = R.room;
  document.getElementById('rName').textContent = r.name || 'Room';
  document.getElementById('rCodeTag').textContent = `Code ${r.code}`;
  document.getElementById('rTeamState').textContent = `${r.countA} v ${r.countB} of ${r.perTeam}`;
  document.getElementById('rHostState').textContent = r.isHost ? 'You are host' : 'Host decides';

  renderTeam('rTeamA', 'A');
  renderTeam('rTeamB', 'B');
  renderRoomSettings();

  const near = document.getElementById('rNearby');
  const list = (P.state && P.state.nearby) || [];
  near.innerHTML = list.length
    ? list.map(n => `
        <div class="row">
          <div>
            <span class="row-name">${esc(n.name)}</span>
            <span class="row-sub">${n.distance}m away · id ${n.id}</span>
          </div>
          <button class="mini" data-rinvite="${n.id}">Invite</button>
        </div>`).join('')
    : `<p class="empty">Nobody close by. Use the code or an ID.</p>`;

  const test = document.getElementById('rTestBox');
  if (test) test.classList.toggle('hidden', !(P.state && P.state.testMode));

  const start = document.getElementById('rStart');
  start.disabled = !r.canStart || !r.isHost;
  document.getElementById('rStartNote').textContent =
    !r.isHost ? 'Waiting for the host to start.'
    : !r.canStart ? 'You need at least one player on each side.'
    : '';
}

/* ── events ────────────────────────────────────────────── */

document.addEventListener('click', async e => {
  const join = e.target.closest('[data-joinroom]');
  if (join) { rApply(await rPost('join', { code: join.dataset.joinroom })); return; }

  const member = e.target.closest('[data-member]');
  if (member && !e.target.closest('[data-kickroom]')) {
    rApply(await rPost('switchTeam', { key: member.dataset.member }));
    return;
  }

  const kick = e.target.closest('[data-kickroom]');
  if (kick) { rApply(await rPost('kick', { key: kick.dataset.kickroom })); return; }

  const mode = e.target.closest('[data-rmode]');
  if (mode) { rApply(await rPost('setMode', { mode: mode.dataset.rmode })); return; }

  const rounds = e.target.closest('[data-rrounds]');
  if (rounds) { rApply(await rPost('setRounds', { rounds: Number(rounds.dataset.rrounds) })); return; }

  const kills = e.target.closest('[data-rkills]');
  if (kills) { rApply(await rPost('setKills', { kills: Number(kills.dataset.rkills) })); return; }

  const wep = e.target.closest('[data-rwep]');
  if (wep) {
    rApply(await rPost('setWeapon', { slot: wep.dataset.rslot, weapon: wep.dataset.rwep }));
    return;
  }

  const item = e.target.closest('[data-ritem]');
  if (item && R.room) {
    const id = item.dataset.ritem;
    const cur = (R.room.items || {})[id] || 0;
    rApply(await rPost('setItem', { id, charges: cur + Number(item.dataset.delta) }));
    return;
  }

  const inv = e.target.closest('[data-rinvite]');
  if (inv) { rApply(await rPost('invite', { player: Number(inv.dataset.rinvite) })); return; }

  const wager = e.target.closest('[data-wager]');
  if (wager && R.room) {
    rApply(await rPost('setWager', { wager: Number(wager.dataset.wager) }));
    return;
  }

  const pick = e.target.closest('[data-arena]');
  if (pick && R.room) {
    const id = pick.dataset.arena === 'any' ? null : Number(pick.dataset.arena);
    rApply(await rPost('setArena', { arenaId: id }));
    return;
  }

  if (e.target.closest('#rPrivate') && R.room) {
    rApply(await rPost('setPrivate', { private: !R.room.private }));
  }
});

const rBtn = (id, name, payload) => {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('click', async () => {
    rApply(await rPost(name, typeof payload === 'function' ? payload() : (payload || {})));
  });
};

rBtn('rCreate', 'create', () => ({ mode: P.mode }));
rBtn('rLeave', 'leave');
rBtn('rRefresh', 'browse');
rBtn('rJoinCode', 'join', () => ({ code: document.getElementById('rCode').value.trim() }));
rBtn('rStart', 'start');
rBtn('rAddDummy', 'addDummy');
rBtn('rFillDummies', 'fillDummies');
rBtn('rInviteById', 'invite', () => ({ player: Number(document.getElementById('rInviteId').value) }));

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'room') {
    R.room = d.data || null;
    if (d.arenas) R.arenas = d.arenas;
    renderRooms();
  }

  if (d.action === 'openPlayer') {
    rPost('state').then(rApply);
  }

  // round flow
  if (d.action === 'score' && d.data) {
    if ((d.data.scoring || 'rounds') === 'rounds') {
      document.getElementById('sbTarget').textContent = `first to ${d.data.target}`;
    } else if (d.data.rounds > 1) {
      document.getElementById('sbMode').textContent =
        `${(P.state && P.state.modes.find(m => m.id === R.roomMode)?.label) || ''} R${d.data.round}`;
      document.getElementById('sbTarget').textContent =
        `${d.data.winsA}-${d.data.winsB} · to ${d.data.target}`;
    }

    if (d.data.roundOver) {
      const ro = d.data.roundOver;
      aBanner(`Round ${ro.round}`, `TEAM ${ro.winner} TAKES IT`,
        `${ro.winsA} – ${ro.winsB} · next round in ${ro.nextIn}s`,
        ro.winner === 'A' ? '#3E9BE4' : '#E4823E', (ro.nextIn || 6) * 1000);
    }

    if (d.data.roundStart) {
      aBanner('Fight', `ROUND ${d.data.roundStart}`, '', '#16E45F', 2500);
    }
  }
});

/* ============================================================
   MATCH INVENTORY
   Renders what the server sends and posts intent back. Dragging
   moves pixels; the server decides whether anything actually
   moved.
   ============================================================ */

const invRoot = document.getElementById('invRoot');
let invState = null;
let dragFrom = null;

function kg(grams) {
  return (grams / 1000).toFixed(1).replace(/\.0$/, '');
}

function renderInventory() {
  const grid = document.getElementById('invGrid');
  if (!grid || !invState) return;

  grid.style.setProperty('--cols', invState.columns || 5);

  const bySlot = {};
  (invState.slots || []).forEach(s => { bySlot[s.slot] = s; });

  const total = invState.total || 20;
  const hotbar = invState.hotbar || 5;
  let out = '';

  for (let i = 1; i <= total; i++) {
    const it = bySlot[i];
    const cls = [
      'inv-slot',
      i <= hotbar ? 'is-hotbar' : '',
      it ? 'has-item' : ''
    ].filter(Boolean).join(' ');

    out += `<div class="${cls}" data-slot="${i}">
      ${i <= hotbar ? `<span class="inv-slot-key">${i}</span>` : ''}
      ${it ? '' : '<span class="inv-slot-mark"></span>'}
      ${it ? `
        <img src="${esc(oxImage(it.image || it.name, invState.oxPath))}" alt=""
             onerror="this.style.visibility='hidden'">
        ${it.count > 1 ? `<span class="inv-slot-count">${it.count}</span>` : ''}
        <span class="inv-slot-name">${esc(it.label)}</span>` : ''}
    </div>`;
  }

  grid.innerHTML = out;

  // weight
  const w = invState.weight || 0;
  const max = invState.maxWeight || 30000;
  const pct = Math.min(100, (w / max) * 100);

  const bar = document.getElementById('invWeightBar');
  bar.style.width = pct + '%';

  const wrap = bar.parentElement;
  wrap.classList.toggle('is-heavy', pct >= 70 && pct < 95);
  wrap.classList.toggle('is-full', pct >= 95);

  document.getElementById('invWeightText').textContent =
    `${kg(w)} / ${kg(max)} kg`;
}

/* Mouse-driven drag, not HTML5 drag-and-drop.
   CEF in FiveM handles native DnD badly -- dragstart frequently never fires
   and dataTransfer is restricted -- so this tracks mousedown, mousemove and
   mouseup itself and carries a ghost element under the cursor. It works
   everywhere and there is nothing browser-specific to go wrong. */

let dragSlot = null;
let dragGhost = null;
let dragStartXY = null;

function slotAt(x, y) {
  const el = document.elementFromPoint(x, y);
  return el ? el.closest('.inv-slot') : null;
}

function clearDragVisuals() {
  document.querySelectorAll('.inv-slot').forEach(s =>
    s.classList.remove('is-dragging', 'is-over'));
  if (dragGhost) { dragGhost.remove(); dragGhost = null; }
}

function endDrag(x, y) {
  if (dragSlot === null) return;

  const target = (x !== undefined) ? slotAt(x, y) : null;
  const to = target ? Number(target.dataset.slot) : null;

  if (to && to !== dragSlot) {
    // `s` here, not `x` -- endDrag's own parameter is called x, and shadowing
    // it inside the callback is how the drop position got lost.
    const entry = invState && (invState.slots || []).find(s => s.slot === dragSlot);

    // Shift-drag a stack of more than one: ask how many rather than moving
    // the lot. Anything else moves whole, which is what you want most of the
    // time and shouldn't need a dialog.
    if (splitHeld && entry && entry.count > 1) {
      openSplit(dragSlot, to, entry, { clientX: x, clientY: y });
    } else {
      fetch(`https://${RES}/invMove`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: dragSlot, to })
      });
    }
  }

  dragSlot = null;
  dragStartXY = null;
  clearDragVisuals();
}

document.addEventListener('mousedown', e => {
  if (invRoot.classList.contains('hidden')) return;
  if (e.button !== 0) return;

  const slot = e.target.closest('.inv-slot.has-item');
  if (!slot) return;

  e.preventDefault();
  dragSlot = Number(slot.dataset.slot);
  dragStartXY = { x: e.clientX, y: e.clientY };
});

document.addEventListener('mousemove', e => {
  if (dragSlot === null || !dragStartXY) return;

  // A few pixels of travel before it counts as a drag, so a click meant as a
  // double-click doesn't turn into one.
  const moved = Math.abs(e.clientX - dragStartXY.x) + Math.abs(e.clientY - dragStartXY.y);
  if (moved < 5 && !dragGhost) return;

  if (!dragGhost) {
    const source = document.querySelector(`.inv-slot[data-slot="${dragSlot}"]`);
    if (!source) return;

    source.classList.add('is-dragging');

    const img = source.querySelector('img');
    dragGhost = document.createElement('div');
    dragGhost.className = 'inv-ghost';
    if (img) dragGhost.innerHTML = `<img src="${img.src}" alt="">`;
    document.body.appendChild(dragGhost);
  }

  dragGhost.style.left = e.clientX + 'px';
  dragGhost.style.top = e.clientY + 'px';

  const over = slotAt(e.clientX, e.clientY);
  document.querySelectorAll('.inv-slot.is-over').forEach(s => s.classList.remove('is-over'));
  if (over && Number(over.dataset.slot) !== dragSlot) over.classList.add('is-over');
});

document.addEventListener('mouseup', e => {
  if (dragSlot === null) return;

  // No ghost means it never became a drag -- leave it as a plain click so
  // double-click to use still works.
  if (!dragGhost) {
    dragSlot = null;
    dragStartXY = null;
    return;
  }

  endDrag(e.clientX, e.clientY);
});

// Cursor leaving the window mid-drag would otherwise strand the ghost.
document.addEventListener('mouseleave', () => {
  if (dragSlot !== null) { dragSlot = null; dragStartXY = null; clearDragVisuals(); }
});

// double-click to use
document.addEventListener('dblclick', e => {
  const slot = e.target.closest('.inv-slot.has-item');
  if (!slot || !invState) return;

  const n = Number(slot.dataset.slot);
  const it = (invState.slots || []).find(s => s.slot === n);
  if (!it || !it.usable) return;

  fetch(`https://${RES}/invUse`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ slot: n })
  });
});

function closeInv() {
  invRoot.classList.add('hidden');
  fetch(`https://${RES}/invClose`, { method: 'POST', body: '{}' });
}

document.getElementById('invClose').addEventListener('click', closeInv);

document.addEventListener('keyup', e => {
  // Escape is handled centrally at the bottom of this file, in stacking
  // order -- two handlers for the same key closed two layers at once.
});

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'invData') {
    invState = d.data || null;
    if (invState) renderInventory();
  }

  if (d.action === 'invOpen') {
    if (d.data) invState = d.data;
    invRoot.classList.remove('hidden');
    renderInventory();
  }

  if (d.action === 'invClose') invRoot.classList.add('hidden');
});

/* ============================================================
   THE SHOP
   ============================================================ */

const shopRoot = document.getElementById('shopRoot');
let shopState = null;
let shopCat = 0;

async function shopPost(action, payload = {}) {
  try {
    const res = await fetch(`https://${RES}/shop`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ action, payload })
    });
    return await res.json().catch(() => ({}));
  } catch (e) { return {}; }
}

function shopFlash(msg, bad) {
  const el = document.getElementById('shopFoot');
  if (!el) return;
  el.textContent = msg;
  el.parentElement.classList.toggle('is-error', !!bad);
  setTimeout(() => {
    el.textContent = 'Ready';
    el.parentElement.classList.remove('is-error');
  }, 3600);
}

function renderShop() {
  if (!shopState) return;

  document.getElementById('shopCoins').textContent = shopState.coins ?? 0;
  document.getElementById('shopShort').textContent = shopState.short || 'RZC';

  const cats = shopState.categories || [];

  document.getElementById('shopCats').innerHTML = cats.map((c, i) => `
    <button class="rail-item ${i === shopCat ? 'is-active' : ''}" data-shopcat="${i}">
      <span class="rail-label">${esc(c.name)}</span>
      <span class="rail-meta">${(c.items || []).length} items</span>
    </button>`).join('');

  const items = (cats[shopCat] || {}).items || [];
  const coins = shopState.coins ?? 0;

  document.getElementById('shopItems').innerHTML = items.map(it => {
    // Affordability is judged on the whole cart now, not one tile at a time
    // -- a tile you can afford on its own may still not fit the total.
    const queued = cart.get(it.item) || 0;
    const afford = true;
    // Durability is the thing worth knowing before you buy: a cheap gun that
    // lasts is often better value than an expensive one that doesn't.
    const meta = it.weapon && it.durability
      ? `${it.durability} lives`
      : (it.count > 1 ? `x${it.count}` : '');

    return `<div class="shop-item" data-buy="${esc(it.item)}">
      ${queued ? `<span class="cart-badge">${queued}</span>` : ''}
      <img src="${esc(oxImage(it.image || it.item, shopState.oxPath))}" alt=""
           onerror="this.style.visibility='hidden'">
      <span class="shop-name">${esc(it.label)}</span>
      <span class="shop-meta">${meta}</span>
      <span class="shop-price">${it.price}</span>
    </div>`;
  }).join('');

  renderCart();

  const cv = shopState.convert || {};
  const box = document.getElementById('convertBox');
  box.classList.toggle('hidden', !cv.enabled);
  previewConvert();

  if (cv.enabled) {
    // Short: it sits in a narrow column now.
    document.getElementById('convertRate').textContent =
      `${cv.rate}:1${cv.fee ? ` · ${Math.round(cv.fee * 100)}%` : ''}`;
  }
}

function previewConvert() {
  const cv = (shopState || {}).convert || {};
  const amount = Number(document.getElementById('convertAmount').value) || 0;
  const el = document.getElementById('convertPreview');
  if (!el) return;

  // What you can convert, before you type anything -- it saves finding the
  // minimum by trial and error.
  if (!amount) {
    const have = (shopState && shopState.coins) || 0;
    el.textContent = have >= (cv.minimum || 0)
      ? `You have ${have}. Minimum ${cv.minimum}.`
      : `You need ${cv.minimum} to cash out. You have ${have}.`;
    return;
  }

  if (amount < (cv.minimum || 0)) {
    el.textContent = `Minimum is ${cv.minimum}.`;
    return;
  }

  const have = (shopState && shopState.coins) || 0;
  if (amount > have) {
    el.textContent = `You only have ${have}.`;
    return;
  }

  const gross = amount * (cv.rate || 1);
  const fee = Math.floor(gross * (cv.fee || 0));
  el.textContent = `$${(gross - fee).toLocaleString()} to your bank`
    + (fee ? ` (after $${fee.toLocaleString()} fee)` : '');
}

document.addEventListener('click', async e => {
  const cat = e.target.closest('[data-shopcat]');
  if (cat) { shopCat = Number(cat.dataset.shopcat); renderShop(); return; }

  const buy = e.target.closest('[data-buy]');
  if (buy) {
    // Into the cart, not straight out of your pocket. Buying one thing is
    // still one click plus Buy -- and buying six is no longer six separate
    // transactions you have to get right in order.
    cartAdd(buy.dataset.buy);
  }
});

document.getElementById('shopClose').addEventListener('click', () => {
  shopRoot.classList.add('hidden');
  fetch(`https://${RES}/closeShop`, { method: 'POST', body: '{}' });
});

document.getElementById('convertAmount').addEventListener('input', previewConvert);

document.getElementById('convertBtn').addEventListener('click', async () => {
  const amount = Number(document.getElementById('convertAmount').value) || 0;
  const res = await shopPost('convert', { amount });
  if (res.coins !== undefined) shopState.coins = res.coins;
  if (res.ok) document.getElementById('convertAmount').value = '';
  renderShop();
  previewConvert();
  shopFlash(res.message || '', !res.ok);
});

window.addEventListener('message', ev => {
  const d = ev.data || {};

  if (d.action === 'openShop') {
    shopState = d.state;
    shopCat = 0;
    // Fresh each time. A cart left over from last visit is a cart you have
    // forgotten about and will buy by accident.
    cart.clear();
    shopRoot.classList.remove('hidden');
    renderShop();
  }

  if (d.action === 'closeShop') shopRoot.classList.add('hidden');
});

/* ============================================================
   RANK BADGES
   ============================================================
   Cut as gems rather than drawn as metal.

   The obvious move is to imitate the rendered-art badges every ranked ladder
   has -- ornate, chromed, bevelled. Done in SVG that always reads as a weak
   copy of a thing made in Photoshop. A faceted gem is native to the medium
   instead: flat planes, hard edges, colour doing the work. It gets to be
   good at what it is rather than a poor version of something else.

   One shape, four builds. A tier gains geometry as it climbs, so the
   silhouette alone tells you roughly where someone sits.            */

function rankBadge(tierCfg, size) {
  const c = tierCfg || {};
  const hue = c.hue || '#A855F7';
  const accent = c.accent || '#D5AAFF';
  const tier = c.tier || 1;
  const id = 'g' + Math.random().toString(36).slice(2, 8);

  // ── the stone ──
  // A wide hexagonal cut, not a teardrop. Flat table on top, crown facets
  // angling down to the girdle, pavilion tapering to the point. The facet
  // seams are what sell it as cut rather than filled.
  const gem = `
    <path d="M50 10 L84 30 L50 48 L16 30 Z"  fill="url(#t${id})"/>
    <path d="M16 30 L50 48 L8 62 Z"          fill="url(#l${id})"/>
    <path d="M84 30 L92 62 L50 48 Z"         fill="url(#r${id})"/>
    <path d="M8 62 L50 48 L34 92 Z"          fill="url(#p${id})"/>
    <path d="M34 92 L50 48 L50 118 Z"        fill="url(#p2${id})"/>
    <path d="M50 48 L66 92 L50 118 Z"        fill="url(#q${id})"/>
    <path d="M92 62 L66 92 L50 48 Z"         fill="url(#q2${id})"/>
    <path d="M50 10 L84 30 L92 62 L50 118 L8 62 L16 30 Z"
          fill="none" stroke="${accent}" stroke-width="2" stroke-linejoin="round"/>
    <g stroke="${accent}" stroke-width=".9" opacity=".45" fill="none">
      <path d="M16 30 L50 48 L84 30 M8 62 L50 48 L92 62"/>
      <path d="M34 92 L50 48 L66 92"/>
    </g>`;

  // ── the frame ──
  //
  // Wings were the first attempt and they read as small bat wings at badge
  // size -- fussy, and the shape fought the stone. A frame behind it works
  // far better: it reads instantly, scales down to 22px without turning to
  // mush, and gets to be geometric rather than trying to be ornate.
  //
  // It grows with rank, so the silhouette alone places someone.
  const frame = tier >= 2 ? `
    <path d="M50 -4 L96 22 L96 76 L50 124 L4 76 L4 22 Z"
          fill="none" stroke="${hue}" stroke-width="${tier >= 3 ? 3 : 1.6}"
          stroke-linejoin="round" opacity="${tier >= 3 ? .8 : .45}"/>` : '';

  // Corner marks from tier 3, where the frame turns.
  const corners = tier >= 3 ? `
    <g fill="${accent}">
      <circle cx="96" cy="22" r="3.6"/><circle cx="96" cy="76" r="3.6"/>
      <circle cx="4"  cy="22" r="3.6"/><circle cx="4"  cy="76" r="3.6"/>
    </g>` : '';

  // A second frame at the top, so Master and above are unmistakable.
  const outer = tier >= 4 ? `
    <path d="M50 -14 L108 18 L108 82 L50 136 L-8 82 L-8 18 Z"
          fill="none" stroke="${accent}" stroke-width="1.4"
          stroke-linejoin="round" opacity=".45"/>` : '';

  // ── crown, tier 4 ──
  // Sitting ON the stone. Floating above it read as a separate object.
  const crown = tier >= 4 ? `
    <path d="M28 14 L36 -2 L44 10 L50 -8 L56 10 L64 -2 L72 14 Z"
          fill="url(#c${id})" stroke="${accent}" stroke-width="1.4" stroke-linejoin="round"/>
    <circle cx="50" cy="-8" r="3.4" fill="#fff" opacity=".9"/>
    <circle cx="36" cy="-2" r="2.2" fill="${accent}"/>
    <circle cx="64" cy="-2" r="2.2" fill="${accent}"/>` : '';

  // a plinth under the top tiers, so they sit rather than float
  const base = tier >= 4 ? `
    <path d="M30 112 L70 112 L62 124 L38 124 Z" fill="${hue}" opacity=".6"/>
    <path d="M30 112 L70 112 L66 117 L34 117 Z" fill="${accent}" opacity=".5"/>` : '';

  // ── sparkle ──
  //
  // Earned, not sprinkled. A Bronze badge with glitter on it tells you
  // nothing; glitter that arrives with rank tells you everything. So the
  // count climbs with tier and the top two get the whole treatment.
  //
  // Every timing is offset by a per-badge seed, so a wall of sixteen badges
  // twinkles unevenly rather than pulsing in lockstep like a Christmas tree.
  const seed = (id.charCodeAt(2) || 7) % 10;

  const sparkPositions = [
    [14, 18], [86, 20], [50, -2], [8, 58], [92, 56],
    [26, 96], [74, 96], [50, 122], [20, 40], [80, 40],
    [38, 8], [62, 8]
  ];

  const sparkCount = tier <= 1 ? 0 : tier === 2 ? 4 : tier === 3 ? 7 : 12;

  const sparks = sparkPositions.slice(0, sparkCount).map((p, n) => {
    const [x, y] = p;
    const r = 2.2 + ((n + seed) % 3) * 0.9;
    const delay = (((n * 7 + seed * 3) % 40) / 10).toFixed(1);
    const dur = (2.4 + ((n + seed) % 4) * 0.5).toFixed(1);

    // A four-point star, not a dot. A dot at this size is a smudge.
    return `
    <g class="spark" style="--d:${delay}s;--t:${dur}s" transform="translate(${x} ${y})">
      <path d="M0 ${-r * 2.6} Q ${r * .5} ${-r * .5} ${r * 2.6} 0
               Q ${r * .5} ${r * .5} 0 ${r * 2.6}
               Q ${-r * .5} ${r * .5} ${-r * 2.6} 0
               Q ${-r * .5} ${-r * .5} 0 ${-r * 2.6} Z"
            fill="${n % 3 === 0 ? '#fff' : accent}"/>
    </g>`;
  }).join('');

  // A light that travels across the stone, so it reads as polished rather
  // than painted. Only from tier 2 -- Bronze should look dug up.
  const sheen = tier >= 2 ? `
    <g clip-path="url(#cut${id})">
      <rect class="sheen" style="--d:${(seed * 0.4).toFixed(1)}s"
            x="-60" y="-20" width="34" height="160"
            fill="url(#sheen${id})" transform="skewX(-18)"/>
    </g>` : '';

  const w = size || 96;

  return `
<svg class="badge${tier >= 4 ? ' is-legend' : ''}" viewBox="-18 -24 136 168"
     width="${w}" height="${w * 1.24}"
     xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <defs>
    <linearGradient id="t${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset="1" stop-color="${accent}"/>
    </linearGradient>
    <linearGradient id="l${id}" x1="1" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${hue}"/><stop offset="1" stop-color="${hue}" stop-opacity=".4"/>
    </linearGradient>
    <linearGradient id="r${id}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${accent}"/><stop offset="1" stop-color="${hue}"/>
    </linearGradient>
    <linearGradient id="p${id}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${hue}" stop-opacity=".45"/><stop offset="1" stop-color="${hue}"/>
    </linearGradient>
    <linearGradient id="p2${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${hue}"/><stop offset="1" stop-color="${hue}" stop-opacity=".55"/>
    </linearGradient>
    <linearGradient id="q${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${accent}" stop-opacity=".8"/><stop offset="1" stop-color="${hue}"/>
    </linearGradient>
    <linearGradient id="q2${id}" x1="1" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${accent}"/><stop offset="1" stop-color="${hue}" stop-opacity=".7"/>
    </linearGradient>
    <linearGradient id="c${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".95"/><stop offset="1" stop-color="${accent}"/>
    </linearGradient>
    <radialGradient id="glow${id}">
      <stop offset="0" stop-color="${accent}" stop-opacity=".55"/>
      <stop offset=".55" stop-color="${accent}" stop-opacity=".16"/>
      <stop offset="1" stop-color="${accent}" stop-opacity="0"/>
    </radialGradient>

    <linearGradient id="sheen${id}" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0"   stop-color="#fff" stop-opacity="0"/>
      <stop offset=".5"  stop-color="#fff" stop-opacity=".55"/>
      <stop offset="1"   stop-color="#fff" stop-opacity="0"/>
    </linearGradient>

    <!-- the sheen is clipped to the stone, so the light stays on the gem
         instead of sweeping across the whole card -->
    <clipPath id="cut${id}">
      <path d="M50 10 L84 30 L92 62 L50 118 L8 62 L16 30 Z"/>
    </clipPath>
  </defs>

  <ellipse class="${tier >= 3 ? 'halo' : ''}" cx="50" cy="62" rx="76" ry="70"
           fill="url(#glow${id})" style="--d:${(seed * 0.3).toFixed(1)}s"/>
  ${outer}${frame}${corners}${base}${gem}${crown}

  <!-- the light on the table facet, which is what makes it read as cut -->
  <path d="M50 10 L84 30 L50 48 Z" fill="#fff" opacity=".2"/>
  <path d="M16 30 L50 48 L8 62 Z"  fill="#fff" opacity=".06"/>

  ${sheen}
  ${sparks}
</svg>`;
}

/* ============================================================
   RANKED
   ============================================================ */

const rankedRoot = document.getElementById('rankedRoot');
let rkState = null;
let rkTiers = [];

function tierFor(elo) {
  let found = rkTiers[0];
  for (const t of rkTiers) if (elo >= t.elo) found = t;
  return found || {};
}

function nextTier(elo) {
  for (const t of rkTiers) if (t.elo > elo) return t;
  return null;
}

async function rkPost(action, payload = {}) {
  try {
    const res = await fetch(`https://${RES}/ranked`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ action, payload })
    });
    return await res.json().catch(() => ({}));
  } catch (e) { return {}; }
}

function renderRanked() {
  rkRenderPlay();
  if (!rkState) return;

  const me = rkState.you || {};
  const elo = me.elo ?? 1000;
  const placed = me.placed ?? 0;
  const need = rkState.placementMatches ?? 10;
  const provisional = placed < need;

  const t = tierFor(elo);
  const nx = nextTier(elo);

  document.getElementById('rkBadge').innerHTML = rankBadge(t, 118);

  // Say provisional rather than showing a rank nobody has earned yet. A
  // ladder that hands out a tier after two games teaches people to ignore it.
  document.getElementById('rkProvisional').textContent =
    provisional ? `Provisional · ${placed} of ${need}` : 'Current rank';
  document.getElementById('rkName').textContent = provisional ? 'Unranked' : (t.name || '—');
  document.getElementById('rkElo').textContent = elo;

  if (provisional) {
    document.getElementById('rkNextLabel').textContent = 'Placement matches';
    document.getElementById('rkNextElo').textContent = `${placed} / ${need}`;
    document.getElementById('rkMeter').style.width = `${(placed / need) * 100}%`;
  } else if (nx) {
    const span = nx.elo - t.elo;
    const into = elo - t.elo;
    document.getElementById('rkNextLabel').textContent = `Next: ${nx.name}`;
    document.getElementById('rkNextElo').textContent = `${nx.elo - elo} to go`;
    document.getElementById('rkMeter').style.width = `${Math.max(2, (into / span) * 100)}%`;
  } else {
    document.getElementById('rkNextLabel').textContent = 'Top of the ladder';
    document.getElementById('rkNextElo').textContent = '—';
    document.getElementById('rkMeter').style.width = '100%';
  }

  const wins = me.wins ?? 0, losses = me.losses ?? 0;
  const played = wins + losses;

  document.getElementById('rkWins').textContent = wins;
  document.getElementById('rkLosses').textContent = losses;
  document.getElementById('rkRate').textContent = played ? `${Math.round((wins / played) * 100)}%` : '0%';
  document.getElementById('rkPeak').textContent = me.peak_elo ?? elo;

  const streak = me.streak ?? 0;
  document.getElementById('rkStreak').textContent =
    streak === 0 ? '0' : (streak > 0 ? `${streak}W` : `${Math.abs(streak)}L`);

  document.getElementById('rkRailDash').textContent = provisional ? 'Provisional' : (t.name || '—');

  // Explain it in their own numbers rather than in the abstract.
  document.getElementById('rkExplain').textContent = provisional
    ? `You're ${need - placed} match${need - placed === 1 ? '' : 'es'} from a rank. Placement results swing ${rkState.placementMultiplier ?? 2}× harder, so you'll land near where you belong rather than climbing out of a bad start.`
    : `At ${elo}, beating someone rated 200 above you is worth about ${Math.round((rkState.kFactor ?? 32) * 0.76)} points. Beating someone 200 below is worth about ${Math.round((rkState.kFactor ?? 32) * 0.24)}. Losing reverses it.`;

  renderLadder(elo, provisional);
}

function renderLadder(elo, provisional) {
  const host = document.getElementById('rkLadder');
  if (!host) return;

  const current = tierFor(elo);

  host.innerHTML = rkTiers.map(t => {
    const mine = !provisional && t.name === current.name;
    const locked = elo < t.elo;

    return `<div class="ladder-item ${mine ? 'is-you' : ''} ${locked ? 'is-locked' : ''}">
      <div class="ladder-badge">${rankBadge(t, 78)}</div>
      <span class="ladder-name">${esc(t.name)}</span>
      <span class="ladder-elo">${t.elo === 0 ? 'Starting tier' : `${t.elo}+ rating`}</span>
    </div>`;
  }).join('');
}

function renderTop(rows) {
  const host = document.getElementById('rkTop');
  if (!host) return;

  const meName = rkState && rkState.name;

  host.innerHTML = rows.length
    ? rows.map((r, i) => {
        const t = tierFor(r.elo || 0);
        return `<div class="lb-row rk-row r${i + 1} ${r.name === meName ? 'is-you' : ''}">
          <span class="lb-rank">${i + 1}</span>
          <span class="lb-player"><span class="lb-name">${esc(r.name || 'Unknown')}</span></span>
          <span class="rk-badge-mini">
            ${rankBadge(t, 22)}
            <span class="rk-tier-name">${esc(t.name || '—')}</span>
          </span>
          <span class="lb-num w">${r.wins || 0}</span>
          <span class="lb-num l">${r.losses || 0}</span>
          <span class="lb-num pts">${r.elo || 0}</span>
        </div>`;
      }).join('')
    : `<p class="empty">Nobody has played a ranked match yet.</p>`;
}

function renderHistory(rows) {
  const host = document.getElementById('rkHistory');
  if (!host) return;

  host.innerHTML = rows.length
    ? rows.map(h => {
        const delta = (h.elo_after || 0) - (h.elo_before || 0);
        return `<div class="hist-row ${h.won ? 'won' : ''}">
          <span class="hist-bar"></span>
          <span>
            <span class="hist-who">${h.won ? 'Beat' : 'Lost to'} ${esc(h.opponent || 'someone')}</span>
            <span class="hist-meta">${esc(h.mode || '')}${h.score ? ' · ' + esc(h.score) : ''}</span>
          </span>
          <span class="hist-delta">${delta >= 0 ? '+' : ''}${delta}</span>
          <span class="hist-elo">${h.elo_after || 0}</span>
        </div>`;
      }).join('')
    : `<p class="empty">No ranked matches yet. Your results will show here with what each one did to your rating.</p>`;
}

/* ── open, close, tabs ── */

async function openRanked() {
  const res = await rkPost('state');
  if (!res.ok) return;

  rkState = res;
  rkTiers = res.tiers || [];

  pRoot.classList.add('hidden');
  rankedRoot.classList.remove('hidden');
  renderRanked();
}

const toRanked = document.getElementById('toRanked');
if (toRanked) toRanked.addEventListener('click', openRanked);

const toCasual = document.getElementById('toCasual');
if (toCasual) {
  toCasual.addEventListener('click', () => {
    rankedRoot.classList.add('hidden');
    pRoot.classList.remove('hidden');
  });
}

const rkClose = document.getElementById('rkClose');
if (rkClose) {
  rkClose.addEventListener('click', () => {
    rankedRoot.classList.add('hidden');
    fetch(`https://${RES}/closePlayer`, { method: 'POST', body: '{}' });
  });
}

document.querySelectorAll('[data-rktab]').forEach(btn => {
  btn.addEventListener('click', async () => {
    document.querySelectorAll('[data-rktab]').forEach(b => b.classList.remove('is-active'));
    document.querySelectorAll('.rkpanel').forEach(p => p.classList.remove('is-active'));
    btn.classList.add('is-active');
    document.querySelector(`[data-rkpanel="${btn.dataset.rktab}"]`).classList.add('is-active');

    if (btn.dataset.rktab === 'top') {
      const res = await rkPost('top');
      renderTop(res.rows || []);
    }
    if (btn.dataset.rktab === 'history') {
      const res = await rkPost('history');
      renderHistory(res.rows || []);
    }
  });
});

window.addEventListener('message', ev => {
  const d = ev.data || {};
  if (d.action === 'closePlayer') rankedRoot.classList.add('hidden');
});

/* The rating change, on the result screen. Losing and then having to open a
   menu to find out what it cost is how a ladder feels arbitrary. */
window.addEventListener('message', ev => {
  const d = ev.data || {};
  if (d.action !== 'rankedResult') return;

  const r = d.data || {};
  const delta = r.delta || 0;
  const t = r.tier || {};

  aBanner(
    r.won ? 'Ranked win' : 'Ranked loss',
    `${delta >= 0 ? '+' : ''}${delta} rating`,
    `${r.after} · ${t.name || ''}`,
    r.won ? '#2DD4BF' : '#F472B6',
    4200);
});

/* ============================================================
   SPLITTING A STACK
   ============================================================
   Shift-drag asks how many. A plain drag moves the whole stack, because
   that's what you want most of the time and it shouldn't cost a dialog. */

let splitHeld = false;
let splitFrom = null;
let splitTo = null;
let splitMax = 1;

document.addEventListener('keydown', e => { if (e.key === 'Shift') splitHeld = true; });
document.addEventListener('keyup',   e => { if (e.key === 'Shift') splitHeld = false; });
window.addEventListener('blur', () => { splitHeld = false; });

function openSplit(from, to, entry, ev) {
  splitFrom = from;
  splitTo = to;
  splitMax = entry.count;

  const box = document.getElementById('splitBox');
  const input = document.getElementById('splitAmount');

  document.getElementById('splitWhat').textContent =
    `Move how many? (${entry.count} ${entry.label})`;

  input.max = entry.count;
  input.value = Math.max(1, Math.floor(entry.count / 2));

  // Placed where the drag ended, then nudged back inside if it would hang
  // off the panel -- a dialog half off screen is worse than no dialog.
  box.classList.remove('hidden');
  const panel = box.offsetParent || document.body;
  const bounds = panel.getBoundingClientRect();
  const w = box.offsetWidth, h = box.offsetHeight;

  let x = (ev ? ev.clientX : bounds.left + 40) - bounds.left + 12;
  let y = (ev ? ev.clientY : bounds.top + 40) - bounds.top + 12;

  x = Math.max(8, Math.min(x, bounds.width - w - 8));
  y = Math.max(8, Math.min(y, bounds.height - h - 8));

  box.style.left = x + 'px';
  box.style.top = y + 'px';

  document.querySelectorAll('.inv-slot').forEach(sl =>
    sl.classList.toggle('is-splitting', Number(sl.dataset.slot) === from));

  input.focus();
  input.select();
}

function closeSplit() {
  document.getElementById('splitBox').classList.add('hidden');
  document.querySelectorAll('.inv-slot').forEach(sl => sl.classList.remove('is-splitting'));
  splitFrom = splitTo = null;
}

function clampSplit(v) {
  return Math.max(1, Math.min(splitMax, Math.floor(v) || 1));
}

async function doSplit() {
  const amount = clampSplit(Number(document.getElementById('splitAmount').value));
  if (splitFrom == null || splitTo == null) return closeSplit();

  await fetch(`https://${RES}/invSplit`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: splitFrom, to: splitTo, amount })
  });
  closeSplit();
}

document.addEventListener('click', e => {
  const step = e.target.closest('[data-split]');
  if (step) {
    const input = document.getElementById('splitAmount');
    input.value = clampSplit(Number(input.value) + Number(step.dataset.split));
    return;
  }

  if (e.target.id === 'splitHalf') {
    document.getElementById('splitAmount').value = clampSplit(splitMax / 2);
  }
  if (e.target.id === 'splitAll') {
    document.getElementById('splitAmount').value = splitMax;
  }
  if (e.target.id === 'splitGo') doSplit();
  if (e.target.id === 'splitCancel') closeSplit();
});

document.addEventListener('keydown', e => {
  if (document.getElementById('splitBox').classList.contains('hidden')) return;
  if (e.key === 'Enter') { e.preventDefault(); doSplit(); }
  // Escape handled centrally.
});

/* ============================================================
   THE SLOT MENU
   ============================================================
   Right-click a slot. Amount first, because everything under it needs one,
   then what to do with that amount. */

let ctxSlot = null;
let ctxEntry = null;

function ctxClamp(v) {
  return Math.max(1, Math.min(ctxEntry ? ctxEntry.count : 1, Math.floor(v) || 1));
}

function openCtx(slot, entry, ev) {
  ctxSlot = slot;
  ctxEntry = entry;

  const box = document.getElementById('ctxBox');
  document.getElementById('ctxName').textContent = entry.label || entry.name;
  document.getElementById('ctxHave').textContent = `x${entry.count}`;

  const slider = document.getElementById('ctxSlider');
  slider.max = entry.count;
  slider.value = 1;
  slider.disabled = entry.count <= 1;
  const valueBox = document.getElementById('ctxValue');
  valueBox.max = entry.count;
  valueBox.value = 1;

  // A weapon isn't "used" from the grid -- you equip it with its number key.
  document.getElementById('ctxUse').disabled = !entry.usable;
  document.getElementById('ctxTargets').classList.add('hidden');

  box.classList.remove('hidden');

  const panel = box.offsetParent || document.body;
  const b = panel.getBoundingClientRect();
  let x = ev.clientX - b.left + 8;
  let y = ev.clientY - b.top + 8;
  x = Math.max(8, Math.min(x, b.width - box.offsetWidth - 8));
  y = Math.max(8, Math.min(y, b.height - box.offsetHeight - 8));
  box.style.left = x + 'px';
  box.style.top = y + 'px';

  document.querySelectorAll('.inv-slot').forEach(sl =>
    sl.classList.toggle('is-splitting', Number(sl.dataset.slot) === slot));
}

function closeCtx() {
  document.getElementById('ctxBox').classList.add('hidden');
  document.getElementById('ctxTargets').classList.add('hidden');
  document.querySelectorAll('.inv-slot').forEach(sl => sl.classList.remove('is-splitting'));
  ctxSlot = null;
  ctxEntry = null;
}

document.addEventListener('contextmenu', e => {
  if (invRoot.classList.contains('hidden')) return;

  const slot = e.target.closest('.inv-slot');
  if (!slot) return;

  e.preventDefault();

  const n = Number(slot.dataset.slot);
  const entry = invState && (invState.slots || []).find(s => s.slot === n);
  if (!entry) return closeCtx();

  openCtx(n, entry, e);
});

// Slider and number field drive each other, so you can drag OR type.
const ctxSliderEl = document.getElementById('ctxSlider');
const ctxValueEl = document.getElementById('ctxValue');

if (ctxSliderEl) {
  ctxSliderEl.addEventListener('input', () => {
    ctxValueEl.value = ctxSliderEl.value;
  });
}

if (ctxValueEl) {
  ctxValueEl.addEventListener('input', () => {
    // An empty field mid-edit is unfinished, not zero -- don't fight it.
    if (ctxValueEl.value.trim() === '') return;
    ctxSliderEl.value = ctxClamp(Number(ctxValueEl.value));
  });

  ctxValueEl.addEventListener('focusout', () => {
    const n = ctxClamp(Number(ctxValueEl.value));
    ctxValueEl.value = n;
    ctxSliderEl.value = n;
  });

  ctxValueEl.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); ctxValueEl.blur(); }
  });
}

function ctxAmount() {
  // The typed field wins if it has something in it, since that is what the
  // person was last looking at.
  const typed = document.getElementById('ctxValue').value;
  if (typed !== '') return ctxClamp(Number(typed));
  return ctxClamp(Number(document.getElementById('ctxSlider').value));
}

function setCtxAmount(v) {
  const n = ctxClamp(v);
  document.getElementById('ctxSlider').value = n;
  document.getElementById('ctxValue').value = n;
}

document.addEventListener('click', async e => {
  const chip = e.target.closest('[data-ctx-set]');
  if (chip) {
    const how = chip.dataset.ctxSet;
    const max = ctxEntry ? ctxEntry.count : 1;
    setCtxAmount(how === 'max' ? max : how === 'half' ? Math.ceil(max / 2) : 1);
    return;
  }

  if (e.target.id === 'ctxClose') return closeCtx();

  if (e.target.id === 'ctxUse') {
    const amount = ctxAmount();
    // Used one at a time server-side, so the count is how many times.
    for (let i = 0; i < amount; i++) {
      await fetch(`https://${RES}/invUse`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ slot: ctxSlot })
      });
    }
    closeCtx();
    return;
  }

  if (e.target.id === 'ctxDrop') {
    const amount = ctxAmount();
    await fetch(`https://${RES}/invDrop`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ slot: ctxSlot, amount })
    });
    closeCtx();
    return;
  }

  if (e.target.id === 'ctxGive') {
    // Who's nearby is a question only the game can answer, so ask it.
    const res = await fetch(`https://${RES}/invNearby`, { method: 'POST', body: '{}' });
    const data = await res.json().catch(() => ({}));
    const list = data.players || [];

    const host = document.getElementById('ctxNearby');
    host.innerHTML = list.length
      ? list.map(p => `
          <button class="ctx-target" data-give="${p.id}">
            ${esc(p.name)} <small>${p.distance}m</small>
          </button>`).join('')
      : `<p class="empty">Nobody close enough.</p>`;

    document.getElementById('ctxTargets').classList.remove('hidden');
    return;
  }

  const give = e.target.closest('[data-give]');
  if (give) {
    const amount = ctxAmount();
    await fetch(`https://${RES}/invGive`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ slot: ctxSlot, amount, target: Number(give.dataset.give) })
    });
    closeCtx();
    return;
  }

  // A click anywhere else closes it, the way a menu should.
  if (!e.target.closest('#ctxBox')) closeCtx();
});

document.addEventListener('keydown', e => {
  if (document.getElementById('ctxBox').classList.contains('hidden')) return;
  // Escape handled centrally.
});

/* ============================================================
   ESCAPE CLOSES EVERYTHING
   ============================================================
   Nobody should be stuck looking at a panel. Every overlay answers to Escape,
   and they close in the order they're stacked -- the split dialog before the
   inventory behind it, the inventory before the panel behind that -- so one
   press does the thing you meant rather than dismissing the lot.

   The modals that are part of a flow (match found, the map vote) are the
   exception: they close themselves in a few seconds and dismissing them would
   only hide something you need to see. */

document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;

  const shown = id => {
    const el = document.getElementById(id);
    return el && !el.classList.contains('hidden');
  };

  // Innermost first. Each entry closes one layer and stops.
  const layers = [
    // little dialogs that sit on top of a panel
    { id: 'ctxBox',     close: () => closeCtx() },
    { id: 'splitBox',   close: () => closeSplit() },

    // panels
    { id: 'invRoot',    close: () => closeInv() },
    { id: 'shopRoot',   close: () => {
        document.getElementById('shopRoot').classList.add('hidden');
        fetch(`https://${RES}/closeShop`, { method: 'POST', body: '{}' });
      } },
    { id: 'rankedRoot', close: () => {
        document.getElementById('rankedRoot').classList.add('hidden');
        fetch(`https://${RES}/closePlayer`, { method: 'POST', body: '{}' });
      } },
    { id: 'pRoot',      close: () => {
        pRoot.classList.add('hidden');
        fetch(`https://${RES}/closePlayer`, { method: 'POST', body: '{}' });
      } },
    { id: 'root',       close: () => {
        root.classList.add('hidden');
        ctrlWatch(false);
        fetch(`https://${RES}/close`, { method: 'POST', body: '{}' });
      } },
  ];

  for (const layer of layers) {
    if (shown(layer.id)) {
      e.preventDefault();
      try { layer.close(); } catch (err) { /* already gone */ }
      return;
    }
  }
});

/* ============================================================
   THE CART
   ============================================================
   Click a tile to add one. The cart shows what it comes to before you commit,
   and the purchase is all or nothing on the server -- paying for five and
   getting three because the bag filled up halfway is the worst thing that
   could happen here. */

const cart = new Map();   // item id -> qty

function cartPriceOf(id) {
  for (const cat of (shopState?.categories || [])) {
    const found = (cat.items || []).find(i => i.item === id);
    if (found) return found;
  }
  return null;
}

function cartAdd(id, n = 1) {
  const have = cart.get(id) || 0;
  const next = Math.max(0, Math.min(99, have + n));

  if (next === 0) cart.delete(id);
  else cart.set(id, next);

  // If a quantity field has focus, update it in place rather than rebuilding
  // the rows underneath the cursor.
  const box = document.querySelector(`[data-cart-qty="${id}"]`);
  if (box && document.activeElement === box && next > 0) {
    box.value = next;
    cartRefreshTotals();
  } else {
    renderCart();
  }

  renderShop();
}

function cartTotal() {
  let total = 0, count = 0;
  for (const [id, qty] of cart) {
    const entry = cartPriceOf(id);
    if (entry) { total += entry.price * qty; count += qty; }
  }
  return { total, count };
}

/* Just the numbers, without redrawing the lines.
   
   renderCart rebuilds the rows, which destroys whatever input has focus --
   fine when a button was clicked, fatal while someone is typing. */
function cartRefreshTotals() {
  const { total, count } = cartTotal();
  const coins = shopState?.coins ?? 0;
  const afford = coins >= total;

  document.getElementById('cartCount').textContent =
    `${count} item${count === 1 ? '' : 's'}`;

  const totalEl = document.getElementById('cartTotal');
  totalEl.textContent = total;
  totalEl.classList.toggle('cant', !afford);

  document.getElementById('cartBuy').disabled = !afford;

  const warn = document.getElementById('cartWarn');
  warn.classList.toggle('hidden', afford);
  if (!afford) warn.textContent = `You need ${total - coins} more ${shopState?.short || 'RZC'}.`;

  // And each line's own price, which is the other thing that changes.
  for (const [id, qty] of cart) {
    const entry = cartPriceOf(id);
    const el = document.querySelector(`[data-cart-line="${id}"]`);
    if (el && entry) el.textContent = entry.price * qty;
  }
}

function renderCart() {
  const bar = document.getElementById('cartBar');
  if (!bar) return;

  bar.classList.toggle('hidden', cart.size === 0);
  if (cart.size === 0) return;

  const { total, count } = cartTotal();
  const coins = shopState?.coins ?? 0;
  const afford = coins >= total;

  document.getElementById('cartLines').innerHTML = [...cart].map(([id, qty]) => {
    const entry = cartPriceOf(id) || { label: id, price: 0 };
    return `
      <div class="cart-line">
        <span class="cart-line-name">${esc(entry.label)}</span>
        <span class="cart-qty">
          <button data-cart-less="${esc(id)}">&minus;</button>
          <input type="number" min="1" max="99" value="${qty}"
                 data-cart-qty="${esc(id)}" aria-label="How many">
          <button data-cart-more="${esc(id)}">+</button>
        </span>
        <span class="cart-line-price" data-cart-line="${esc(id)}">${entry.price * qty}</span>
        <button class="cart-drop" data-cart-drop="${esc(id)}">&times;</button>
      </div>`;
  }).join('');

  document.getElementById('cartCount').textContent =
    `${count} item${count === 1 ? '' : 's'}`;

  const totalEl = document.getElementById('cartTotal');
  totalEl.textContent = total;
  totalEl.classList.toggle('cant', !afford);

  document.getElementById('cartBuy').disabled = !afford;

  // Say what's wrong rather than just greying the button out.
  const warn = document.getElementById('cartWarn');
  warn.classList.toggle('hidden', afford);
  if (!afford) warn.textContent = `You need ${total - coins} more ${shopState?.short || 'RZC'}.`;
}

/* Typing a number.
   
   Handled on input rather than change, so the total keeps up as you type --
   but the field is NOT re-rendered while you are in it, because rewriting an
   input someone is typing into is how you lose the second digit of "20". */
document.addEventListener('input', e => {
  const box = e.target.closest('[data-cart-qty]');
  if (!box) return;

  const id = box.dataset.cartQty;
  const raw = box.value.trim();

  // An empty field mid-edit is not zero, it is unfinished. Leave the cart
  // alone until there is a number to act on.
  if (raw === '') return;

  const n = Math.max(1, Math.min(99, Math.floor(Number(raw)) || 1));
  cart.set(id, n);

  cartRefreshTotals();
  renderShop();
});

/* Tidy up when they leave the field: an empty or silly value becomes
   something real, and only then is the field rewritten. */
document.addEventListener('focusout', e => {
  const box = e.target.closest('[data-cart-qty]');
  if (!box) return;

  const id = box.dataset.cartQty;
  const n = Math.max(1, Math.min(99, Math.floor(Number(box.value)) || 1));

  cart.set(id, n);
  box.value = n;
  renderCart();
  renderShop();
});

/* Enter confirms and moves on rather than submitting anything. */
document.addEventListener('keydown', e => {
  const box = e.target.closest('[data-cart-qty]');
  if (!box) return;
  if (e.key === 'Enter') { e.preventDefault(); box.blur(); }
});

document.addEventListener('click', async e => {
  const less = e.target.closest('[data-cart-less]');
  if (less) return cartAdd(less.dataset.cartLess, -1);

  const more = e.target.closest('[data-cart-more]');
  if (more) return cartAdd(more.dataset.cartMore, 1);

  const drop = e.target.closest('[data-cart-drop]');
  if (drop) { cart.delete(drop.dataset.cartDrop); renderCart(); renderShop(); return; }

  if (e.target.id === 'cartClear') { cart.clear(); renderCart(); renderShop(); return; }

  if (e.target.id === 'cartBuy') {
    const lines = [...cart].map(([item, qty]) => ({ item, qty }));
    if (!lines.length) return;

    const btn = document.getElementById('cartBuy');
    btn.disabled = true;

    const res = await shopPost('cart', { lines });

    if (res.coins !== undefined) shopState.coins = res.coins;
    if (res.ok) cart.clear();

    renderCart();
    renderShop();
    shopFlash(res.message || '', !res.ok);

    btn.disabled = false;
  }
});

/* ============================================================
   THE RANKED QUEUE
   ============================================================
   Queueing from here puts your rating on the line; queueing from the casual
   panel does not. Same modes, same arenas -- the difference is which door you
   came through, and the server keeps the two queues apart so a ranked player
   is never matched against someone messing about. */

let rkMode = null;
let rkScore = null;

function rkRenderPlay() {
  const st = P.state;
  if (!st) return;

  // Only the modes that can be ranked at all.
  const allowed = st.rankedModes || [];
  const modes = (st.modes || []).filter(m => allowed.includes(m.id));

  if (!rkMode && modes.length) rkMode = modes[0].id;
  const mode = modes.find(m => m.id === rkMode) || modes[0];

  const host = document.getElementById('rkModes');
  if (host) {
    host.innerHTML = modes.length
      ? modes.map(m => `
          <div class="mode-card ${m.id === rkMode ? 'is-on' : ''}" data-rkmode="${esc(m.id)}">
            <span class="mode-name">${esc(m.label)}</span>
            <span class="mode-queued">${(st.rankedQueue || {})[m.id] || 0} queued</span>
          </div>`).join('')
      : `<p class="empty">No modes are ranked on this server.</p>`;
  }

  const scores = document.getElementById('rkScores');
  if (scores && mode) {
    if (!rkScore || !(mode.scores || []).includes(rkScore)) {
      rkScore = mode.defaultScore;
    }
    scores.innerHTML = (mode.scores || []).map(v => `
      <div class="score-card ${v === rkScore ? 'is-on' : ''}" data-rkscore="${v}">${v}</div>`).join('');
  }

  // The same queue you'd leave from the casual panel -- there is only one.
  const queued = !!st.queuedIn;
  const qBtn = document.getElementById('rkQueueBtn');
  const lBtn = document.getElementById('rkLeaveQueueBtn');
  if (qBtn) qBtn.classList.toggle('hidden', queued);
  if (lBtn) lBtn.classList.toggle('hidden', !queued);

  const meta = document.getElementById('rkPlayMeta');
  if (meta) meta.textContent = queued ? 'In the queue' : 'Queue ranked';
}

document.addEventListener('click', async e => {
  const m = e.target.closest('[data-rkmode]');
  if (m) { rkMode = m.dataset.rkmode; rkRenderPlay(); return; }

  const sc = e.target.closest('[data-rkscore]');
  if (sc) { rkScore = Number(sc.dataset.rkscore); rkRenderPlay(); return; }

  if (e.target.id === 'rkQueueBtn') {
    // joinQueue, not 'queue'. There is no 'queue' action -- it fell through
    // to "Unknown action." and the button did nothing, silently, forever.
    // ranked: true is the whole difference between this and the casual one.
    const r = await pPost('joinQueue', { mode: rkMode, score: rkScore, ranked: true });
    if (r.state) { P.state = r.state; renderPlayer(); }
    pFlash(r.message || '', !r.ok);
    rkRenderPlay();
    return;
  }

  if (e.target.id === 'rkLeaveQueueBtn') {
    const r = await pPost('leaveQueue');
    if (r.state) { P.state = r.state; renderPlayer(); }
    pFlash(r.message || '', !r.ok);
    rkRenderPlay();
  }
});

/* ============================================================
   THE CONTROL PANEL
   ============================================================
   What's happening, and the handles to change it. Everything here used to be
   a command typed blind -- and a command typed blind is one you get wrong on
   the player id. */

let ctrl = null;
let ctrlEveryone = false;
let ctrlSearch = '';
let ctrlTimer = null;

async function ctrlPost(action, payload = {}) {
  try {
    const res = await fetch(`https://${RES}/control`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ action, payload })
    });
    return await res.json().catch(() => ({}));
  } catch (e) { return {}; }
}

/* Refresh while the control view is open, and stop the moment it is not --
   a timer polling a hidden panel is a timer costing frames for nothing. */
function ctrlWatch(on) {
  clearInterval(ctrlTimer);
  ctrlTimer = null;
  if (on) {
    ctrlRefresh();
    ctrlTimer = setInterval(() => {
      if (root.classList.contains('hidden')) { ctrlWatch(false); return; }
      const live = document.querySelector('[data-panel="live"]');
      const people = document.querySelector('[data-panel="people"]');
      if ((live && live.classList.contains('is-active')) ||
          (people && people.classList.contains('is-active'))) {
        ctrlRefresh();
      }
    }, 3000);
  }
}

async function ctrlRefresh() {
  const res = await ctrlPost('state', { everyone: ctrlEveryone });
  if (!res.ok) return;
  ctrl = res;
  renderControl();
}

function renderControl() {
  if (!ctrl) return;

  const t = ctrl.totals || {};
  document.getElementById('cLive').textContent = t.live || 0;
  document.getElementById('cLobby').textContent = t.lobby || 0;
  document.getElementById('cQueued').textContent = t.queued || 0;
  document.getElementById('cRooms').textContent = t.rooms || 0;

  document.getElementById('liveMeta').textContent =
    t.live ? `${t.live} match${t.live === 1 ? '' : 'es'}` : 'Nothing running';
  document.getElementById('peopleMeta').textContent =
    `${(ctrl.people || []).length} in the world`;

  // ── matches ──
  const matches = ctrl.matches || [];
  document.getElementById('cMatches').innerHTML = matches.length
    ? matches.map(m => `
        <div class="ctrl-card">
          <div class="ctrl-head">
            <div>
              <span class="ctrl-title">${esc(m.arena)}</span>
              <span class="ctrl-sub">${esc(m.mode)}${m.ranked ? ' · ranked' : ''}
                · first to ${m.target} · ${Math.floor(m.started / 60)}m in</span>
            </div>
            <span class="ctrl-score">${m.scores.A} &ndash; ${m.scores.B}</span>
          </div>
          <div class="ctrl-players">
            ${(m.players || []).map(p => `
              <span class="ctrl-player team-${esc(p.team)}">
                ${esc(p.name)} <small>${p.kills}/${p.deaths}</small>
              </span>`).join('')}
          </div>
          <div class="ctrl-actions">
            <button class="mini" data-endmatch="${esc(m.key)}" data-winner="A">A wins</button>
            <button class="mini" data-endmatch="${esc(m.key)}" data-winner="B">B wins</button>
            <button class="mini mini-danger" data-endmatch="${esc(m.key)}">End, no winner</button>
          </div>
        </div>`).join('')
    : `<p class="empty">No matches running.</p>`;

  renderPeople();
}

function renderPeople() {
  const host = document.getElementById('cPeople');
  if (!host || !ctrl) return;

  const q = ctrlSearch.toLowerCase();
  const people = (ctrl.people || []).filter(p => !q || p.name.toLowerCase().includes(q));

  document.getElementById('cShowAll').textContent =
    ctrlEveryone ? 'Only in the arena' : 'Show everyone';

  host.innerHTML = people.length
    ? people.map(p => `
        <div class="ctrl-person">
          <div class="ctrl-person-who">
            <span class="ctrl-person-name">${esc(p.name)}</span>
            <span class="ctrl-person-where">#${p.id} &middot; ${esc(p.where)}</span>
          </div>
          <span class="ctrl-person-coins">${p.coins}</span>
          <div class="ctrl-give">
            <input type="number" placeholder="0" data-give-amount="${p.id}">
            <button class="mini" data-give="${p.id}" data-sign="1">Give</button>
            <button class="mini mini-danger" data-give="${p.id}" data-sign="-1">Take</button>
          </div>
          <button class="mini" data-pull="${p.id}">To lobby</button>
        </div>`).join('')
    : `<p class="empty">${q ? 'Nobody by that name.' : 'Nobody in the arena world.'}</p>`;
}

/* Tabs, and a refresh while the control view is open. */
document.querySelectorAll('[data-atab]').forEach(btn => {
  btn.addEventListener('click', () => {
    adminView = btn.dataset.atab;

    document.querySelectorAll('[data-atab]').forEach(b => b.classList.remove('is-active'));
    btn.classList.add('is-active');

    document.querySelectorAll('[data-panel]').forEach(p => p.classList.remove('is-active'));
    const panel = document.querySelector(`[data-panel="${adminView}"]`);
    if (panel) panel.classList.add('is-active');

    // The arena rail highlight would otherwise claim you're looking at an
    // arena you aren't.
    document.querySelectorAll('.arena-item').forEach(a => a.classList.remove('is-on'));

    ctrlRefresh();
  });
});

document.addEventListener('click', async e => {
  const end = e.target.closest('[data-endmatch]');
  if (end) {
    const res = await ctrlPost('endMatch',
      { key: end.dataset.endmatch, winner: end.dataset.winner || null });
    flash(res.message || '', !res.ok);
    ctrlRefresh();
    return;
  }

  const clear = e.target.closest('[data-clearzone]');
  if (clear) {
    const res = await ctrlPost('clearZone', { id: Number(clear.dataset.clearzone) });
    flash(res.message || '', !res.ok);
    ctrlRefresh();
    return;
  }

  const pull = e.target.closest('[data-pull]');
  if (pull) {
    const res = await ctrlPost('pull', { id: Number(pull.dataset.pull) });
    flash(res.message || '', !res.ok);
    ctrlRefresh();
    return;
  }

  const give = e.target.closest('[data-give]');
  if (give) {
    const id = Number(give.dataset.give);
    const box = document.querySelector(`[data-give-amount="${id}"]`);
    const amount = Math.abs(Math.floor(Number(box?.value) || 0)) * Number(give.dataset.sign);

    if (!amount) return flash('Type an amount first.', true);

    const res = await ctrlPost('coins', { id, amount });
    flash(res.message || '', !res.ok);
    if (box) box.value = '';
    ctrlRefresh();
    return;
  }

  if (e.target.id === 'cShowAll') {
    ctrlEveryone = !ctrlEveryone;
    ctrlRefresh();
  }
});

const cSearchBox = document.getElementById('cSearch');
if (cSearchBox) {
  cSearchBox.addEventListener('input', () => {
    ctrlSearch = cSearchBox.value;
    renderPeople();   // not a full refresh -- that would clear the box
  });
}
