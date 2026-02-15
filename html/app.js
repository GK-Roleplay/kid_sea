const app = document.getElementById('app');
const tabletTitle = document.getElementById('tabletTitle');
const closeBtn = document.getElementById('closeBtn');
const levelLabel = document.getElementById('levelLabel');
const xpLabel = document.getElementById('xpLabel');
const xpFill = document.getElementById('xpFill');
const bonusLabel = document.getElementById('bonusLabel');
const dailyLabel = document.getElementById('dailyLabel');
const resetLabel = document.getElementById('resetLabel');
const walletLabel = document.getElementById('walletLabel');
const objectiveText = document.getElementById('objectiveText');
const questSteps = document.getElementById('questSteps');
const fishList = document.getElementById('fishList');
const holdLabel = document.getElementById('holdLabel');
const holdFill = document.getElementById('holdFill');
const runsLabel = document.getElementById('runsLabel');
const earnedLabel = document.getElementById('earnedLabel');
const selectedBoatText = document.getElementById('selectedBoatText');
const boatList = document.getElementById('boatList');
const stagePill = document.getElementById('stagePill');
const routePill = document.getElementById('routePill');
const waypointBtn = document.getElementById('waypointBtn');
const startRunBtn = document.getElementById('startRunBtn');
const deployBtn = document.getElementById('deployBtn');
const reelBtn = document.getElementById('reelBtn');
const sellBtn = document.getElementById('sellBtn');
const spawnBoatBtn = document.getElementById('spawnBoatBtn');
const nextActionBtn = document.getElementById('nextActionBtn');
const nextActionHint = document.getElementById('nextActionHint');
const receiptModal = document.getElementById('receiptModal');
const receiptList = document.getElementById('receiptList');
const receiptTotal = document.getElementById('receiptTotal');
const receiptClose = document.getElementById('receiptClose');
const toastStack = document.getElementById('toastStack');
const progressOverlay = document.getElementById('progressOverlay');
const progressLabel = document.getElementById('progressLabel');
const progressFill = document.getElementById('progressFill');
const tabs = Array.from(document.querySelectorAll('.tab-btn'));
const tabContents = Array.from(document.querySelectorAll('.tab-content'));

const uiState = { visible: false, activeTab: 'run', state: null, manualTabSelection: false };
let nextActionRunner = null;

function nui(action, payload) {
    payload = payload || {};
    return fetch('https://' + GetParentResourceName() + '/' + action, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(payload)
    }).catch(() => null);
}

function formatCash(v) { return '$' + (Number(v) || 0).toLocaleString(); }
function formatGrams(v) { return Math.max(0, Math.floor(Number(v) || 0)).toLocaleString() + 'g'; }

function stageToLabel(stage) {
    const map = {
        job_off: 'Job Off',
        go_harbor: 'Go Harbor',
        deploy_line: 'Deploy',
        reel_line: 'Reel',
        return_sell: 'Sell',
        daily_complete: 'Daily Limit'
    };
    return map[stage] || stage || '-';
}

function setTab(tabKey, byUser) {
    byUser = !!byUser;
    uiState.activeTab = tabKey;
    if (byUser) uiState.manualTabSelection = true;
    tabs.forEach((btn) => btn.classList.toggle('active', btn.dataset.tab === tabKey));
    tabContents.forEach((content) => content.classList.toggle('hidden', content.dataset.content !== tabKey));
}

function pushToast(type, text) {
    const toast = document.createElement('div');
    toast.className = 'toast ' + (type || 'success');
    toast.textContent = text || 'Sea update';
    toastStack.appendChild(toast);
    setTimeout(() => toast.remove(), 3200);
}

