/*
    tenx-zones :: panel

    This file only ever asks. Every write goes out as an NUI callback
    to client/nui.lua, which forwards it to the server, which re-checks
    the ACE permission before it touches anything. Nothing is decided
    here, so a tampered page gets you no further than a spoofed event.
*/

const RES = 'tenx-zones';

const PALETTE = [
    { r: 255, g: 77,  b: 61  },
    { r: 255, g: 158, b: 44  },
    { r: 246, g: 217, b: 76  },
    { r: 0,   g: 224, b: 138 },
    { r: 56,  g: 199, b: 255 },
    { r: 138, g: 122, b: 255 },
    { r: 255, g: 106, b: 193 },
    { r: 226, g: 232, b: 244 }
];

const S = {
    zones: [],
    limits: { minRadius: 5, maxRadius: 600, minPoints: 3, maxPoints: 32 },
    draft: null,
    editingId: null,
    context: null,          // 'draft' | 'existing'
    existing: null,
    color: PALETTE[0],
    solid: true,
    visible: true,
    tags: [],
    warnTimer: null,
    toastTimer: null
};

const $ = (id) => document.getElementById(id);

function post(name, data) {
    return fetch(`https://${RES}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
    }).catch(() => {});
}

function show(el, on) {
    if (el) el.hidden = !on;
}

function sameColor(a, b) {
    return !!a && !!b && a.r === b.r && a.g === b.g && a.b === b.b;
}

function rgb(c) {
    return `rgb(${c.r}, ${c.g}, ${c.b})`;
}


/* ============================================================
   ZONE LIST
   ============================================================ */

function zoneMeta(z) {
    const chips = [];

    if (z.kind === 'sphere') {
        chips.push(['dome', 'Dome']);
        chips.push(['size', `${Math.round(z.radius * 2)}m across`]);
    } else {
        chips.push(['walls', 'Walls']);
        chips.push(['size', `${z.points ? z.points.length : 0} corners`]);
        chips.push(['size', `${Math.round((z.maxZ || 0) - (z.minZ || 0))}m tall`]);
    }

    chips.push(z.solid ? ['blocks', 'Blocks players'] : ['pass', 'Passable']);
    if (z.visible === false) chips.push(['hidden', 'Not drawn']);

    (z.tags || []).forEach((t) => chips.push(['tag', t]));

    return chips;
}

function renderList() {
    const list = $('list');
    const count = $('count');

    list.innerHTML = '';

    const n = S.zones.length;
    count.textContent = n === 0
        ? 'no zones yet'
        : (n === 1 ? '1 zone' : `${n} zones`);

    show($('empty'), n === 0);

    S.zones
        .slice()
        .sort((a, b) => a.id - b.id)
        .forEach((z) => {
            const row = document.createElement('div');
            row.className = 'row';

            const main = document.createElement('div');
            main.className = 'row-main';

            const dot = document.createElement('span');
            dot.className = 'dot';
            dot.style.background = rgb(z.color || PALETTE[0]);
            if (z.visible === false) dot.style.opacity = '0.3';

            const text = document.createElement('div');

            const name = document.createElement('div');
            name.className = 'row-name';
            name.innerHTML = `<span class="zid">#${z.id}</span>`;
            name.appendChild(document.createTextNode(z.name));

            const meta = document.createElement('div');
            meta.className = 'row-meta';
            zoneMeta(z).forEach(([kind, label]) => {
                const c = document.createElement('span');
                c.className = `chip ${kind}`;
                c.textContent = label;
                meta.appendChild(c);
            });

            text.appendChild(name);
            text.appendChild(meta);
            main.appendChild(text);
            row.appendChild(dot);

            const acts = document.createElement('div');
            acts.className = 'row-acts';

            const go = document.createElement('button');
            go.textContent = 'Fly here';
            go.onclick = () => post('goto', { zone: z });

            const edit = document.createElement('button');
            edit.textContent = 'Edit';
            edit.onclick = () => openExisting(z);

            const reshape = document.createElement('button');
            reshape.textContent = 'Reshape';
            reshape.onclick = () => {
                S.editingId = z.id;
                S.color = z.color || PALETTE[0];
                S.solid = z.solid !== false;
                S.visible = z.visible !== false;
                S.tags = Array.isArray(z.tags) ? z.tags.slice() : [];
                closePanels();
                post('draw', { mode: z.kind === 'sphere' ? 'sphere' : 'poly', zone: z });
            };

            const del = document.createElement('button');
            del.className = 'danger';
            del.textContent = 'Delete';
            del.onclick = () => {
                if (del.dataset.armed === '1') {
                    post('delete', { id: z.id });
                    return;
                }
                del.dataset.armed = '1';
                del.textContent = 'Sure?';
                setTimeout(() => {
                    del.dataset.armed = '0';
                    del.textContent = 'Delete';
                }, 2500);
            };

            const vis = document.createElement('button');
            vis.textContent = z.visible === false ? 'Show' : 'Hide';
            vis.onclick = () => post('updateZone', {
                id: z.id,
                name: z.name,
                solid: z.solid,
                visible: z.visible === false,
                color: z.color,
                tags: z.tags || []
            });

            acts.appendChild(go);
            acts.appendChild(vis);
            acts.appendChild(edit);
            acts.appendChild(reshape);
            acts.appendChild(del);

            row.appendChild(main);
            row.appendChild(acts);
            list.appendChild(row);
        });
}


