const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'aec';
const $ = (id) => document.getElementById(id);
const esc = (s) => (s == null ? '' : String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c])));

/* ---- clean inline icons (lucide-style) ---- */
const sv = (p) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${p}</svg>`;
const IC = {
  building: sv('<rect x="4" y="2" width="16" height="20" rx="2"/><path d="M9 22v-4h6v4M9 6h.01M15 6h.01M9 10h.01M15 10h.01M9 14h.01M15 14h.01"/>'),
  dash: sv('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/>'),
  plus: sv('<path d="M12 5v14M5 12h14"/>'),
  list: sv('<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>'),
  x: sv('<path d="M18 6 6 18M6 6l12 12"/>'),
  layers: sv('<path d="m12 2 9 5-9 5-9-5 9-5z"/><path d="M3 12l9 5 9-5M3 17l9 5 9-5"/>'),
  activity: sv('<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>'),
  pin: sv('<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>'),
  edit: sv('<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>'),
  trash: sv('<path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2m2 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/>'),
  car: sv('<path d="M7 17h10M5 17H3v-4l2-5h14l2 5v4h-2"/><circle cx="7" cy="17" r="2"/><circle cx="17" cy="17" r="2"/>'),
  floor: sv('<rect x="4" y="2" width="16" height="20" rx="2"/><path d="m9 9 3-3 3 3M9 15l3 3 3-3"/>'),
  lock: sv('<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>'),
};

async function nui(name, data = {}) {
  try {
    const r = await fetch(`https://${RES}/${name}`, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data) });
    return await r.json();
  } catch (e) { return null; }
}

/* ---- toast + confirm (replace ugly browser alert/confirm) ---- */
function toast(msg, type){
  const t=document.createElement('div');
  t.className='toast'+(type?(' '+type):'');
  t.textContent=msg;
  $('toasts').appendChild(t);
  setTimeout(()=>{ t.style.opacity='0'; t.style.transition='opacity .3s'; setTimeout(()=>t.remove(),300); }, 2600);
}
function confirmModal(title, msg){
  return new Promise((resolve)=>{
    const bg=document.createElement('div'); bg.id='cmodalBg';
    bg.innerHTML=`<div class="cmodal"><h4>${esc(title)}</h4><p>${esc(msg)}</p>
      <div class="crow"><button class="btn ghost" data-no>Cancel</button><button class="btn danger" data-yes>Delete</button></div></div>`;
    document.body.appendChild(bg);
    bg.querySelector('[data-yes]').onclick=()=>{ bg.remove(); resolve(true); };
    bg.querySelector('[data-no]').onclick=()=>{ bg.remove(); resolve(false); };
  });
}

const S = {
  elevators: [],
  view: 'dashboard',
  // wizard draft
  draft: null,   // { id?, name, allowVehicles, floors:[{label,x,y,z,h}], access:{level,jobs,items,passcode} }
  step: 1,
};

