const app      = document.getElementById('app');
const grid     = document.getElementById('grid');
const search   = document.getElementById('search');
const countEl  = document.getElementById('count');
const amountWrap = document.getElementById('amountWrap');
const amountEl = document.getElementById('amount');
const showcaseBtn = document.getElementById('showcaseBtn');
const vanillaBtn = document.getElementById('vanillaBtn');
const photoBtn = document.getElementById('photoBtn');
const importBar = document.getElementById('importBar');
const importInput = document.getElementById('importInput');
const preview = document.getElementById('preview');
const previewImg = document.getElementById('previewImg');

let DATA = { vehicles: [], items: [], imports: [], captured: {}, imageUrls: {} };
let currentTab = 'vehicles';
let showcase = false;
let hideVanilla = false;
const RENDER_CAP = 250;

const carIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M5 13l1.5-4.5A2 2 0 018.4 7h7.2a2 2 0 011.9 1.5L19 13M5 13h14v4a1 1 0 01-1 1h-1a1 1 0 01-1-1v-1H8v1a1 1 0 01-1 1H6a1 1 0 01-1-1v-4z"/><circle cx="8" cy="15" r="1"/><circle cx="16" cy="15" r="1"/></svg>`;
const boxIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M21 8l-9-5-9 5 9 5 9-5zM3 8v8l9 5 9-5V8M12 13v8"/></svg>`;
// NEW v2: pencil icon for rename
const pencilIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>`;
// NEW v2: undo icon for reset-to-default
const undoIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 00-15-6.7L3 13"/></svg>`;

function getResourceName() {
    try { return window.GetParentResourceName ? GetParentResourceName() : 'spawn_menu'; }
    catch (e) { return 'spawn_menu'; }
}