/* ============================================================
   SWATCHES
   ============================================================ */

function renderSwatches() {
    const wrap = $('f-colors');
    wrap.innerHTML = '';

    PALETTE.forEach((c) => {
        const b = document.createElement('button');
        b.className = 'swatch';
        b.style.background = rgb(c);
        b.setAttribute('aria-label', `Colour ${rgb(c)}`);
        if (sameColor(c, S.color)) b.dataset.on = 'true';

        b.onclick = () => {
            S.color = c;
            renderSwatches();
            if (S.context === 'draft') post('patch', { color: c });
        };

        wrap.appendChild(b);
    });
}


/* ============================================================
   SOLID TOGGLE
   ============================================================ */

function paintSolid() {
    const btn = $('f-solid');
    btn.dataset.on = S.solid ? 'true' : 'false';
    $('f-solid-label').textContent = S.solid
        ? 'Players cannot leave'
        : 'Players can walk through';
    $('f-solid-sub').textContent = S.solid
        ? 'They get pushed back at the edge'
        : 'The shell is shown but never blocks';
}

$('f-solid').onclick = () => {
    S.solid = !S.solid;
    paintSolid();
    if (S.context === 'draft') post('patch', { solid: S.solid });
};


/* ============================================================
   FORM
   ============================================================ */

function renderTags() {
    const wrap = $('f-tags');
    wrap.innerHTML = '';

    S.tags.forEach((t, i) => {
        const b = document.createElement('button');
        b.textContent = t;
        b.title = 'Remove this tag';
        b.onclick = () => {
            S.tags.splice(i, 1);
            renderTags();
        };
        wrap.appendChild(b);
    });
}

function addTag(raw) {
    const t = (raw || '').trim().toLowerCase().replace(/[^\w-]/g, '');
    if (!t || S.tags.includes(t) || S.tags.length >= 8) return;
    S.tags.push(t);
    renderTags();
}

$('f-tagadd').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    addTag($('f-tagadd').value);
    $('f-tagadd').value = '';
});