function renderState(state) {
    if (!state) return;

    levelLabel.textContent = 'Level ' + (state.level || 1);
    xpLabel.textContent = (state.xp || 0) + ' XP';
    xpFill.style.width = Math.max(0, Math.min(100, Number(state.levelProgressPct) || 0)) + '%';
    bonusLabel.textContent = 'Level bonus: +' + (state.levelBonusPct || 0) + '%';

    dailyLabel.textContent = (state.daily?.runs || 0) + ' / ' + (state.daily?.maxRuns || 0);
    resetLabel.textContent = 'Reset date: ' + (state.daily?.lastResetDate || '-');
    walletLabel.textContent = formatCash(state.wallet || 0);

    objectiveText.textContent = state.objective?.text || 'Follow your objective.';
    stagePill.textContent = 'Stage: ' + stageToLabel(state.stage);
    routePill.textContent = 'Route: ' + (state.routeTarget || state.objective?.zone || '-');

    holdLabel.textContent = formatGrams(state.holdUsedGrams) + ' / ' + formatGrams(state.holdCapacityGrams);
    holdFill.style.width = Math.max(0, Math.min(100, Number(state.holdPct) || 0)) + '%';

    runsLabel.textContent = 'Runs complete: ' + (state.stats?.runsCompleted || 0);
    earnedLabel.textContent = 'Total earned: ' + formatCash(state.stats?.totalEarned || 0);

    questSteps.innerHTML = '';
    (state.questSteps || []).forEach((step) => {
        const li = document.createElement('li');
        if (step.done) li.classList.add('done');
        const dot = document.createElement('span');
        dot.className = 'step-dot';
        const label = document.createElement('span');
        label.textContent = step.label || step.key;
        li.append(dot, label);
        questSteps.appendChild(li);
    });

    fishList.innerHTML = '';
    const fishRows = state.fishHold || [];
    if (fishRows.length === 0) {
        fishList.innerHTML = '<div class="recipe-row"><span>No fish in hold</span></div>';
    } else {
        fishRows.forEach((item) => {
            const row = document.createElement('div');
            row.className = 'recipe-row';
            const rareTag = item.rare ? ' (Rare)' : '';
            row.innerHTML = '<div><strong>' + item.label + rareTag + '</strong><div class="recipe-meta">' + formatGrams(item.grams) + ' @ $' + Number(item.pricePerGram || 0).toFixed(2) + '/g</div></div><strong>' + formatCash(item.estValue) + '</strong>';
            fishList.appendChild(row);
        });
    }

    selectedBoatText.textContent = 'Selected boat: ' + (state.selectedBoat?.label || '-') + ' (' + (state.selectedBoat?.model || '-') + ')';
    boatList.innerHTML = '';
    (state.unlockedBoats || []).forEach((boat) => {
        const row = document.createElement('div');
        row.className = 'recipe-row';
        const isSelected = Number(state.selectedBoatLevel) === Number(boat.level);
        const status = boat.unlocked ? 'UNLOCKED' : 'LOCKED L' + boat.level;
        row.innerHTML = '<div><strong>L' + boat.level + ' ' + boat.label + '</strong><div class="recipe-meta">' + boat.model + ' | Hold ' + formatGrams(boat.holdCapacityGrams) + ' | +' + boat.payoutBonusPct + '% | ' + status + '</div></div>';

        const btn = document.createElement('button');
        btn.className = 'primary-btn';
        btn.textContent = isSelected ? 'Selected' : 'Select';
        btn.disabled = isSelected || !boat.unlocked;
        btn.addEventListener('click', () => nui('selectBoat', { level: boat.level, model: boat.model }));
        row.appendChild(btn);
        boatList.appendChild(row);
    });

    startRunBtn.disabled = state.stage !== 'go_harbor';
    deployBtn.disabled = state.stage !== 'deploy_line';
    reelBtn.disabled = state.stage !== 'reel_line';
    sellBtn.disabled = state.stage !== 'return_sell';
    spawnBoatBtn.disabled = !state.selectedBoat;

    waypointBtn.textContent = 'Waypoint: ' + (state.preferences?.waypoint ? 'ON' : 'OFF');

    nextActionRunner = null;
    if (state.stage === 'go_harbor') {
        nextActionBtn.textContent = 'Start Sea Run';
        nextActionHint.textContent = 'Go to Harbor and start your run.';
        nextActionRunner = () => nui('startRun');
        nextActionBtn.disabled = false;
    } else if (state.stage === 'deploy_line') {
        nextActionBtn.textContent = 'Deploy Line';
        nextActionHint.textContent = 'Go to the line marker and deploy.';
        nextActionRunner = () => nui('deployLine');
        nextActionBtn.disabled = false;
    } else if (state.stage === 'reel_line') {
        nextActionBtn.textContent = 'Reel Line';
        nextActionHint.textContent = 'Reel when timer is ready.';
        nextActionRunner = () => nui('reelLine');
        nextActionBtn.disabled = false;
    } else if (state.stage === 'return_sell') {
        nextActionBtn.textContent = 'Sell Catch';
        nextActionHint.textContent = 'Go to market and sell.';
        nextActionRunner = () => nui('sellCatch');
        nextActionBtn.disabled = false;
    } else {
        nextActionBtn.textContent = 'Continue';
        nextActionHint.textContent = state.objective?.text || 'Follow objective.';
        nextActionBtn.disabled = true;
    }

    if (!uiState.manualTabSelection) {
        if (state.stage === 'return_sell') setTab('market');
        else if (state.stage === 'go_harbor' && !state.activeRun) setTab('boats');
        else setTab('run');
    }
}