function post(name, data) {
    fetch(`https://${getResourceName()}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
    }).catch(() => {});
}

function render() {
    const q = search.value.trim().toLowerCase();
    let list;
    if (currentTab === 'vehicles') list = DATA.vehicles;
    else if (currentTab === 'import') list = DATA.imports;
    else list = DATA.items;

    if (currentTab === 'vehicles' && hideVanilla) {
        list = list.filter(o => !o.vanilla);
    }

    const filtered = q
        ? list.filter(o =>
            (o.label || '').toLowerCase().includes(q) ||
            (o.model || o.name || '').toLowerCase().includes(q))
        : list;

    grid.innerHTML = '';
    countEl.textContent = `${filtered.length} result${filtered.length === 1 ? '' : 's'}`;

    if (filtered.length === 0) {
        const msg = currentTab === 'import'
            ? 'No imported cars yet. Paste spawn codes above and hit "Add to Import".'
            : 'No matches. Try a different search.';
        grid.innerHTML = `<div class="empty">${msg}</div>`;
        return;
    }

    const slice = filtered.slice(0, RENDER_CAP);
    const frag = document.createDocumentFragment();

    function makeThumb(imgUrl, iconSvg, card) {
        const thumb = document.createElement('div');
        thumb.className = 'thumb';
        const img = document.createElement('img');
        img.src = imgUrl;
        img.onload = () => { if (card) card.dataset.img = imgUrl; };
        img.onerror = () => { thumb.innerHTML = iconSvg; if (card) delete card.dataset.img; };
        thumb.appendChild(img);
        return thumb;
    }

    const vehImg = (m) => (DATA.imageUrls && DATA.imageUrls[m]) ? DATA.imageUrls[m] : `nui://spawn_menu/images/${m}.png`;
    const oxImg  = (n) => `nui://ox_inventory/web/images/${n}.png`;

    // NEW v2: turn a card's label into an inline-editable field
    function enterRenameMode(card, lblEl, o) {
        lblEl.style.display = 'none';
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'rename-input';
        input.value = o.label;
        input.maxLength = 60;
        card.insertBefore(input, lblEl);
        input.focus();
        input.select();

        let finished = false;
        const commit = () => {
            if (finished) return;
            finished = true;
            const val = input.value.trim();
            input.remove();
            lblEl.style.display = '';
            if (val && val !== o.label) {
                o.label = val;
                lblEl.textContent = val;
                post('renameVehicle', { model: o.model, label: val });
            }
        };
        const cancel = () => {
            if (finished) return;
            finished = true;
            input.remove();
            lblEl.style.display = '';
        };

        input.addEventListener('keydown', (e) => {
            e.stopPropagation();
            if (e.key === 'Enter') commit();
            else if (e.key === 'Escape') cancel();
        });
        input.addEventListener('blur', commit);
        input.addEventListener('click', (e) => e.stopPropagation());
    }

    slice.forEach(o => {
        const card = document.createElement('div');
        card.className = 'card';

        if (currentTab === 'vehicles' || currentTab === 'import') {
            card.appendChild(makeThumb(vehImg(o.model), carIcon, card));

            const lbl = document.createElement('div'); lbl.className = 'label'; lbl.textContent = o.label;
            const sub = document.createElement('div'); sub.className = 'sub'; sub.textContent = o.model;
            card.appendChild(lbl); card.appendChild(sub);

            card.onclick = () => post('spawnVehicle', { model: o.model, showcase: showcase });

            if (currentTab === 'vehicles' && DATA.captured && DATA.captured[o.model]) {
                const done = document.createElement('span'); done.className = 'badge done'; done.textContent = '✓ photo';
                card.appendChild(done);
            }

            // NEW v2: "renamed" badge if this car has a custom name saved
            if (o.renamed) {
                const rb = document.createElement('span'); rb.className = 'badge renamed'; rb.textContent = 'renamed';
                card.appendChild(rb);
            }

            // NEW v2: rename pencil button (top-right of card)
            const renameBtn = document.createElement('button');
            renameBtn.className = 'card-action rename-btn';
            renameBtn.title = 'Rename this vehicle';
            renameBtn.innerHTML = pencilIcon;
            renameBtn.onclick = (e) => {
                e.stopPropagation();
                enterRenameMode(card, lbl, o);
            };
            card.appendChild(renameBtn);

            // NEW v2: reset-to-default button, only shown if renamed
            if (o.renamed) {
                const resetBtn = document.createElement('button');
                resetBtn.className = 'card-action reset-btn';
                resetBtn.title = 'Reset to default name';
                resetBtn.innerHTML = undoIcon;
                resetBtn.onclick = (e) => {
                    e.stopPropagation();
                    post('resetVehicleName', { model: o.model });
                    // optimistic local update; server push will confirm via 'vehicles' message
                    o.label = o.defaultLabel || o.model;
                    o.renamed = false;
                    render();
                };
                card.appendChild(resetBtn);
            }

            if (currentTab === 'import') {
                const rh = document.createElement('div'); rh.className = 'remove-hint'; rh.textContent = 'right-click to remove';
                card.appendChild(rh);
                card.oncontextmenu = (e) => { e.preventDefault(); post('removeImport', { model: o.model }); };
            }
        } else {
            card.appendChild(makeThumb(oxImg(o.name), boxIcon, card));
            const lbl = document.createElement('div'); lbl.className = 'label'; lbl.textContent = o.label;
            const sub = document.createElement('div'); sub.className = 'sub'; sub.textContent = o.name;
            card.appendChild(lbl); card.appendChild(sub);
            if (o.weapon) {
                const b = document.createElement('span'); b.className = 'badge weapon'; b.textContent = 'Weapon';
                card.appendChild(b);
            }
            card.onclick = () => {
                const amt = Math.max(1, parseInt(amountEl.value) || 1);
                post('giveItem', { name: o.name, amount: amt });
            };
        }

        card.addEventListener('mouseenter', () => { if (card.dataset.img) showPreview(card.dataset.img); });
        card.addEventListener('mouseleave', hidePreview);
        frag.appendChild(card);
    });

    grid.appendChild(frag);

    if (filtered.length > RENDER_CAP) {
        const more = document.createElement('div');
        more.className = 'empty';
        more.style.padding = '20px 0';
        more.textContent = `Showing first ${RENDER_CAP} of ${filtered.length} — refine your search to narrow down.`;
        grid.appendChild(more);
    }
}

function switchTab(tab) {
    currentTab = tab;
    document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
    amountWrap.style.display = tab === 'items' ? 'flex' : 'none';
    showcaseBtn.style.display = (tab === 'vehicles' || tab === 'import') ? 'flex' : 'none';
    vanillaBtn.style.display = tab === 'vehicles' ? 'flex' : 'none';
    photoBtn.style.display = tab === 'vehicles' ? 'flex' : 'none';
    importBar.classList.toggle('hidden', tab !== 'import');
    hidePreview();
    search.value = '';
    render();
    search.focus();
}

showcaseBtn.onclick = () => {
    showcase = !showcase;
    showcaseBtn.classList.toggle('on', showcase);
};

vanillaBtn.onclick = () => {
    hideVanilla = !hideVanilla;
    vanillaBtn.classList.toggle('on', hideVanilla);
    render();
};

photoBtn.onclick = () => {
    let list = DATA.vehicles;
    if (hideVanilla) list = list.filter(o => !o.vanilla);
    const q = search.value.trim().toLowerCase();
    if (q) list = list.filter(o => (o.label||'').toLowerCase().includes(q) || (o.model||'').toLowerCase().includes(q));
    const models = list.map(o => o.model).filter(m => !(DATA.captured && DATA.captured[m]));
    if (models.length === 0) {
        countEl.textContent = 'All shown cars already captured — right-click "Take Pictures" to reset';
        return;
    }
    app.classList.add('hidden');
    post('capturePhotos', { models });
};
photoBtn.oncontextmenu = (e) => { e.preventDefault(); post('resetPhotos'); };

function showPreview(url) {
    previewImg.src = url;
    preview.classList.remove('hidden');
}
function hidePreview() { preview.classList.add('hidden'); }
document.addEventListener('mousemove', (e) => {
    if (preview.classList.contains('hidden')) return;
    let x = e.clientX + 20, y = e.clientY + 20;
    if (x + 330 > window.innerWidth) x = e.clientX - 340;
    if (y + 210 > window.innerHeight) y = e.clientY - 220;
    preview.style.left = x + 'px';
    preview.style.top = y + 'px';
});

document.getElementById('addImportBtn').onclick = () => {
    const text = importInput.value.trim();
    if (text.length === 0) return;
    post('addImports', { text });
    importInput.value = '';
};
document.getElementById('clearImportBtn').onclick = () => post('clearImports');

document.querySelectorAll('.tab').forEach(t => t.onclick = () => switchTab(t.dataset.tab));
search.addEventListener('input', render);
document.getElementById('closeBtn').onclick = () => { app.classList.add('hidden'); post('close'); };

window.addEventListener('message', (ev) => {
    const d = ev.data;
    if (d.action === 'open') {
        DATA.vehicles = d.vehicles || [];
        DATA.items = d.items || [];
        DATA.imports = d.imports || [];
        DATA.captured = d.captured || {};
        DATA.imageUrls = d.imageUrls || {};
        app.classList.remove('hidden');
        switchTab('vehicles');
    } else if (d.action === 'imports') {
        DATA.imports = d.imports || [];
        if (currentTab === 'import') render();
    } else if (d.action === 'captured') {
        DATA.captured = d.captured || {};
        if (currentTab === 'vehicles') render();
    } else if (d.action === 'vehicles') {
        // NEW v2: server pushed a refreshed list after rename/reset
        DATA.vehicles = d.vehicles || DATA.vehicles;
        DATA.imports = d.imports || DATA.imports;
        if (currentTab === 'vehicles' || currentTab === 'import') render();
    } else if (d.action === 'close') {
        app.classList.add('hidden');
    }
});

(function () {
    const panel = document.querySelector('.panel');
    const header = document.querySelector('header');
    let dragging = false, offX = 0, offY = 0;

    header.addEventListener('mousedown', (e) => {
        if (e.target.closest('button, .tabs')) return;
        const rect = panel.getBoundingClientRect();
        panel.style.transform = 'none';
        panel.style.left = rect.left + 'px';
        panel.style.top = rect.top + 'px';
        offX = e.clientX - rect.left;
        offY = e.clientY - rect.top;
        dragging = true;
        e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
        if (!dragging) return;
        let x = e.clientX - offX, y = e.clientY - offY;
        x = Math.max(0, Math.min(x, window.innerWidth - panel.offsetWidth));
        y = Math.max(0, Math.min(y, window.innerHeight - panel.offsetHeight));
        panel.style.left = x + 'px';
        panel.style.top = y + 'px';
    });

    document.addEventListener('mouseup', () => { dragging = false; });
})();

document.addEventListener('keyup', (e) => {
    if (e.key === 'Escape') { app.classList.add('hidden'); post('close'); }
});
