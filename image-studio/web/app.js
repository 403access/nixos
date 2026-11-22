const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const state = {
  kind: 'nixos',
  presets: null,
  jobs: [],
  bundles: [],
  token: localStorage.getItem('imageStudioToken') || '',
  logTimer: null,
  currentLog: null,
};

function toast(message, bad = false) {
  const node = $('#toast');
  node.textContent = message;
  node.classList.toggle('bad', bad);
  node.classList.remove('hidden');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => node.classList.add('hidden'), 5200);
}

function authHeaders(extra = {}) {
  return state.token ? { ...extra, Authorization: `Bearer ${state.token}` } : extra;
}

async function api(path, options = {}, retried = false) {
  const headers = authHeaders(options.headers || {});
  const response = await fetch(path, { ...options, headers });
  if (response.status === 401 && !retried) {
    const token = window.prompt('Image Studio token:');
    if (token) {
      state.token = token;
      localStorage.setItem('imageStudioToken', token);
      return api(path, options, true);
    }
  }
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = { error: text }; }
  if (!response.ok) throw new Error(body?.error || response.statusText);
  return body;
}

function field(form, name) {
  return form.elements.namedItem(name);
}

function setField(form, name, value) {
  const element = field(form, name);
  if (!element) return;
  if (element instanceof RadioNodeList) return;
  if (element.type === 'checkbox') element.checked = Boolean(value);
  else element.value = value ?? '';
}

function collect(kind) {
  const form = kind === 'nixos' ? $('#nixos-form') : $('#windows-form');
  const data = new FormData(form);
  const profile = {};
  for (const [key, value] of data.entries()) {
    if (key === 'removeComponents') {
      profile.removeComponents ||= [];
      profile.removeComponents.push(value);
    } else {
      profile[key] = value;
    }
  }
  profile.name = String(profile.name || (kind === 'nixos' ? 'nixos-image' : 'windows-image'));
  if (kind === 'nixos') {
    profile.packages = String(profile.packages || '').split(/[\s,]+/).filter(Boolean);
    for (const key of ['ssh', 'libvirt', 'bluetooth', 'ksm', 'passwordlessSudo']) profile[key] = data.has(key);
    profile.kind = 'nixos';
  } else {
    profile.themes = String(profile.themes || '').split(',').map((item) => item.trim()).filter(Boolean);
    profile.memoryGiB = Number(profile.memoryGiB || 4);
    profile.vcpus = Number(profile.vcpus || 2);
    for (const key of ['autologon', 'removeWinRE', 'solid']) profile[key] = data.has(key);
    profile.removeComponents ||= [];
    const recipes = {
      ai: 'disable-ai',
      search: 'disable-search',
      printer: 'printer-off',
      telemetry: 'disable-telemetry',
      store: 'remove-store',
      edge: 'remove-edge',
    };
    const post = new Set((profile.removeComponents || []).map((item) => recipes[item]).filter(Boolean));
    if ((profile.removeComponents || []).some((item) => ['onedrive', 'xbox'].includes(item))) post.add('trim-stock');
    profile.postInstall = [...post];
    profile.kind = 'windows';
    if (!profile.sourceIso) delete profile.sourceIso;
  }
  return profile;
}

function applyProfile(kind, profile) {
  const form = kind === 'nixos' ? $('#nixos-form') : $('#windows-form');
  if (!form) return;
  const normalizedKind = profile.kind || kind;
  if (normalizedKind !== state.kind) switchTab(normalizedKind);
  for (const [key, value] of Object.entries(profile)) {
    if (['kind', 'removeComponents', 'postInstall'].includes(key)) continue;
    if (Array.isArray(value)) {
      if (key === 'packages') setField(form, key, value.join(' '));
      else if (key === 'themes') setField(form, key, value.join(', '));
      continue;
    }
    setField(form, key, value);
  }
  if (Array.isArray(profile.removeComponents)) {
    for (const checkbox of $$('input[name="removeComponents"]', form)) {
      checkbox.checked = profile.removeComponents.includes(checkbox.value);
    }
  }
  $('#profile-json').value = JSON.stringify(profile, null, 2);
}