/* ================= AUDIO (travel) ================= */
let actx = null, hummer = null;
function ctx(){ if(!actx){ try{ actx = new (window.AudioContext||window.webkitAudioContext)(); }catch(e){ actx=null; } } return actx; }
function startHum(dur){
  const a=ctx(); if(!a) return; stopHum();
  const o=a.createOscillator(), o2=a.createOscillator(), g=a.createGain();
  o.type='sine'; o.frequency.value=66; o2.type='sine'; o2.frequency.value=132; g.gain.value=0;
  o.connect(g); o2.connect(g); g.connect(a.destination);
  const now=a.currentTime, end=now+dur/1000;
  g.gain.linearRampToValueAtTime(0.05, now+0.4);
  g.gain.setValueAtTime(0.05, end-0.35);
  g.gain.linearRampToValueAtTime(0, end);
  o.start(now); o2.start(now); o.stop(end+0.05); o2.stop(end+0.05);
  hummer={o,o2};
}
function stopHum(){ if(!hummer) return; try{ hummer.o.stop(); hummer.o2.stop(); }catch(e){} hummer=null; }
function gbam(){
  const a=ctx(); if(!a) return;
  // low thud
  const o=a.createOscillator(), g=a.createGain();
  o.type='sine'; o.frequency.setValueAtTime(125,a.currentTime);
  o.frequency.exponentialRampToValueAtTime(42,a.currentTime+0.19);
  g.gain.setValueAtTime(0.0001,a.currentTime);
  g.gain.linearRampToValueAtTime(0.55,a.currentTime+0.01);
  g.gain.exponentialRampToValueAtTime(0.0001,a.currentTime+0.36);
  o.connect(g); g.connect(a.destination); o.start(); o.stop(a.currentTime+0.4);
  // metallic clank (filtered noise)
  const buf=a.createBuffer(1,Math.floor(a.sampleRate*0.16),a.sampleRate), d=buf.getChannelData(0);
  for(let i=0;i<d.length;i++) d[i]=(Math.random()*2-1)*Math.pow(1-i/d.length,2.4);
  const n=a.createBufferSource(); n.buffer=buf;
  const bp=a.createBiquadFilter(); bp.type='bandpass'; bp.frequency.value=2600; bp.Q.value=1.3;
  const ng=a.createGain(); ng.gain.value=0.3;
  n.connect(bp); bp.connect(ng); ng.connect(a.destination); n.start(a.currentTime+0.02);
}
function ding(){
  const a=ctx(); if(!a) return;
  [[880,0.28],[1174.66,0.42]].forEach(([f,t])=>{
    const o=a.createOscillator(), g=a.createGain(); o.type='sine'; o.frequency.value=f;
    o.connect(g); g.connect(a.destination); const s=a.currentTime+t;
    g.gain.setValueAtTime(0.0001,s); g.gain.linearRampToValueAtTime(0.26,s+0.01);
    g.gain.exponentialRampToValueAtTime(0.0001,s+0.4); o.start(s); o.stop(s+0.45);
  });
}
function showTravel(floor,dur,audio){
  $('t-floor').textContent = floor||'Floor';
  const t=$('travel'); t.classList.remove('hidden'); void t.offsetWidth; t.classList.add('show');
  const f=$('t-fill'); f.style.transition='none'; f.style.width='0%'; void f.offsetWidth;
  f.style.transition=`width ${dur}ms linear`; f.style.width='100%';
  if(audio){ try{ if(ctx()&&actx.state==='suspended') actx.resume(); }catch(e){} startHum(dur); }
}
function hideTravel(){ const t=$('travel'); t.classList.remove('show'); setTimeout(()=>t.classList.add('hidden'),350); }

/* ================= FLOOR PICKER (in-world) ================= */
function showPicker(elev, needsPasscode){
  $('picker').classList.remove('hidden');
  $('pTitle').textContent = elev.name || 'Elevator';
  if(needsPasscode){ renderPasscode(); } else { renderPickerFloors(elev); }
}
function hidePicker(){ $('picker').classList.add('hidden'); }
function renderPasscode(err){
  $('pBody').innerHTML = `<div class="pcode">
      <div class="pcode-ic">${IC.lock}</div>
      <label style="margin:0">Enter passcode</label>
      <input id="pInput" type="password" placeholder="••••" />
      <div class="perr">${err?esc(err):''}</div>
      <button class="btn" id="pSubmit">Unlock</button>
    </div>`;
  const inp=$('pInput'); inp.focus();
  $('pSubmit').onclick=()=>nui('submitPasscode', { code: inp.value });
  inp.onkeydown=(e)=>{ if(e.key==='Enter') nui('submitPasscode', { code: inp.value }); };
}
function renderPickerFloors(elev){
  const veh = elev.allowVehicles;
  $('pBody').innerHTML = elev.floors.map((f,i)=> i===elev.fromIndex ? '' :
    `<div class="fbtn" data-pick="${i}">
       <div class="fi">${IC.floor}</div>
       <div><div class="ft">${esc(f.label)}</div><div class="fs">${veh?'Vehicles allowed':'Tap to travel'}</div></div>
     </div>`).join('');
  $('pBody').querySelectorAll('[data-pick]').forEach(el=>el.onclick=()=>nui('pickFloor', { index: parseInt(el.dataset.pick) }));
}
function setView(v){
  S.view=v;
  document.querySelectorAll('.nav-item').forEach(n=>n.classList.toggle('active', n.dataset.view===v));
  document.querySelectorAll('.view').forEach(s=>s.classList.add('hidden'));
  $('view-'+v).classList.remove('hidden');
  if(v==='dashboard') renderDashboard();
  if(v==='list') renderList();
  if(v==='create') { if(!S.draft) newDraft(); renderWizard(); }
}

