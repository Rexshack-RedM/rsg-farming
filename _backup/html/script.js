const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'rsg-farming';
const $ = (id) => document.getElementById(id);
const app = $('app'), plantPanel = $('plant-panel'), listPanel = $('list-panel');
let current = null;      // plant open in the single view
let lastList = [];

function post(name, data = {}) {
    return fetch(`https://${RES}/${name}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(data)
    }).catch(() => {});
}

const cls = (v, inverse) => {
    if (inverse) return v >= 100 ? 'stat-good' : v >= 50 ? 'stat-warn' : 'stat-warn';
    return v >= 50 ? 'stat-good' : v >= 20 ? 'stat-warn' : 'stat-bad';
};
const pct = (v) => `${Math.round(v)}%`;

function setBar(key, value, klass) {
    const bar = $(`b-${key}`);
    bar.style.width = `${Math.max(0, Math.min(100, value))}%`;
    bar.className = `fill ${klass}`;
    $(`v-${key}`).textContent = pct(value);
}

function statusOf(p) {
    if (p.dead) return { text: 'Dead', cls: 'bad' };
    if (p.ready) return { text: 'Ready to harvest', cls: 'good' };
    if (p.thirsty) return { text: 'Needs water', cls: 'bad' };
    if (p.water < 25) return { text: 'Thirsty', cls: 'warn' };
    return { text: 'Growing', cls: '' };
}

function renderPlant(p) {
    current = p;
    $('p-label').textContent = p.label;
    $('p-sub').textContent = p.dead ? 'Withered' : `Stage ${p.stage} / ${p.stages}`;

    const s = statusOf(p);
    const pill = $('p-status');
    pill.textContent = s.text;
    pill.className = `status-pill ${s.cls}`;

    setBar('growth', p.growth, p.growth >= 100 ? 'stat-good' : 'stat-warn');
    setBar('water', p.water, cls(p.water));
    setBar('fert', p.fertilizer, p.fertilizer > 0 ? cls(p.fertilizer) : 'stat-bad');
    setBar('health', p.health, cls(p.health));

    let note = '';
    if (p.dead) note = 'This crop has withered. Clear it to replant.';
    else if (p.ready) note = 'Fully grown and ready to be gathered.';
    else if (p.thirsty) note = 'Bone dry — it will not grow and is losing health.';
    else note = `Roughly ${p.remaining} minute${p.remaining === 1 ? '' : 's'} until harvest${p.fertilizer > 0 ? ' (fertilised)' : ''}.`;
    if (!p.isOwner) note += ' — Not your crop.';
    $('p-note').textContent = note;

    const btn = (a) => document.querySelector(`[data-act="${a}"]`);
    btn('water').disabled = p.dead || p.water >= 95;
    btn('fertilize').disabled = p.dead || p.fertilizer >= 95 || p.growth >= 100;
    btn('harvest').disabled = !p.ready || (p.ownerOnly && !p.isOwner);
    btn('destroy').disabled = !p.isOwner && !p.dead;
}

function renderList(plants) {
    lastList = plants;
    $('l-sub').textContent = `${plants.length} plant${plants.length === 1 ? '' : 's'}`;
    const list = $('list');
    list.innerHTML = '';
    if (!plants.length) {
        list.innerHTML = '<div class="empty">You have nothing in the ground.</div>';
        return;
    }
    plants.forEach((p) => {
        const s = statusOf(p);
        const row = document.createElement('div');
        row.className = 'row';
        row.innerHTML = `
            <div class="badge-icon">&#10048;</div>
            <div class="row-body">
                <div class="row-title">${p.label}</div>
                <div class="row-desc">${p.dead ? 'Withered' : `Stage ${p.stage}/${p.stages}`} · ${p.distance}m away</div>
                <div class="mini">
                    <div><label>Growth</label><div class="track small"><div class="fill ${p.growth >= 100 ? 'stat-good' : 'stat-warn'}" style="width:${p.growth}%"></div></div></div>
                    <div><label>Water</label><div class="track small"><div class="fill ${cls(p.water)}" style="width:${p.water}%"></div></div></div>
                    <div><label>Health</label><div class="track small"><div class="fill ${cls(p.health)}" style="width:${p.health}%"></div></div></div>
                </div>
            </div>
            <span class="pill ${s.cls}">${s.text}</span>`;
        row.addEventListener('click', () => { close(false); post('openPlant', { id: p.id }); });
        list.appendChild(row);
    });
}

function show(panel) {
    app.classList.remove('hidden');
    plantPanel.classList.toggle('hidden', panel !== 'plant');
    listPanel.classList.toggle('hidden', panel !== 'list');
}

function close(notify = true) {
    app.classList.add('hidden');
    plantPanel.classList.add('hidden');
    listPanel.classList.add('hidden');
    current = null;
    if (notify) post('close');
}

window.addEventListener('message', ({ data }) => {
    switch (data.action) {
        case 'open':   renderPlant(data.plant); show('plant'); break;
        case 'update': if (current && current.id === data.plant.id) renderPlant(data.plant); break;
        case 'list':   renderList(data.plants || []); show('list'); break;
        case 'close':  close(false); break;
    }
});

document.querySelectorAll('[data-act]').forEach((b) =>
    b.addEventListener('click', () => {
        if (!current || b.disabled) return;
        post('action', { action: b.dataset.act, id: current.id });
        close(false);
    })
);
document.querySelectorAll('.btn-close').forEach((b) => b.addEventListener('click', () => close()));
$('btn-list').addEventListener('click', () => post('showList'));
$('btn-back').addEventListener('click', () => close());
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' || e.key === 'Backspace') close(); });