function switchTab(kind) {
  state.kind = kind;
  for (const tab of $$('.tab')) tab.classList.toggle('active', tab.dataset.kind === kind);
  $('#nixos-form').classList.toggle('hidden', kind !== 'nixos');
  $('#windows-form').classList.toggle('hidden', kind !== 'windows');
}

async function loadPresets() {
  const presets = await api('/api/profiles');
  state.presets = presets;
  const nixos = presets.nixos?.[0]?.profile;
  const windows = presets.windows?.[0]?.profile;
  if (nixos) applyProfile('nixos', nixos);
  if (windows) applyProfile('windows', windows);
  switchTab('nixos');
  $('#profile-json').value = JSON.stringify(presets.nixos?.[0]?.profile || {}, null, 2);
}

async function refreshHealth() {
  const pill = $('#mode');
  try {
    const health = await api('/api/health');
    pill.textContent = `${health.mode}${health.dryRun ? ' · dry-run' : ''} · v${health.version}`;
    pill.className = 'pill ok';
    pill.title = JSON.stringify(health.capabilities, null, 2);
  } catch (error) {
    pill.textContent = 'offline';
    pill.className = 'pill bad';
    throw error;
  }
}

function statusBadge(status) {
  const span = document.createElement('span');
  span.className = `badge ${status}`;
  span.textContent = status;
  return span;
}

function actionButton(label, handler, className = '') {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = label;
  if (className) button.className = className;
  button.addEventListener('click', handler);
  return button;
}

function renderJobs() {
  const host = $('#jobs');
  host.replaceChildren();
  $('#job-count').textContent = String(state.jobs.length);
  if (!state.jobs.length) {
    const empty = document.createElement('p');
    empty.className = 'muted';
    empty.textContent = 'No builds yet.';
    host.append(empty);
    return;
  }
  for (const job of state.jobs.slice(0, 20)) {
    const card = document.createElement('article');
    card.className = 'job';
    const head = document.createElement('div');
    head.className = 'job-head';
    const title = document.createElement('div');
    title.className = 'job-title';
    title.textContent = `${job.kind === 'nixos' ? 'NixOS' : 'Windows'} · ${job.meta?.profile?.name || job.kind}`;
    head.append(title, statusBadge(job.status));
    const meta = document.createElement('div');
    meta.className = 'job-meta';
    meta.textContent = `${new Date(job.createdAt).toLocaleString()} · ${job.preview || job.command || ''}`;
    const actions = document.createElement('div');
    actions.className = 'job-actions';
    actions.append(actionButton('Log', () => openLog(job.id)));
    if (job.status === 'running') actions.append(actionButton('Cancel', () => cancelJob(job.id)));
    if (job.status === 'succeeded') {
      actions.append(actionButton('Artifacts', () => showArtifacts(job.id)));
      actions.append(actionButton('Export', () => exportJob(job.id)));
    }
    card.append(head, meta, actions);
    const artifacts = document.createElement('div');
    artifacts.className = 'job-actions';
    artifacts.dataset.artifacts = job.id;
    card.append(artifacts);
    host.append(card);
  }
}

async function showArtifacts(id) {
  const target = document.querySelector(`[data-artifacts="${CSS.escape(id)}"]`);
  if (!target) return;
  target.replaceChildren();
  try {
    const data = await api(`/api/builds/${id}`);
    if (!data.artifacts?.length) {
      target.textContent = 'No artifact discovered yet.';
      return;
    }
    for (const artifact of data.artifacts) {
      const link = document.createElement('a');
      link.textContent = `${artifact.name} (${(artifact.size / 1024 / 1024).toFixed(1)} MiB)`;
      link.href = `/api/builds/${id}/artifacts/${encodeURIComponent(artifact.name)}${state.token ? `?token=${encodeURIComponent(state.token)}` : ''}`;
      target.append(link);
    }
  } catch (error) {
    target.textContent = error.message;
  }
}