function renderDashboard(){
  const totalFloors = S.elevators.reduce((a,e)=>a+(e.floors?e.floors.length:0),0);
  const totalUses = S.elevators.reduce((a,e)=>a+(e.uses||0),0);
  $('stats').innerHTML = `
    ${stat(IC.building, S.elevators.length, 'Total Elevators')}
    ${stat(IC.layers, totalFloors, 'Total Floors')}
    ${stat(IC.activity, totalUses, 'Uses Today')}`;
  const r=$('recent');
  if(!S.elevators.length){ r.innerHTML='<div class="ritem">No elevators yet — create your first one.</div>'; return; }
  r.innerHTML = S.elevators.slice(-5).reverse().map(e=>
    `<div class="ritem"><b>${esc(e.name)}</b> — ${e.floors.length} floors · ${e.access&&e.access.public?'Public':'Restricted'}${e.access&&e.access.allowVehicles?' · vehicles':''}</div>`).join('');
}
function stat(ic,n,l){ return `<div class="stat"><div class="ic">${ic}</div><div><div class="n">${n}</div><div class="l">${l}</div></div></div>`; }

function renderList(){
  const b=$('listBody'); const empty=$('listEmpty');
  if(!S.elevators.length){ b.innerHTML=''; empty.classList.remove('hidden'); return; }
  empty.classList.add('hidden');
  b.innerHTML = S.elevators.map(e=>{
    const pub = e.access && e.access.public;
    return `<tr>
      <td><b>${esc(e.name)}</b></td>
      <td>${e.floors.length}</td>
      <td><span class="badge ${pub?'pub':'res'}">${pub?'Public':'Restricted'}</span></td>
      <td>${e.access&&e.access.allowVehicles?`<span class="vyes">${IC.car} Yes</span>`:'—'}</td>
      <td>${e.uses||0}</td>
      <td class="actions">
        <button class="btn ghost tiny" data-tp="${e.id}">${IC.pin} Go</button>
        <button class="btn ghost tiny" data-edit="${e.id}">${IC.edit} Edit</button>
        <button class="btn danger tiny ic-only" data-del="${e.id}">${IC.trash}</button>
      </td></tr>`;
  }).join('');
  b.querySelectorAll('[data-tp]').forEach(el=>el.onclick=()=>{
    const e=S.elevators.find(x=>x.id==el.dataset.tp); if(e&&e.floors[0]) nui('teleportTo', e.floors[0]);
  });
  b.querySelectorAll('[data-edit]').forEach(el=>el.onclick=()=>editElevator(el.dataset.edit));
  b.querySelectorAll('[data-del]').forEach(el=>el.onclick=async()=>{
    const ok = await confirmModal('Delete elevator', 'This removes the elevator and all its floors. This cannot be undone.');
    if(!ok) return;
    await nui('deleteElevator', { id: parseInt(el.dataset.del) });
  });
}

/* ---------- Wizard ---------- */
function newDraft(){
  S.draft = { name:'', allowVehicles:false, floors:[ blankFloor(1) ], access:{ level:'public', jobs:[], items:[], passcode:'' } };
  S.step = 1;
  $('createTitle').textContent='Create Elevator';
}
function blankFloor(i){ return { label: i===1?'Ground Floor':('Floor '+(i-1)), x:null,y:null,z:null,h:null }; }

function editElevator(id){
  const e=S.elevators.find(x=>x.id==id); if(!e) return;
  S.draft = {
    id: e.id, name: e.name, allowVehicles: !!(e.access&&e.access.allowVehicles),
    floors: e.floors.map(f=>({...f})),
    access: {
      level: (e.access&&e.access.public)?'public':'restricted',
      jobs: (e.access&&e.access.jobs)||[], items:(e.access&&e.access.items)||[],
      passcode: (e.access&&e.access.passcode)?String(e.access.passcode):''
    }
  };
  S.step=1; $('createTitle').textContent='Edit Elevator';
  setView('create');
}