function showProgress(show, label, percent) {
    progressOverlay.classList.toggle('hidden', !show);
    if (!show) return;
    progressLabel.textContent = label || 'Working...';
    progressFill.style.width = Math.max(0, Math.min(100, Number(percent) || 0)) + '%';
}

function showReceipt(receipt) {
    receiptList.innerHTML = '';
    const lines = [
        'Fish sold: ' + formatGrams(receipt.soldGrams || 0),
        'Subtotal: ' + formatCash(receipt.subtotal || 0),
        'Boat bonus: +' + (receipt.boatBonusPct || 0) + '%',
        'Level bonus: +' + (receipt.levelBonusPct || 0) + '%',
        'XP gained: +' + (receipt.xpGained || 0),
        'Huge rare catches: ' + (receipt.hugeRareCount || 0)
    ];

    lines.forEach((line) => {
        const li = document.createElement('li');
        li.textContent = line;
        receiptList.appendChild(li);
    });

    receiptTotal.textContent = 'Total payout: ' + formatCash(receipt.totalPayout || 0);
    receiptModal.classList.remove('hidden');
}

window.addEventListener('message', (event) => {
    const payload = event.data || {};
    if (payload.action === 'open') {
        app.classList.remove('hidden');
        uiState.visible = true;
        uiState.manualTabSelection = false;
        tabletTitle.textContent = payload.title || 'Sea Explorer Tablet';
        setTab(payload.tab || uiState.activeTab);
        return;
    }
    if (payload.action === 'close') {
        uiState.visible = false;
        app.classList.add('hidden');
        showProgress(false);
        return;
    }
    if (payload.action === 'sync') {
        uiState.state = payload.state || null;
        renderState(uiState.state);
        return;
    }
    if (payload.action === 'toast') { pushToast(payload.toast?.type, payload.toast?.text); return; }
    if (payload.action === 'receipt') { showReceipt(payload.receipt || {}); return; }
    if (payload.action === 'levelUp') {
        levelLabel.classList.add('level-pop');
        pushToast('success', 'Level up! You are now level ' + (payload.data?.level || '?') + '.');
        setTimeout(() => levelLabel.classList.remove('level-pop'), 700);
        return;
    }
    if (payload.action === 'progress') {
        showProgress(payload.show, payload.label, payload.percent);
        return;
    }
});

closeBtn.addEventListener('click', () => nui('close'));
receiptClose.addEventListener('click', () => receiptModal.classList.add('hidden'));
waypointBtn.addEventListener('click', () => {
    const current = !!uiState.state?.preferences?.waypoint;
    nui('setWaypoint', { enabled: !current });
});

startRunBtn.addEventListener('click', () => nui('startRun'));
deployBtn.addEventListener('click', () => nui('deployLine'));
reelBtn.addEventListener('click', () => nui('reelLine'));
sellBtn.addEventListener('click', () => nui('sellCatch'));
spawnBoatBtn.addEventListener('click', () => nui('spawnBoat'));

nextActionBtn.addEventListener('click', () => {
    if (typeof nextActionRunner === 'function') nextActionRunner();
});

tabs.forEach((tabButton) => {
    tabButton.addEventListener('click', () => setTab(tabButton.dataset.tab, true));
});

document.addEventListener('keydown', (event) => {
    if (!uiState.visible) return;
    const tagName = (event.target && event.target.tagName) ? event.target.tagName.toLowerCase() : '';
    const typing = tagName === 'input' || tagName === 'textarea' || tagName === 'select';

    if (event.key === 'Escape') { nui('close'); return; }
    if (typing) return;

    if (event.key === '1') setTab('run', true);
    if (event.key === '2') setTab('boats', true);
    if (event.key === '3') setTab('market', true);
    if (event.key === 'Enter' && typeof nextActionRunner === 'function') nextActionRunner();
});

nui('requestSync');