async function refreshJobs() {
  const data = await api('/api/builds');
  state.jobs = data.jobs || [];
  renderJobs();
}

async function cancelJob(id) {
  try {
    await api(`/api/builds/${id}/cancel`, { method: 'POST' });
    toast('Job cancelled');
    await refreshJobs();
  } catch (error) {
    toast(error.message, true);
  }
}

async function exportJob(id) {
  try {
    const result = await api('/api/export', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jobId: id }),
    });
    toast(`Bundle ready: ${result.name}`);
    await refreshBundles();
    window.open(result.downloadUrl + (state.token ? `?token=${encodeURIComponent(state.token)}` : ''), '_blank');
  } catch (error) {
    toast(error.message, true);
  }
}

function openLog(id) {
  const dialog = $('#log-dialog');
  $('#log-title').textContent = `Job ${id}`;
  $('#log-output').textContent = 'Loading…';
  state.currentLog = id;
  if (!dialog.open) dialog.showModal();
  const tick = async () => {
    if (state.currentLog !== id) return;
    try {
      const data = await api(`/api/builds/${id}/log`);
      const pre = $('#log-output');
      const stick = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
      pre.textContent = data.text || '(no output)';
      if (stick) pre.scrollTop = pre.scrollHeight;
    } catch (error) {
      $('#log-output').textContent = error.message;
    }
  };
  tick();
  clearInterval(state.logTimer);
  state.logTimer = setInterval(tick, 1200);
  $('#log-close').onclick = () => {
    state.currentLog = null;
    clearInterval(state.logTimer);
    dialog.close();
  };
  dialog.onclose = () => {
    state.currentLog = null;
    clearInterval(state.logTimer);
  };
}

function renderBundles() {
  const host = $('#bundles');
  host.replaceChildren();
  if (!state.bundles.length) {
    const empty = document.createElement('p');
    empty.className = 'muted';
    empty.textContent = 'No bundles imported or exported yet.';
    host.append(empty);
    return;
  }
  for (const bundle of state.bundles.slice(0, 12)) {
    const card = document.createElement('article');
    card.className = 'bundle';
    const head = document.createElement('div');
    head.className = 'job-head';
    const title = document.createElement('div');
    title.className = 'job-title';
    title.textContent = `${bundle.manifest.kind === 'nixos' ? 'NixOS' : 'Windows'} · ${bundle.manifest.profile?.name || bundle.id}`;
    head.append(title, statusBadge(bundle.type));
    const meta = document.createElement('div');
    meta.className = 'job-meta';
    meta.textContent = `${new Date(bundle.manifest.createdAt).toLocaleString()} · ${bundle.manifest.artifacts?.length || 0} artifact(s)`;
    const actions = document.createElement('div');
    actions.className = 'job-actions';
    const link = document.createElement('a');
    link.href = `/api/bundles/${bundle.id}/download${state.token ? `?token=${encodeURIComponent(state.token)}` : ''}`;
    link.textContent = 'Download';
    actions.append(link);
    actions.append(actionButton('Use profile', () => {
      applyProfile(bundle.manifest.kind, bundle.manifest.profile);
      toast('Profile loaded into the builder');
    }));
    const iso = bundle.manifest.artifacts?.find((artifact) => artifact.name.toLowerCase().endsWith('.iso'));
    if (iso) {
      actions.append(actionButton('Use ISO', () => {
        switchTab('windows');
        setField($('#windows-form'), 'sourceIso', `${bundle.dir}/artifacts/${iso.name}`);
        toast('Imported ISO selected as the Windows source');
      }));
    }
    card.append(head, meta, actions);
    host.append(card);
  }
}

async function refreshBundles() {
  const data = await api('/api/bundles');
  state.bundles = data.bundles || [];
  renderBundles();
}