function fillForm(z, isSphere) {
    $('f-name').value = z.name && z.name !== 'New zone' ? z.name : '';
    show($('f-sphere-row'), isSphere);
    show($('f-poly-row'), !isSphere);

    if (isSphere) {
        $('f-radius').min = S.limits.minRadius;
        $('f-radius').max = S.limits.maxRadius;
        $('f-radius').value = Number(z.radius || 40).toFixed(1);
    } else {
        $('f-minz').value = Number(z.minZ || 0).toFixed(1);
        $('f-maxz').value = Number(z.maxZ || 0).toFixed(1);
    }

    S.color = z.color || PALETTE[0];
    S.solid = z.solid !== false;
    S.visible = z.visible !== false;
    S.tags = Array.isArray(z.tags) ? z.tags.slice() : [];
    $('f-tagadd').value = '';

    paintSolid();
    renderSwatches();
    renderTags();
}

function openDraftForm(zone, editingId) {
    S.context = 'draft';
    S.draft = zone;
    S.editingId = editingId || null;
    S.existing = null;

    $('form-title').textContent = editingId ? 'Update this zone' : 'Name this zone';
    $('form-back').textContent = 'Keep shaping';
    $('f-save').textContent = editingId ? 'Save changes' : 'Save zone';

    fillForm(zone, zone.kind === 'sphere');

    show($('rail'), false);
    show($('readout'), false);
    show($('form'), true);
    $('f-name').focus();
}

function openExisting(z) {
    S.context = 'existing';
    S.existing = z;
    S.draft = null;
    S.editingId = z.id;

    $('form-title').textContent = 'Edit zone';
    $('form-back').textContent = 'Back to list';
    $('f-save').textContent = 'Save changes';

    fillForm(z, z.kind === 'sphere');

    show($('rail'), false);
    show($('form'), true);
}

function backToList() {
    S.context = null;
    S.draft = null;
    S.existing = null;
    S.editingId = null;
    show($('form'), false);
    show($('rail'), true);
}

$('form-back').onclick = () => {
    if (S.context === 'draft') {
        show($('form'), false);
        show($('readout'), true);
        post('resume', {});
    } else {
        backToList();
    }
};

$('f-discard').onclick = () => {
    post('discard', {});
    backToList();
};

$('f-save').onclick = () => {
    const name = ($('f-name').value || '').trim();
    if (!name) {
        toast(false, 'Give the zone a name first');
        $('f-name').focus();
        return;
    }

    const payload = {
        name: name,
        solid: S.solid,
        visible: S.visible,
        color: S.color,
        tags: S.tags
    };

    const isSphere = S.context === 'draft'
        ? S.draft.kind === 'sphere'
        : S.existing.kind === 'sphere';

    if (isSphere) {
        payload.radius = parseFloat($('f-radius').value);
    } else {
        payload.minZ = parseFloat($('f-minz').value);
        payload.maxZ = parseFloat($('f-maxz').value);
    }

    if (S.context === 'draft') {
        post('save', payload);
    } else {
        payload.id = S.existing.id;
        post('updateZone', payload);
    }

    backToList();
};

// Live preview while the draft form is open.
['f-radius', 'f-minz', 'f-maxz'].forEach((id) => {
    $(id).addEventListener('input', () => {
        if (S.context !== 'draft') return;
        const patch = {};
        const v = parseFloat($(id).value);
        if (isNaN(v)) return;
        if (id === 'f-radius') patch.radius = v;
        if (id === 'f-minz') patch.minZ = v;
        if (id === 'f-maxz') patch.maxZ = v;
        post('patch', patch);
    });
});

$('f-name').addEventListener('input', () => {
    if (S.context === 'draft') post('patch', { name: $('f-name').value });
});


/* ============================================================
   SHAPE BUTTONS
   ============================================================ */

document.querySelectorAll('.make-btn').forEach((btn) => {
    btn.onclick = () => {
        const mode = btn.dataset.mode;
        S.editingId = null;
        S.color = PALETTE[0];
        S.solid = true;
        S.visible = true;
        S.tags = [];
        closePanels();
        post('draw', { mode: mode });
    };
});

function closePanels() {
    show($('rail'), false);
    show($('form'), false);
}


/* ============================================================
   READOUT + KEYSTRIP
   ============================================================ */