function renderWizard(){
  const d=S.draft;
  // step chips
  document.querySelectorAll('.step').forEach(s=>{
    const n=+s.dataset.step; s.classList.toggle('active', n===S.step); s.classList.toggle('done', n<S.step);
  });
  document.querySelectorAll('.wstep').forEach(w=>w.classList.toggle('hidden', +w.dataset.w!==S.step));
  // buttons
  $('prevBtn').style.visibility = S.step===1?'hidden':'visible';
  $('nextBtn').classList.toggle('hidden', S.step===4);
  $('saveBtn').classList.toggle('hidden', S.step!==4);

  if(S.step===1){ $('fName').value=d.name; $('fVeh').checked=d.allowVehicles; }
  if(S.step===2){ renderFloors(); }
  if(S.step===3){ $('fAccess').value=d.access.level; toggleRestrict(); renderTags(); $('fPass').value=d.access.passcode; }
  if(S.step===4){ renderReview(); }
}

function renderFloors(){
  const box=$('floors'); const d=S.draft;
  box.innerHTML = d.floors.map((f,i)=>{
    const set = f.x!=null;
    return `<div class="floor-row">
      <div class="top">
        <div class="idx">${i+1}</div>
        <input data-fl="${i}" value="${esc(f.label)}" placeholder="Floor name" maxlength="40" />
      </div>
      <div class="bottom">
        <span class="pos ${set?'set':''}">${set?`✓ position set  (${f.x}, ${f.y}, ${f.z})`:'⚠ no position set'}</span>
        <div class="fbtns">
          <button class="btn ghost tiny" data-setpos="${i}">${IC.pin} Set position</button>
          <button class="btn danger tiny" data-rmf="${i}">${IC.x} Remove</button>
        </div>
      </div>
    </div>`;
  }).join('');
  box.querySelectorAll('[data-fl]').forEach(el=>el.oninput=()=>{ d.floors[+el.dataset.fl].label=el.value; });
  box.querySelectorAll('[data-setpos]').forEach(el=>el.onclick=async()=>{
    const pos=await nui('capturePosition'); if(pos){ Object.assign(d.floors[+el.dataset.setpos], pos); renderFloors(); toast('Position captured','success'); }
  });
  box.querySelectorAll('[data-rmf]').forEach(el=>el.onclick=()=>{
    if(d.floors.length<=1){ toast('Keep at least one floor','error'); return; }
    d.floors.splice(+el.dataset.rmf,1); renderFloors();
  });
}

function toggleRestrict(){ $('restrictBox').classList.toggle('hidden', S.draft.access.level!=='restricted'); }
function renderTags(){
  const d=S.draft;
  $('jobTags').innerHTML = d.access.jobs.map((j,i)=>`<span class="tag">${esc(j)}<b data-rmjob="${i}">✕</b></span>`).join('');
  $('itemTags').innerHTML = d.access.items.map((it,i)=>`<span class="tag">${esc(it)}<b data-rmitem="${i}">✕</b></span>`).join('');
  $('jobTags').querySelectorAll('[data-rmjob]').forEach(el=>el.onclick=()=>{ d.access.jobs.splice(+el.dataset.rmjob,1); renderTags(); });
  $('itemTags').querySelectorAll('[data-rmitem]').forEach(el=>el.onclick=()=>{ d.access.items.splice(+el.dataset.rmitem,1); renderTags(); });
}

function renderReview(){
  const d=S.draft;
  const acc = d.access.level==='public' ? 'Public (anyone)' :
    `Restricted — jobs: ${d.access.jobs.join(', ')||'none'} · cards: ${d.access.items.join(', ')||'none'} · passcode: ${d.access.passcode||'none'}`;
  $('review').innerHTML = `
    ${rev('Name', d.name||'—')}
    ${rev('Floors', d.floors.map(f=>f.label).join(', '))}
    ${rev('Positions set', d.floors.filter(f=>f.x!=null).length+' / '+d.floors.length)}
    ${rev('Vehicles', d.allowVehicles?'Allowed':'No')}
    ${rev('Access', acc)}`;
}
function rev(k,v){ return `<div class="rev-row"><span class="k">${k}</span><span>${esc(v)}</span></div>`; }