async function uploadIso(file) {
  const response = await fetch(`/api/uploads?name=${encodeURIComponent(file.name)}`, {
    method: 'POST',
    headers: authHeaders({ 'content-type': 'application/octet-stream' }),
    body: file,
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || 'upload failed');
  return body;
}

async function submit(kind, event) {
  event.preventDefault();
  const form = event.currentTarget;
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    const profile = collect(kind);
    if (kind === 'windows') {
      const file = $('#iso-file').files?.[0];
      if (file) {
        toast(`Uploading ${file.name}…`);
        const uploaded = await uploadIso(file);
        profile.sourceIso = uploaded.path;
        setField(form, 'sourceIso', uploaded.path);
      }
    }
    const result = await api('/api/builds', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ kind, profile }),
    });
    toast(`Build started: ${result.job.id}`);
    await refreshJobs();
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

async function validate(kind) {
  try {
    const profile = collect(kind);
    const normalized = await api('/api/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ kind, profile }),
    });
    $('#profile-json').value = JSON.stringify(normalized, null, 2);
    toast('Profile is valid');
  } catch (error) {
    toast(error.message, true);
  }
}

async function importFile(file) {
  try {
    toast(`Importing ${file.name}…`);
    const response = await fetch('/api/import', {
      method: 'POST',
      headers: authHeaders({ 'content-type': 'application/gzip', 'x-filename': file.name }),
      body: file,
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error || 'import failed');
    toast(`Imported ${body.manifest?.name || body.id}`);
    await refreshBundles();
  } catch (error) {
    toast(error.message, true);
  }
}

function bind() {
  for (const tab of $$('.tab')) tab.addEventListener('click', () => switchTab(tab.dataset.kind));
  $('#nixos-form').addEventListener('submit', (event) => submit('nixos', event));
  $('#windows-form').addEventListener('submit', (event) => submit('windows', event));
  for (const button of $$('[data-validate]')) {
    button.addEventListener('click', () => validate(button.dataset.validate));
  }
  for (const button of $$('[data-reset]')) {
    button.addEventListener('click', () => {
      const kind = button.dataset.reset;
      const preset = state.presets?.[kind]?.[0]?.profile;
      if (preset) applyProfile(kind, preset);
    });
  }
  $('#refresh').addEventListener('click', () => {
    refreshJobs().then(refreshBundles).then(refreshHealth).then(() => toast('Refreshed')).catch((error) => toast(error.message, true));
  });
  $('#json-fill').addEventListener('click', () => {
    try {
      const profile = JSON.parse($('#profile-json').value);
      applyProfile(profile.kind || state.kind, profile);
      toast('Form filled from JSON');
    } catch (error) {
      toast(error.message, true);
    }
  });
  $('#json-save').addEventListener('click', () => {
    try {
      const profile = JSON.parse($('#profile-json').value);
      const blob = new Blob([JSON.stringify(profile, null, 2)], { type: 'application/json' });
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = `${profile.name || 'image-profile'}.json`;
      link.click();
      URL.revokeObjectURL(link.href);
    } catch (error) {
      toast(error.message, true);
    }
  });
  $('#bundle-file').addEventListener('change', (event) => {
    const file = event.target.files?.[0];
    if (file) importFile(file);
  });
  const drop = $('#drop');
  drop.addEventListener('dragover', (event) => { event.preventDefault(); drop.classList.add('active'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('active'));
  drop.addEventListener('drop', (event) => {
    event.preventDefault();
    drop.classList.remove('active');
    const file = event.dataTransfer?.files?.[0];
    if (file) importFile(file);
  });
}

async function boot() {
  bind();
  try {
    await refreshHealth();
    await loadPresets();
    await refreshJobs();
    await refreshBundles();
    setInterval(() => {
      refreshJobs().catch(() => {});
      refreshBundles().catch(() => {});
    }, 3500);
  } catch (error) {
    toast(error.message, true);
  }
}

boot();