function setMetric(value, unit, label) {
    $('metric-value').textContent = value;
    $('metric-unit').textContent = unit;
    $('metric-label').textContent = label;
}


/* ============================================================
   TOAST + WARNING
   ============================================================ */

function toast(ok, text) {
    const el = $('toast');
    el.textContent = text;
    el.dataset.ok = ok ? 'true' : 'false';
    show(el, true);

    clearTimeout(S.toastTimer);
    S.toastTimer = setTimeout(() => show(el, false), 3200);
}

function warning(title, text, hold) {
    $('warn-title').textContent = title;
    $('warn-text').textContent = text;
    show($('warning'), true);

    clearTimeout(S.warnTimer);
    S.warnTimer = setTimeout(() => show($('warning'), false), hold || 3000);
}


/* ============================================================
   MESSAGES FROM LUA
   ============================================================ */

window.addEventListener('message', (ev) => {
    const d = ev.data || {};

    switch (d.action) {
        case 'open':
            S.zones = d.zones || [];
            if (d.limits) S.limits = d.limits;
            renderList();
            show($('form'), false);
            show($('readout'), false);
            show($('keys'), false);
            show($('rail'), true);
            break;

        case 'close':
            show($('rail'), false);
            show($('form'), false);
            show($('readout'), false);
            show($('keys'), false);
            break;

        case 'zones':
            S.zones = d.zones || [];
            renderList();
            break;

        case 'draft':
            show($('keys'), false);
            openDraftForm(d.zone, d.editingId);
            break;

        case 'keys':
            show($('keys'), !!d.show);
            if (d.show) {
                const poly = d.mode === 'poly';
                show($('k-mark'), true);
                show($('k-undo'), poly);
                show($('k-lift'), !poly);
                $('k-mark').lastChild.textContent = poly ? 'mark corner' : 'drop centre';
                $('k-scroll').lastChild.textContent = poly ? 'speed' : 'size';
                show($('readout'), true);
                setMetric(poly ? '0' : '40.0', poly ? '' : 'm', poly ? 'corners marked' : 'radius');
            } else {
                show($('readout'), false);
            }
            break;

        case 'radius':
            setMetric(Number(d.value).toFixed(1), 'm', 'radius');
            break;

        case 'points':
            setMetric(String(d.count), '', d.count === 1 ? 'corner marked' : 'corners marked');
            break;

        case 'speed':
            $('k-speed').textContent = Number(d.value).toFixed(1);
            break;

        case 'cancelled':
            // Drawing was cancelled in game. Bring the list back —
            // without this the page keeps focus with nothing on screen
            // and no way out but restarting the resource.
            S.context = null;
            S.draft = null;
            S.existing = null;
            S.editingId = null;
            show($('form'), false);
            show($('readout'), false);
            show($('keys'), false);
            show($('rail'), true);
            renderList();
            break;

        case 'lift':
            $('metric-label').textContent = Number(d.value) === 0
                ? 'radius'
                : `radius · centre ${Number(d.value) > 0 ? '+' : ''}${Number(d.value).toFixed(1)}m`;
            break;

        case 'noclip':
            break;

        case 'anchored':
            $('k-mark').lastChild.textContent = d.on ? 'release centre' : 'drop centre';
            break;

        case 'toast':
            if (d.text) toast(d.ok, d.text);
            break;

        case 'warning':
            warning(d.title, d.text, d.hold);
            break;

        case 'hideWarning':
            show($('warning'), false);
            break;
    }
});


/* ============================================================
   KEYBOARD
   ============================================================ */

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;

    if (!$('form').hidden) {
        if (S.context === 'draft') {
            show($('form'), false);
            show($('readout'), true);
            post('resume', {});
        } else {
            backToList();
        }
        return;
    }

    if (!$('rail').hidden) post('close', {});
});

$('close').onclick = () => post('close', {});

renderSwatches();
paintSolid();