function validateStep(){
  const d=S.draft;
  if(S.step===1){ if((d.name||'').trim().length<4){ toast('Name must be at least 4 characters','error'); return false; } }
  if(S.step===2){
    if(d.floors.length<2){ toast('Add at least 2 floors','error'); return false; }
    if(d.floors.some(f=>f.x==null)){ toast('Every floor needs a position - stand there and hit Set position','error'); return false; }
  }
  return true;
}

async function saveDraft(){
  const d=S.draft;
  const access = {
    public: d.access.level==='public',
    jobs: d.access.jobs, items: d.access.items,
    passcode: d.access.passcode||false, allowVehicles: d.allowVehicles
  };
  await nui('saveElevator', { id: d.id, name: d.name.trim(), floors: d.floors, access });
  S.draft=null;
  setView('list');
}

/* ================= wiring ================= */
function initAdmin(){
  document.querySelectorAll('.nav-item').forEach(n=>n.onclick=()=>setView(n.dataset.view));
  $('closeBtn').onclick=()=>{ $('admin').classList.add('hidden'); nui('closeAdmin'); };
  $('newBtn').onclick=()=>{ newDraft(); setView('create'); };
  $('nextBtn').onclick=()=>{ if(validateStep()){ S.step=Math.min(4,S.step+1); renderWizard(); } };
  $('prevBtn').onclick=()=>{ S.step=Math.max(1,S.step-1); renderWizard(); };
  $('saveBtn').onclick=saveDraft;
  $('addFloor').onclick=()=>{ S.draft.floors.push(blankFloor(S.draft.floors.length+1)); renderFloors(); };
  $('fName').oninput=()=>{ S.draft.name=$('fName').value; };
  $('fVeh').onchange=()=>{ S.draft.allowVehicles=$('fVeh').checked; };
  $('fAccess').onchange=()=>{ S.draft.access.level=$('fAccess').value; toggleRestrict(); };
  $('fPass').oninput=()=>{ S.draft.access.passcode=$('fPass').value; };
  $('jobInput').onkeydown=(e)=>{ if(e.key==='Enter'&&e.target.value.trim()){ S.draft.access.jobs.push(e.target.value.trim()); e.target.value=''; renderTags(); } };
  $('itemInput').onkeydown=(e)=>{ if(e.key==='Enter'&&e.target.value.trim()){ S.draft.access.items.push(e.target.value.trim()); e.target.value=''; renderTags(); } };
  document.addEventListener('keydown',(e)=>{ if(e.key==='Escape'&&!$('admin').classList.contains('hidden')){ $('admin').classList.add('hidden'); nui('closeAdmin'); } });
}

window.addEventListener('message',(e)=>{
  const m=e.data||{};
  if(m.action==='openAdmin'){
    S.elevators=m.elevators||[]; if(m.brand) $('brandName').textContent=m.brand;
    $('admin').classList.remove('hidden'); setView('dashboard');
  } else if(m.action==='setData'){
    S.elevators=m.elevators||[];
    if(S.view==='dashboard') renderDashboard(); if(S.view==='list') renderList();
  } else if(m.action==='travel'){
    showTravel(m.floor, m.duration||2500, m.audio);
  } else if(m.action==='arrived'){
    stopHum(); if(m.gbam) gbam(); if(m.ding) ding(); hideTravel();
  } else if(m.action==='floorPicker'){
    showPicker(m.elev, m.needsPasscode);
  } else if(m.action==='pickerFloors'){
    renderPickerFloors(m.elev);
  } else if(m.action==='passcodeError'){
    renderPasscode(m.error || 'Wrong passcode');
  } else if(m.action==='closePicker'){
    hidePicker();
  }
});

$('pClose').onclick=()=>nui('closeFloorPicker');
document.addEventListener('keydown',(e)=>{ if(e.key==='Escape'&&!$('picker').classList.contains('hidden')) nui('closeFloorPicker'); });

initAdmin();
