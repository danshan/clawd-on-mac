const ICONS = {
  'claude-code':'<path d="M10 2C5.6 2 2 5.6 2 10s3.6 8 8 8 8-3.6 8-8-3.6-8-8-8zm0 2.5a2 2 0 110 4 2 2 0 010-4zM6.5 10.5a1 1 0 110 2 1 1 0 010-2zm7 0a1 1 0 110 2 1 1 0 010-2zM7 14.2c.8.8 1.8 1.3 3 1.3s2.2-.5 3-1.3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
  'gemini-cli':'<path d="M10 2l2.2 5.5L18 10l-5.8 2.5L10 18l-2.2-5.5L2 10l5.8-2.5z"/>',
  'codex-cli':'<rect x="2" y="4" width="16" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.5 9l2.5 2-2.5 2M10.5 13h3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
  'opencode':'<circle cx="10" cy="10" r="7.5" fill="none" stroke="currentColor" stroke-width="1.5"/><ellipse cx="10" cy="10" rx="3" ry="7.5" fill="none" stroke="currentColor" stroke-width="1.2"/><line x1="2.5" y1="10" x2="17.5" y2="10" stroke="currentColor" stroke-width="1.2"/>',
  'copilot-cli':'<path d="M10 3C6.5 3 4 5.2 4 8c0 1.5.7 2.8 1.8 3.7L5 16h10l-.8-4.3C15.3 10.8 16 9.5 16 8c0-2.8-2.5-5-6-5z" fill="none" stroke="currentColor" stroke-width="1.5"/><circle cx="7.5" cy="8.5" r="1.2"/><circle cx="12.5" cy="8.5" r="1.2"/>',
  'cursor':'<path d="M5 2l10 8-4.5 1L14 17l-2.5 1-3.5-6L4 14z"/>',
  'kiro':'<path d="M11 2L7 10h4l-2 8 6-9h-4z"/>',
  '_default':'<path d="M11.5 2.1L10.4 5.8 7.7 3.6 8.4 7.4 4.6 7.1 7.6 9.4 4 11l3.8.5-2.2 2.8 3.4-1.3.3 3.7 1.8-3.2 2.7 2.5-.8-3.6 3.6.7-2.8-2.3L18 9.4l-3.7-.5 1.5-3.2-3.2 1.6z" fill="none" stroke="currentColor" stroke-width="1.3"/>'
};
const COLORS = {
  'claude-code':'#e07850','gemini-cli':'#4285f4','codex-cli':'#10a37f',
  'opencode':'#a78bfa','copilot-cli':'#79c0ff','cursor':'#19c8ff','kiro':'#f59e0b'
};

let toolsCache = [];
const HOME_RE = /^\/Users\/[^\/]+/;
const esc = s => { if (!s) return ''; const d = document.createElement('div'); d.textContent = s; return d.innerHTML; };
const shortPath = p => p ? p.replace(HOME_RE, '~') : '';
const svg = (id, cls) => {
  const builtinPng = ['claude-code','codex-cli','copilot-cli','cursor','droid','kimi','kiro','opencode','pi','qoder'];
  if (builtinPng.includes(id) || id.includes('_')) {
    // Built-in PNGs or custom tools (underscore keys)
    const imgId = id.replace(/_/g, '-');
    return `<img src="/icons/${imgId}.png" alt="" width="20" height="20" style="border-radius:4px" class="${cls||''}" onerror="this.outerHTML=svgFallback('${id}','${cls||''}')">`;
  }
  return svgFallback(id, cls);
};
const svgFallback = (id, cls) => `<svg viewBox="0 0 20 20" fill="currentColor" style="color:${COLORS[id]||'#888'}" class="${cls||''}">${ICONS[id]||ICONS._default}</svg>`;

function toast(msg, type) {
  const old = document.querySelectorAll('.toast');
  old.forEach(t => t.remove());
  const el = document.createElement('div');
  el.className = 'toast' + (type ? ' ' + type : '');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .3s'; setTimeout(() => el.remove(), 300); }, 3000);
}

function pickFolder(inputId) {
  fetch('/api/pick-folder', {method:'POST'}).then(r=>r.json()).then(data => {
    if (data.cancelled || !data.path) return;
    const el = document.getElementById(inputId);
    if (el) el.value = data.path;
  });
}

function summarize(t) {
  const parts = [];
  const d = t.details || {};
  if (d.hooks) parts.push(d.hooks);
  if (t.plugins && t.plugins.length) parts.push(t.plugins.length + ' plugin' + (t.plugins.length > 1 ? 's' : ''));
  if (t.authType) parts.push(t.authType);
  if (d.experimental) parts.push('experimental');
  return parts.join(' \u00b7 ');
}

function navigate() {
  const hash = location.hash || '#/';
  // Clean up batch panel when navigating away from skills list
  if (hash !== '#/skills') {
    window._selectMode = false;
    window._selectedSkills = {};
  }
  updateSidebar(hash);
  const m = hash.match(/^#\/tool\/(.+)$/);
  const sm = hash.match(/^#\/skills\/(.+)$/);
  if (m) { window._selectedToolId = m[1]; renderList(); }
  else if (hash === '#/settings') { renderSettings(); }
  else if (hash === '#/skills') { renderSkillsList(); }
  else if (hash === '#/skills-marketplace') { renderSkillsMarketplace(); }
  else if (hash === '#/skills-discover') { window._installTab='discover'; renderSkillsMarketplace(); }
  else if (hash === '#/skills-tools') { renderToolsConfig(); }
  else if (hash === '#/skills-scenarios') { renderScenarios(); }
  else if (hash.startsWith('#/skills-scenario/')) { location.hash = '#/skills-scenarios'; }
  else if (hash === '#/skills-backup') { location.hash = '#/settings'; }
  else if (hash === '#/skills-projects') { renderProjects(); }
  else if (hash.startsWith('#/skills-project/')) { renderProjectDetail(hash.split('/').pop()); }
  else if (sm) { renderSkillDetail(sm[1]); }
  else { renderList(); }
}

const SI = {
  tools: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1.5" y="1.5" width="13" height="13" rx="2"/><path d="M1.5 5.5h13"/><circle cx="4.5" cy="3.5" r=".7" fill="currentColor" stroke="none"/><circle cx="7" cy="3.5" r=".7" fill="currentColor" stroke="none"/></svg>',
  skills: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M8 1v4M4.5 2.5L6 5.5M11.5 2.5L10 5.5"/><rect x="3" y="5" width="10" height="8" rx="1.5"/><path d="M6 9h4"/></svg>',
  market: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="6.5"/><path d="M2 8h12M8 1.5c-2 2-2 5 0 6.5s2 4.5 0 6.5M8 1.5c2 2 2 5 0 6.5s-2 4.5 0 6.5"/></svg>',
  discover: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="7" cy="7" r="5.5"/><path d="M11 11l3.5 3.5" stroke-linecap="round"/></svg>',
  scenario: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 4h5v4H2zM9 4h5v4H9zM5.5 12h5v3h-5z"/><path d="M4.5 8v2h7V8M8 10v2"/></svg>',
  toolcfg: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M6.5 1.5v2.3A5 5 0 003.8 6.5H1.5v3h2.3a5 5 0 002.7 2.7v2.3h3v-2.3a5 5 0 002.7-2.7h2.3v-3h-2.3A5 5 0 009.5 3.8V1.5z"/><circle cx="8" cy="8" r="2"/></svg>',
  backup: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 10V5a2 2 0 012-2h6a2 2 0 012 2v5"/><path d="M1.5 10h13v2.5a1.5 1.5 0 01-1.5 1.5H3a1.5 1.5 0 01-1.5-1.5z"/><circle cx="11.5" cy="12" r=".8" fill="currentColor" stroke="none"/></svg>',
  project: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 3.5A1.5 1.5 0 013.5 2H6l1.5 2h5A1.5 1.5 0 0114 5.5v7a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 012 12.5z"/></svg>',
  settings: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="2.5"/><path d="M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.5 1.5M11.5 11.5L13 13M13 3l-1.5 1.5M4.5 11.5L3 13"/></svg>',
  refresh: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M2.5 8a5.5 5.5 0 019.5-3.5M13.5 8a5.5 5.5 0 01-9.5 3.5"/><path d="M12 1v3.5h-3.5M4 15v-3.5h3.5"/></svg>',
  select: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><path d="M10 11.5l1.5 1.5 3-3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  upload: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M8 10V3M5 5.5L8 3l3 2.5"/><path d="M2 11v2.5h12V11"/></svg>',
  plus: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>',
  folder: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M2 4.5V12a1 1 0 001 1h10a1 1 0 001-1V6a1 1 0 00-1-1H8L6.5 3.5H3A1 1 0 002 4.5z"/></svg>',
  logo: '<svg viewBox="0 0 20 14" shape-rendering="crispEdges"><path fill="currentColor" opacity=".35" d="M7 1h6v1h-6z M5 2h2v1h-2z M13 2h2v1h-2z M4 3h1v1h-1z M15 3h1v1h-1z M3 4h1v1h-1z M16 4h1v1h-1z M3 5h1v1h-1z M16 5h1v1h-1z M3 6h1v1h-1z M16 6h1v1h-1z M4 7h1v1h-1z M15 7h1v1h-1z M2 8h3v1h-3z M15 8h3v1h-3z M1 9h1v1h-1z M4 9h1v1h-1z M7 9h6v1h-6z M15 9h1v1h-1z M18 9h1v1h-1z M1 10h1v1h-1z M4 10h1v1h-1z M6 10h1v1h-1z M13 10h1v1h-1z M15 10h1v1h-1z M18 10h1v1h-1z M1 11h1v1h-1z M4 11h1v1h-1z M6 11h1v1h-1z M13 11h1v1h-1z M15 11h1v1h-1z M18 11h1v1h-1z M2 12h2v1h-2z M5 12h2v1h-2z M13 12h2v1h-2z M16 12h2v1h-2z"/><path fill="#60a5fa" d="M7 2h6v1h-6z M5 3h10v1h-10z M4 4h12v1h-12z M4 5h2v1h-2z M14 5h2v1h-2z M4 6h2v1h-2z M14 6h2v1h-2z M2 9h2v1h-2z M16 9h2v1h-2z M2 10h2v1h-2z M16 10h2v1h-2z"/><path fill="#3b82f6" d="M8 5h2v1h-2z M12 5h2v1h-2z M8 6h2v1h-2z M12 6h2v1h-2z M5 7h10v1h-10z M5 8h10v1h-10z M5 9h2v1h-2z M13 9h2v1h-2z M5 10h1v1h-1z M14 10h1v1h-1z M2 11h2v1h-2z M5 11h1v1h-1z M14 11h1v1h-1z M16 11h2v1h-2z"/><path fill="#ffffff" d="M6 5h2v1h-2z M10 5h2v1h-2z M6 6h1v1h-1z M10 6h1v1h-1z"/><path fill="#0f172a" d="M7 6h1v1h-1z M11 6h1v1h-1z"/></svg>',
};

function updateSidebar(hash) {
  const isActive = p => {
    if (p === '#/' && (hash === '#/' || hash.startsWith('#/tool/'))) return true;
    if (p === '#/skills' && (hash === '#/skills' || hash.match(/^#\/skills\/[^-]/))) return true;
    if (p !== '#/' && p !== '#/skills' && hash.startsWith(p)) return true;
    return false;
  };
  const item = (href, icon, label) =>
    `<a class="sidebar-item${isActive(href) ? ' active' : ''}" href="${href}">${icon}<span>${label}</span></a>`;

  document.getElementById('sidebar').innerHTML = `
    <div class="sidebar-brand"><span style="width:24px;height:17px;display:inline-flex">${SI.logo}</span> Clawd</div>
    <div class="sidebar-group">
      <div class="sidebar-label">Skills</div>
      ${item('#/', SI.tools, 'Dashboard')}
      ${item('#/skills', SI.skills, 'My Skills')}
      ${item('#/skills-marketplace', SI.market, 'Install Skills')}
      ${item('#/skills-scenarios', SI.scenario, 'Scenarios')}
      ${item('#/skills-projects', SI.project, 'Projects')}
    </div>
    <div class="sidebar-group">
      <div class="sidebar-label">Settings</div>
      ${item('#/skills-tools', SI.toolcfg, 'Coding Tools')}
      ${item('#/settings', SI.settings, 'Preferences')}
    </div>
    <div class="sidebar-footer">
      <button onclick="loadData(true)" title="Refresh">${SI.refresh}</button>
      <button onclick="toggleTheme()" id="theme-btn" title="Toggle theme">${document.documentElement.classList.contains('light') ? '\u{2600}' : '\u{263E}'}</button>
      <time id="ts" style="font-family:var(--mono);font-size:.68rem;color:var(--text3)"></time>
    </div>
  `;
}

function renderList() {
  const app = document.getElementById('app');
  if (!toolsCache.length) { loadData(); return; }
  const ts = document.getElementById('ts');
  if (ts && !ts.textContent) ts.textContent = new Date().toLocaleTimeString();

  // Fetch enabled status to annotate tools
  fetch('/api/skills/tools').then(r=>r.json()).then(skillTools => {
    window._enabledTools = {};
    skillTools.forEach(st => { window._enabledTools[st.key] = st.enabled !== false; });
    renderListInner();
  }).catch(() => renderListInner());
}

function renderListInner() {
  const app = document.getElementById('app');
  const enabled = window._enabledTools || {};
  const visibleTools = Object.keys(enabled).length
    ? toolsCache.filter(t => enabled[t.id] !== false)
    : toolsCache;
  window._visibleTools = visibleTools;

  let h = '<div class="split-view">';

  // Left: list panel
  h += '<div class="list-panel">';
  h += `<div class="list-toolbar">
    <input id="tool-search" type="text" placeholder="Search tools..." oninput="filterToolsList()">
    <button class="tb-btn" onclick="loadData(true)" title="Refresh">${SI.refresh}</button>
  </div>`;
  h += '<div class="list-scroll" id="tools-list">';
  h += renderToolRows(visibleTools);
  h += '</div></div>';

  // Right: detail panel
  h += '<div class="detail-panel" id="tool-detail">';
  if (visibleTools.length) {
    h += '<div class="empty" style="padding:60px 20px;color:var(--text3)">Select a tool to view details</div>';
  } else {
    h += '<div class="empty" style="padding:60px 20px">No tools detected.<br>Install a coding tool to get started.</div>';
  }
  h += '</div></div>';
  app.innerHTML = h;

  // Auto-select tool
  if (visibleTools.length) {
    const prevId = window._selectedToolId;
    const target = prevId && visibleTools.find(t => t.id === prevId) ? prevId : visibleTools[0].id;
    selectToolRow(target);
  }
}

function renderToolRows(tools) {
  if (!tools.length) return '<div class="empty" style="padding:30px">No tools match</div>';
  let h = '';
  tools.forEach(t => {
    const skillCount = (t.skills||[]).length;
    const active = window._selectedToolId === t.id ? ' active' : '';
    h += `<div class="list-row${active}" data-tool-id="${esc(t.id)}" onclick="selectToolRow('${esc(t.id)}')">`;
    h += `<div class="row-icon">${svg(t.id)}</div>`;
    h += `<span class="row-name" style="flex:1;min-width:0">${esc(t.name)}</span>`;
    if (skillCount) h += `<span class="row-extra" style="margin-left:8px;white-space:nowrap">${skillCount} skills</span>`;
    if (t.hookIntegrated) h += `<span class="tag-badge" style="font-size:10px;padding:1px 6px;margin-left:6px">hooked</span>`;
    h += '</div>';
  });
  return h;
}

function selectToolRow(id) {
  window._selectedToolId = id;
  // Update active state in list
  document.querySelectorAll('#tools-list .list-row').forEach(r => {
    r.classList.toggle('active', r.dataset.toolId === id);
  });
  // Render detail panel
  const panel = document.getElementById('tool-detail');
  const t = (window._visibleTools || toolsCache).find(x => x.id === id);
  if (!panel || !t) return;
  panel.innerHTML = renderToolDetailPanel(t);
}

function filterToolsList() {
  const q = (document.getElementById('tool-search')?.value || '').toLowerCase();
  const tools = window._visibleTools || toolsCache;
  const filtered = q ? tools.filter(t => t.name.toLowerCase().includes(q) || t.id.toLowerCase().includes(q)) : tools;
  const container = document.getElementById('tools-list');
  if (container) container.innerHTML = renderToolRows(filtered);
}

function renderToolDetailPanel(t) {
  let h = `<div style="position:relative">`;
  h += `<div class="detail-hdr" style="margin-bottom:20px">
    <div class="detail-icon">${svg(t.id)}</div>
    <div>
      <h1 style="font-size:1.3rem;font-weight:700">${esc(t.name)}</h1>
      ${t.version ? `<span class="ver" style="margin-top:6px;display:inline-block">v${esc(t.version)}</span>` : ''}
      <span class="status-badge ${t.hookIntegrated ? 'status-on' : 'status-off'}" style="margin-left:8px">${t.hookIntegrated ? '\u{2713} HOOKED' : 'NO HOOK'}</span>
    </div>
  </div>`;

  // Configuration section
  const cfgRows = kv('Model', t.modelName) + kv('API Endpoint', t.apiEndpoint)
    + kv('Auth', t.authType) + kv('Reasoning', t.reasoningLevel) + kv('Subscription', t.subscription);
  if (cfgRows) h += `<section class="section"><h3>Configuration</h3>${cfgRows}</section>`;

  // Quota section
  const qk = Object.keys(t.quota || {});
  if (qk.length) {
    h += '<section class="section"><h3>Account / Quota</h3>';
    qk.forEach(k => {
      const label = k.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
      h += kv(label, t.quota[k]);
    });
    h += '</section>';
  }

  // Integration section
  const hookHtml = `<div class="kv"><span class="kv-k">Hook Status</span><span class="hook-status ${t.hookIntegrated ? 'on' : 'off'}">${t.hookIntegrated ? '\u{2713} Integrated' : '\u{00D7} Not integrated'}</span></div>`;
  const cfgPath = t.configPath ? kv('Config Path', shortPath(t.configPath), true) : '';
  h += `<section class="section"><h3>Integration</h3>${hookHtml}${cfgPath}</section>`;

  // Plugins section
  if (t.plugins && t.plugins.length) {
    h += `<section class="section"><h3>Plugins (${t.plugins.length})</h3><div class="pills">`;
    t.plugins.forEach(p => { h += `<span class="pill">${esc(p)}</span>`; });
    h += '</div></section>';
  }

  // MCP Servers section
  if (t.mcpServers && t.mcpServers.length) {
    h += `<section class="section"><h3>MCP Servers (${t.mcpServers.length})</h3><div class="pills">`;
    t.mcpServers.forEach(s => { h += `<span class="pill">${esc(s)}</span>`; });
    h += '</div></section>';
  }

  // Skills section
  if (t.skills && t.skills.length) {
    h += `<section class="section"><h3>Skills (${t.skills.length})</h3>`;
    if (t.skillDetails && t.skillDetails.length) {
      h += '<div class="skill-list">';
      t.skillDetails.forEach(s => {
        h += `<div class="skill-item"><span class="skill-name">${esc(s.name)}</span>`;
        if (s.description) h += `<span class="skill-desc">${esc(s.description)}</span>`;
        h += '</div>';
      });
      h += '</div>';
    } else {
      h += '<div class="pills">';
      t.skills.forEach(s => { h += `<span class="pill">${esc(s)}</span>`; });
      h += '</div>';
    }
    h += '</section>';
  }

  // Details section
  const dk = Object.keys(t.details || {});
  if (dk.length) {
    h += '<section class="section"><h3>Details</h3>';
    dk.forEach(k => { h += kv(k.replace(/_/g, ' '), t.details[k]); });
    h += '</section>';
  }

  h += '</div>';
  return h;
}

function kv(label, val, isCode) {
  if (!val) return '';
  return `<div class="kv"><span class="kv-k">${esc(label)}</span><span class="kv-v${isCode ? ' code' : ''}">${esc(val)}</span></div>`;
}

// Legacy: redirect #/tool/{id} to split-view with selection
function renderDetail(id) {
  window._selectedToolId = id;
  location.hash = '#/';
}

function renderSettings() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading settings...</div>';
  Promise.all([
    fetch('/api/settings').then(r => r.json()),
    fetch('/api/skills/backup/status').then(r => r.json()).catch(() => null)
  ]).then(([settings, backup]) => {
    let h = `<div class="page-hdr"><h1>Preferences</h1></div>`;

    // Appearance
    h += `<section class="section"><h3>Appearance</h3>`;
    h += settingSelect('theme', 'Theme', settings.theme, [['clawd','Clawd'],['calico','Calico']]);
    h += settingSelect('size', 'Size', settings.size, [['P:8','P:8'],['P:10','P:10'],['P:12','P:12'],['P:15','P:15']]);
    h += settingSelect('lang', 'Language', settings.lang, [['en','English'],['zh','中文'],['ko','한국어']]);
    h += `</section>`;

    // Behavior
    h += `<section class="section"><h3>Behavior</h3>`;
    h += settingToggle('soundMuted', 'Sound Effects', !settings.soundMuted, true);
    h += settingToggle('bubbleFollowPet', 'Bubble Follow Pet', settings.bubbleFollowPet);
    h += settingToggle('hideBubbles', 'Hide Bubbles', settings.hideBubbles);
    h += settingToggle('showSessionId', 'Show Session ID', settings.showSessionId);
    h += `</section>`;

    // System
    h += `<section class="section"><h3>System</h3>`;
    h += settingToggle('showDock', 'Show in Dock', settings.showDock);
    h += settingToggle('showTray', 'Show in Menu Bar', settings.showTray);
    h += settingToggle('openAtLogin', 'Start on Login', settings.openAtLogin);
    h += settingToggle('autoStartWithClaude', 'Auto-start with Claude', settings.autoStartWithClaude);
    h += `</section>`;

    // Marketplace
    h += `<section class="section"><h3>Marketplace</h3>`;
    h += `<div class="setting-row"><span class="setting-label">Default Marketplace URL<span class="setting-saved" id="saved-marketplace_url">Saved</span></span>
      <input class="path-input" id="marketplace-url" value="${esc(settings.marketplace_url || 'https://skills.sh')}" onchange="saveSetting('marketplace_url', this.value)" style="width:260px"></div>`;
    h += `</section>`;

    // Custom Marketplace Repos
    h += `<section class="section"><h3>Custom Marketplace Repos</h3>`;
    h += `<div style="font-size:.78rem;color:var(--text3);margin-bottom:10px">Add git repositories containing skills. They appear as filter labels in Install Skills.</div>`;
    h += `<div id="pref-repos-list"></div>`;
    h += `<div style="display:flex;gap:8px;align-items:center;margin-top:10px">
      <input class="path-input" id="pref-repo-url" placeholder="https://github.com/org/skills-repo.git" style="flex:1">
      <input class="path-input" id="pref-repo-name" placeholder="Display name" style="width:140px">
      <button class="btn btn-sm" onclick="addPrefRepo()">Add</button>
    </div>`;
    h += `<div id="pref-repo-status" style="margin-top:6px;font-size:.78rem"></div>`;
    h += `</section>`;

    // Git Backup
    h += `<section class="section"><h3>Git Backup</h3>`;
    if (backup && backup.isRepo) {
      h += `<div class="kv"><span class="kv-k">Branch</span><span class="kv-v code">${esc(backup.branch || 'unknown')}</span></div>`;
      h += `<div class="kv"><span class="kv-k">Status</span><span class="kv-v" style="color:${backup.hasChanges ? 'var(--red)' : 'var(--green)'}">${backup.hasChanges ? 'Uncommitted changes' : 'Clean'}</span></div>`;
      if (backup.remoteURL) {
        h += `<div class="kv"><span class="kv-k">Remote</span><span class="kv-v code">${esc(backup.remoteURL)}</span></div>`;
      }
      if (backup.lastCommit) {
        h += `<div class="kv"><span class="kv-k">Last Commit</span><span class="kv-v">${esc(backup.lastCommit)}</span></div>`;
      }
      h += `<div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap">`;
      if (backup.hasChanges) h += `<button class="btn btn-sm btn-green" onclick="commitBackup()">Commit</button>`;
      h += `<button class="btn btn-sm" onclick="snapshotBackup()">Snapshot</button>`;
      if (backup.remoteURL) {
        h += `<button class="btn btn-sm" onclick="pushBackup()">Push</button>`;
        h += `<button class="btn btn-sm" onclick="pullBackup()">Pull</button>`;
      }
      h += `</div>`;
      h += `<div style="display:flex;gap:8px;align-items:center;margin-top:10px">
        <input class="path-input" id="remote-url" placeholder="Remote URL (https://...)" value="${esc(backup.remoteURL || '')}" style="flex:1">
        <button class="btn btn-sm" onclick="setRemoteURL()">Set Remote</button>
      </div>`;
    } else {
      h += `<div style="color:var(--text2);font-size:.84rem;margin-bottom:10px">Git backup not initialized.</div>`;
      h += `<div style="display:flex;gap:8px">
        <button class="btn btn-sm" onclick="initBackup()">Initialize</button>
        <button class="btn btn-sm" onclick="cloneBackupPrompt()">Clone from Remote</button>
      </div>`;
    }
    h += `</section>`;

    app.innerHTML = h;
    loadPrefReposList();
  }).catch(e => {
    app.innerHTML = `<div class="empty">Error loading settings: ${esc(String(e))}</div>`;
  });
}

function loadPrefReposList() {
  fetch('/api/skills/marketplace/repos').then(r=>r.json()).then(repos => {
    const el = document.getElementById('pref-repos-list');
    if (!el) return;
    if (!repos.length) { el.innerHTML = '<div style="font-size:.78rem;color:var(--text3)">No custom repos configured.</div>'; return; }
    let h = '';
    for (const r of repos) {
      h += `<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;margin-bottom:4px;background:var(--surface);border-radius:6px;border:1px solid var(--border)">
        <span style="font-weight:500;font-size:.82rem;color:var(--text);min-width:80px">${esc(r.name)}</span>
        <span style="flex:1;font-size:.75rem;color:var(--text3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(r.url)}</span>
        <button class="btn btn-sm" style="font-size:.68rem;padding:2px 8px;color:var(--red)" onclick="removePrefRepo('${esc(r.url)}')">Remove</button>
      </div>`;
    }
    el.innerHTML = h;
  }).catch(() => {});
}

function addPrefRepo() {
  const urlInput = document.getElementById('pref-repo-url');
  const nameInput = document.getElementById('pref-repo-name');
  const statusEl = document.getElementById('pref-repo-status');
  const url = (urlInput ? urlInput.value.trim() : '');
  if (!url) { if (statusEl) statusEl.innerHTML = '<span style="color:var(--red)">URL is required</span>'; return; }
  const name = (nameInput ? nameInput.value.trim() : '') || null;
  if (statusEl) statusEl.innerHTML = '<span class="spinner"></span> Validating...';
  fetch('/api/skills/marketplace/repos', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:url,name:name})})
    .then(r=>r.json()).then(result => {
      if (result.error) { if (statusEl) statusEl.innerHTML = `<span style="color:var(--red)">${esc(result.error)}</span>`; return; }
      if (statusEl) statusEl.innerHTML = '<span style="color:var(--green)">Added successfully</span>';
      if (urlInput) urlInput.value = '';
      if (nameInput) nameInput.value = '';
      loadPrefReposList();
      setTimeout(() => { if (statusEl) statusEl.innerHTML = ''; }, 3000);
    }).catch(e => { if (statusEl) statusEl.innerHTML = `<span style="color:var(--red)">${esc(String(e))}</span>`; });
}

function removePrefRepo(url) {
  fetch('/api/skills/marketplace/repos', {method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:url})})
    .then(r=>r.json()).then(() => { loadPrefReposList(); })
    .catch(e => toast('Error: ' + String(e), 'error'));
}

function settingToggle(key, label, checked, inverted) {
  return `<div class="setting-row"><span class="setting-label">${esc(label)}<span class="setting-saved" id="saved-${key}">Saved</span></span>
    <label class="toggle"><input type="checkbox" ${checked ? 'checked' : ''} onchange="saveSetting('${key}', ${inverted ? '!this.checked' : 'this.checked'})"><span class="slider"></span></label></div>`;
}

function settingSelect(key, label, current, options) {
  let opts = options.map(([v, l]) => `<option value="${v}" ${v === current ? 'selected' : ''}>${esc(l)}</option>`).join('');
  return `<div class="setting-row"><span class="setting-label">${esc(label)}<span class="setting-saved" id="saved-${key}">Saved</span></span>
    <select class="setting-select" onchange="saveSetting('${key}', this.value)">${opts}</select></div>`;
}

function saveSetting(key, value) {
  const body = {}; body[key] = value;
  fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    .then(() => {
      const el = document.getElementById('saved-' + key);
      if (el) { el.classList.add('show'); setTimeout(() => el.classList.remove('show'), 1200); }
    });
}

function toggleTheme() {
  const html = document.documentElement;
  const isLight = html.classList.toggle('light');
  localStorage.setItem('theme', isLight ? 'light' : 'dark');
  const btn = document.getElementById('theme-btn');
  if (btn) btn.textContent = isLight ? '\u{2600}' : '\u{263E}';
}
// Restore saved theme
if (localStorage.getItem('theme') === 'light') {
  document.documentElement.classList.add('light');
}

// ── Skills Pages ──

/* Extra styles for skills UI */
const skillStyles = document.createElement('style');
skillStyles.textContent = `
  .tag-badge{display:inline-flex;align-items:center;gap:3px;font-size:.65rem;padding:2px 8px;border-radius:10px;font-family:var(--mono);font-weight:500;background:rgba(139,92,246,.1);color:#a78bfa;border:1px solid rgba(139,92,246,.15)}
  .tag-badge .tag-x{cursor:pointer;opacity:.5;margin-left:2px;font-size:.75rem}
  .tag-badge .tag-x:hover{opacity:1}
  .update-dot{width:8px;height:8px;border-radius:50%;display:inline-block;flex-shrink:0}
  .update-dot.available{background:#f59e0b;box-shadow:0 0 6px rgba(245,158,11,.4)}
  .update-dot.checking{background:var(--text3);animation:pulse 1.5s infinite}
  .update-dot.up-to-date{background:var(--green)}
  .update-dot.error{background:var(--red)}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .tag-input{background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:4px 10px;font-size:.78rem;font-family:var(--mono);width:120px}
  .tag-input:focus{border-color:var(--accent);outline:none}
  .ft-node{font-family:var(--mono);transition:background .15s}
  .ft-node:hover{background:var(--hover-bg)}
  .tool-cfg-row{display:flex;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--border);font-size:.84rem}
  .tool-cfg-row:last-child{border-bottom:none}
  .tool-cfg-name{display:flex;align-items:center;gap:8px;min-width:160px;font-weight:500}
  .tool-cfg-path{flex:1;font-family:var(--mono);font-size:.76rem;color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .tool-cfg-actions{display:flex;align-items:center;gap:8px;flex-shrink:0}
  .path-input{background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:4px 10px;font-size:.76rem;font-family:var(--mono);width:240px}
  .path-input:focus{border-color:var(--accent);outline:none}
  .btn-sm{padding:3px 10px;font-size:.72rem}
  .btn-warn{border-color:var(--red);color:var(--red)}
  .btn-warn:hover{background:var(--red-bg)}
  .btn-green{border-color:var(--green);color:var(--green)}
  .btn-green:hover{background:var(--green-bg)}
  .update-bar{display:flex;align-items:center;gap:10px;padding:10px 14px;background:rgba(245,158,11,.06);border:1px solid rgba(245,158,11,.2);border-radius:8px;margin-bottom:16px;font-size:.82rem}
  .update-bar .update-dot{margin-right:2px}
`;
document.head.appendChild(skillStyles);

function updateStatusBadge(s) {
  const us = s.updateStatus || 'unknown';
  if (us === 'available') return '<span class="update-dot available" title="Update available"></span>';
  if (us === 'checking') return '<span class="update-dot checking" title="Checking..."></span>';
  if (us === 'up_to_date' || us === 'up-to-date') return '<span class="update-dot up-to-date" title="Up to date"></span>';
  if (us === 'error') return '<span class="update-dot error" title="Check failed"></span>';
  return '';
}

function renderTagBadges(tags) {
  if (!tags || !tags.length) return '';
  return tags.map(t => `<span class="tag-badge">${esc(t)}</span>`).join(' ');
}

function renderSkillsList() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading skills...</div>';
  Promise.all([
    fetch('/api/skills').then(r=>r.json()),
    fetch('/api/skills/tools').then(r=>r.json()),
    fetch('/api/skills/tags').then(r=>r.json()).catch(()=>[])
  ]).then(([skills, tools, allTags]) => {
    window._enabledToolsList = tools.filter(t => t.installed && t.enabled !== false);
    window._allTagsList = allTags;
    window._allSkills = skills;
    window._installedTools = tools.filter(t => t.installed);
    window._currentFilter = window._currentFilter || 'all';

    let h = '<div class="split-view">';
    // ── Left: list panel ──
    h += '<div class="list-panel">';
    h += `<div class="list-toolbar">
      <input id="skill-search" type="text" placeholder="Search skills..." oninput="filterSkillsList()">
      <button class="tb-btn" id="select-toggle" onclick="toggleSelectMode()" title="Batch select">${SI.select}</button>
      <button class="tb-btn" onclick="location.hash='#/skills-marketplace'" title="Install">${SI.plus}</button>
      <button class="tb-btn" onclick="renderSkillsList()" title="Refresh">${SI.refresh}</button>
    </div>`;
    // Filter pills - merge API tags with skill-embedded tags
    const skillTags = [...new Set(skills.flatMap(s => s.tags || []))];
    const mergedTags = [...new Set([...allTags, ...skillTags])].sort();
    window._allTagsList = mergedTags;
    h += `<div id="skill-filters" style="display:flex;gap:4px;padding:4px 10px;flex-wrap:wrap;border-bottom:1px solid var(--border)">`;
    const cf = window._currentFilter || 'all';
    h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px;${cf==='all'?'background:var(--accent);color:#fff;':''}" onclick="filterSkillsList('all')">All</button>`;
    h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px;${cf==='git'?'background:var(--accent);color:#fff;':''}" onclick="filterSkillsList('git')">Git</button>`;
    h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px;${cf==='local'?'background:var(--accent);color:#fff;':''}" onclick="filterSkillsList('local')">Local</button>`;
    for (const tag of mergedTags) {
      const active = cf === 'tag:' + tag;
      h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px;${active?'background:var(--accent);color:#fff;':''}" onclick="filterSkillsList('tag:${esc(tag)}')">${esc(tag)}</button>`;
    }
    h += `</div>`;
    h += '<div class="list-scroll" id="skills-list">';
    h += renderSkillRows(skills);
    h += '</div></div>';

    // ── Right: detail panel ──
    h += '<div class="detail-panel" id="skill-detail">';
    if (skills.length) {
      h += '<div class="empty" style="padding:60px 20px;color:var(--text3)">Select a skill to view details</div>';
    } else {
      h += `<div class="empty" style="padding:60px 20px">No skills installed yet.<br><a href="#/skills-marketplace">Install from marketplace</a></div>`;
    }
    h += '</div>';

    h += '</div>';
    app.innerHTML = h;

    // Auto-select first skill or restore previous selection (skip in batch select mode)
    if (skills.length && !window._selectMode) {
      const prevId = window._selectedSkillId;
      const target = prevId && skills.find(s => s.id === prevId) ? prevId : skills[0].id;
      selectSkillRow(target);
    }

    if (window._selectMode) {
      const btn = document.getElementById('select-toggle');
      if (btn) btn.style.color = 'var(--accent)';
      updateBatchCount();
      renderBatchDetail();
    }
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function renderSkillRows(skills) {
  if (!skills.length) return '<div class="empty" style="padding:30px">No skills match</div>';
  const selectMode = window._selectMode;
  const favs = getFavorites();
  // Sort: favorites first, then alphabetical by name
  const sorted = [...skills].sort((a, b) => {
    const aFav = favs.has(a.id) ? 0 : 1;
    const bFav = favs.has(b.id) ? 0 : 1;
    if (aFav !== bFav) return aFav - bFav;
    return (a.name || '').localeCompare(b.name || '');
  });
  let h = '';
  for (const s of sorted) h += renderOneSkillRow(s, selectMode, favs.has(s.id));
  return h;
}

function getFavorites() {
  try { return new Set(JSON.parse(localStorage.getItem('clawd-favorites') || '[]')); }
  catch { return new Set(); }
}
function setFavorites(set) {
  localStorage.setItem('clawd-favorites', JSON.stringify([...set]));
}
function toggleFavorite(id, event) {
  if (event) event.stopPropagation();
  const favs = getFavorites();
  if (favs.has(id)) favs.delete(id); else favs.add(id);
  setFavorites(favs);
  filterSkillsList();
}
function batchFavorite(add) {
  const sel = window._selectedSkills || {};
  const ids = Object.keys(sel).filter(k => sel[k]);
  if (!ids.length) return;
  const favs = getFavorites();
  ids.forEach(id => { if (add) favs.add(id); else favs.delete(id); });
  setFavorites(favs);
  filterSkillsList();
  toast(add ? 'Added to favorites' : 'Removed from favorites', 'success');
}

function renderOneSkillRow(s, selectMode, isFav) {
  const active = !selectMode && window._selectedSkillId === s.id ? ' active' : '';
  const syncedTools = (s.targets || []).map(t => t.tool);
  const checkbox = selectMode ? `<input type="checkbox" class="sk-cb" ${(window._selectedSkills||{})[s.id]?'checked':''} onchange="event.stopPropagation();toggleSkillSelect('${esc(s.id)}',this.checked)" onclick="event.stopPropagation()" style="width:14px;height:14px;accent-color:var(--accent);cursor:pointer">` : '';
  // Tool icons
  let toolIcons = '';
  for (const t of syncedTools) {
    const iconKey = t.replace(/_/g, '-');
    toolIcons += svg(iconKey, '');
  }
  const extraCount = syncedTools.length > 3 ? `<span class="row-extra">+${syncedTools.length - 3}</span>` : '';
  const starStyle = isFav ? 'color:#f59e0b;opacity:1' : 'color:var(--text3);opacity:.3';
  const star = `<button onclick="toggleFavorite('${esc(s.id)}',event)" style="background:none;border:none;cursor:pointer;padding:0 2px;font-size:.8rem;${starStyle}" title="${isFav ? 'Remove from favorites' : 'Add to favorites'}">\u2605</button>`;

  return `<div class="list-row${active}" data-id="${esc(s.id)}" onclick="${selectMode ? `shiftSelectSkill(event,'${esc(s.id)}')` : `selectSkillRow('${esc(s.id)}')`}">
    ${checkbox}
    ${star}
    <div class="row-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><path d="M14 2v6h6"/></svg></div>
    <span class="row-name">${esc(s.name)}</span>
    <div class="row-tools">${toolIcons}${extraCount}</div>
  </div>`;
}

function selectSkillRow(id) {
  // In select mode, toggle selection instead of showing detail
  if (window._selectMode) {
    toggleSkillSelect(id);
    // Update checkbox UI
    const row = document.querySelector(`.list-row[data-id="${id}"]`);
    if (row) {
      const cb = row.querySelector('.sk-cb');
      if (cb) cb.checked = !!window._selectedSkills[id];
    }
    return;
  }
  window._selectedSkillId = id;
  document.querySelectorAll('.list-row').forEach(r => {
    r.classList.toggle('active', r.dataset.id === id);
  });
  const dp = document.getElementById('skill-detail');
  if (!dp) return;
  dp.innerHTML = '<div class="empty"><span class="spinner"></span></div>';

  const s = (window._allSkills || []).find(sk => sk.id === id);
  if (!s) { dp.innerHTML = '<div class="empty">Skill not found</div>'; return; }

  fetch(`/api/skills/${encodeURIComponent(id)}/document`).then(r=>r.json()).catch(()=>({})).then(doc => {
    renderDetailPanel(s, doc);
  });
}

function renderDetailPanel(s, doc) {
  const dp = document.getElementById('skill-detail');
  if (!dp) return;
  const installed = window._enabledToolsList || [];
  const syncedTools = (s.targets || []).map(t => t.tool);
  const isDisabled = s.enabled === false || s.enabled === 0;

  let h = `<div${isDisabled ? ' style="opacity:.6"' : ''}>`;
  // Title row with actions
  h += `<div style="display:flex;align-items:flex-start;gap:12px;margin-bottom:4px">`;
  h += `<div class="dp-title" style="flex:1;min-width:0">${esc(s.name)}${isDisabled ? ' <span style="font-size:.7rem;padding:2px 8px;border-radius:10px;background:var(--surface);color:var(--text3);border:1px solid var(--border);vertical-align:middle;margin-left:8px">disabled</span>' : ''}</div>`;
  h += `<div class="dp-hdr-actions">
    <button onclick="toggleSkillEnabled('${esc(s.id)}')" title="${isDisabled ? 'Enable' : 'Disable'} skill" style="display:inline-flex;align-items:center;gap:4px;padding:2px 10px;border-radius:20px;font-size:.72rem;border:1px solid ${isDisabled ? 'var(--border)' : 'var(--green)'};background:${isDisabled ? 'var(--surface)' : 'rgba(34,197,94,.12)'};color:${isDisabled ? 'var(--text3)' : 'var(--green)'};cursor:pointer">
      <span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${isDisabled ? 'var(--text3)' : 'var(--green)'}"></span>
      ${isDisabled ? 'Disabled' : 'Enabled'}
    </button>
    <button onclick="checkUpdate('${esc(s.id)}')" title="Check updates" style="background:none;border:1px solid var(--border);border-radius:6px;padding:4px 6px;cursor:pointer;color:var(--text2);display:inline-flex;align-items:center"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="width:14px;height:14px"><circle cx="8" cy="8" r="6"/><path d="M8 5v3l2 1.5"/></svg></button>
    <button onclick="if(confirm('Uninstall this skill?'))uninstallSkill('${esc(s.id)}')" title="Uninstall" style="background:none;border:1px solid var(--border);border-radius:6px;padding:4px 6px;cursor:pointer;color:var(--text2);display:inline-flex;align-items:center" onmouseover="this.style.borderColor='var(--red)';this.style.color='var(--red)'" onmouseout="this.style.borderColor='var(--border)';this.style.color='var(--text2)'"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="width:14px;height:14px"><path d="M3 4h10M6 4V3h4v1M5 4v8.5a1 1 0 001 1h4a1 1 0 001-1V4"/></svg></button>
  </div></div>`;
  if (s.description) h += `<div class="dp-desc" style="white-space:pre-wrap;word-break:break-word;overflow-wrap:break-word">${esc(s.description)}</div>`;
  else h += `<div class="dp-desc" style="color:var(--text3);font-style:italic">No description</div>`;

  // Synced Tools section (before Location)
  const unsyncedCount = installed.filter(t => !syncedTools.includes(t.key)).length;
  h += `<div class="dp-section"><div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
    <h3>Synced Tools</h3>`;
  if (unsyncedCount > 0) {
    h += `<button class="btn btn-sm btn-green" onclick="syncAll('${esc(s.id)}')">Sync All</button>`;
  }
  h += `</div>`;
  h += `<div style="display:flex;flex-direction:column;gap:4px">`;
  for (const t of installed) {
    const isSynced = syncedTools.includes(t.key);
    const iconKey = t.key.replace(/_/g, '-');
    if (isSynced) {
      h += `<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:6px;background:rgba(34,197,94,.06);border:1px solid rgba(34,197,94,.15)">
        <span class="row-icon" style="width:18px;height:18px;flex-shrink:0">${svg(iconKey)}</span>
        <span style="flex:1;font-size:.8rem;color:var(--text)">${esc(t.displayName || t.key)}</span>
        <span style="font-size:.72rem;color:var(--green)">\u2713 synced</span>
        <button onclick="unsyncTool('${esc(s.id)}','${esc(t.key)}')" style="background:none;border:none;cursor:pointer;font-size:.68rem;color:var(--text3);padding:2px 6px;border-radius:4px" onmouseover="this.style.color='var(--red)';this.style.background='var(--red-bg)'" onmouseout="this.style.color='var(--text3)';this.style.background='none'">unsync</button>
      </div>`;
    } else {
      h += `<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:6px;background:var(--surface);border:1px solid var(--border);cursor:pointer" onclick="syncTool('${esc(s.id)}','${esc(t.key)}')">
        <span class="row-icon" style="width:18px;height:18px;flex-shrink:0;opacity:.5">${svg(iconKey)}</span>
        <span style="flex:1;font-size:.8rem;color:var(--text3)">${esc(t.displayName || t.key)}</span>
        <span style="font-size:.72rem;color:var(--text3)">\u2014</span>
        <span style="font-size:.68rem;color:var(--accent)">sync</span>
      </div>`;
    }
  }
  h += `</div></div>`;

  // Location section
  h += `<div class="dp-section"><h3 style="margin-bottom:8px">Location (${syncedTools.length + 1})</h3>`;
  // Central repo path
  h += `<div class="dp-loc-item">
    <div><div class="dp-loc-path">${esc(shortPath(s.centralPath))}</div><div class="dp-loc-tool">Central Repo</div></div>
    <div class="dp-loc-actions">
      <button onclick="navigator.clipboard.writeText('${esc(s.centralPath)}');toast('Path copied','success')" title="Copy path"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="width:14px;height:14px"><rect x="5" y="5" width="8" height="8" rx="1.5"/><path d="M3 11V3.5A1.5 1.5 0 014.5 2H11"/></svg></button>
    </div>
  </div>`;
  // Synced tool paths
  for (const t of s.targets || []) {
    const toolName = installed.find(x => x.key === t.tool)?.displayName || t.tool;
    h += `<div class="dp-loc-item">
      <div><div class="dp-loc-path">${esc(shortPath(t.targetPath))}</div><div class="dp-loc-tool">${esc(toolName)}${t.mode === 'copy' ? ' (copy)' : ''}</div></div>
      <div class="dp-loc-actions">
        <button onclick="unsyncTool('${esc(s.id)}','${esc(t.tool)}')" title="Unsync"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="width:14px;height:14px"><path d="M3 4h10M6 4V3h4v1M5 4v8.5a1 1 0 001 1h4a1 1 0 001-1V4"/></svg></button>
      </div>
    </div>`;
  }
  h += '</div>';

  // Tags (always show — allows adding tags to any skill)
  h += `<div class="dp-section"><div class="dp-section-hdr" onclick="this.nextElementSibling.style.display=this.nextElementSibling.style.display==='none'?'':'none';this.querySelector('.chevron').classList.toggle('open')">
    <h3>Tags</h3><span class="chevron open">\u25BC</span></div>
    <div style="margin-top:10px">
      <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-bottom:8px">`;
  (s.tags || []).forEach(t => {
    h += `<span class="tag-badge">${esc(t)} <span class="tag-x" onclick="event.stopPropagation();removeTag('${esc(s.id)}','${esc(t)}')">\u{00D7}</span></span>`;
  });
  h += `</div><div style="display:flex;gap:6px;align-items:center">
          <input class="tag-input" id="new-tag" placeholder="Add tag..." onkeydown="if(event.key==='Enter')addTag('${esc(s.id)}')">
          <button class="btn btn-sm" onclick="addTag('${esc(s.id)}')">Add</button>
        </div>
      </div></div>`;

  // Content section — file tree + viewer
  h += `<div class="dp-section"><div class="dp-section-hdr" onclick="this.nextElementSibling.style.display=this.nextElementSibling.style.display==='none'?'':'none';this.querySelector('.chevron').classList.toggle('open')">
    <h3>Content</h3><span class="chevron open">\u25BC</span></div>
    <div style="margin-top:10px">
      <div id="skill-content-view" style="display:flex;gap:0;border:1px solid var(--border);border-radius:8px;overflow:hidden;height:420px">
        <div id="skill-file-tree" style="width:160px;min-width:120px;border-right:1px solid var(--border);overflow-y:auto;background:var(--surface);padding:6px 0;font-size:.72rem"></div>
        <div id="skill-file-viewer" style="flex:1;overflow:auto;padding:14px;font-size:.78rem"></div>
      </div>
    </div></div>`;

  // Info section (collapsible)
  h += `<div class="dp-section"><div class="dp-section-hdr" onclick="this.nextElementSibling.style.display=this.nextElementSibling.style.display==='none'?'':'none';this.querySelector('.chevron').classList.toggle('open')">
    <h3>Info</h3><span class="chevron">\u25BC</span></div>
    <div style="display:none;margin-top:10px">`;
  h += kv('Source', s.sourceType + (s.sourceRef ? ' \u{2014} ' + s.sourceRef : ''));
  if (s.sourceRevision) h += kv('Revision', s.sourceRevision.substring(0, 10), true);
  if (s.contentHash) h += kv('Hash', s.contentHash.substring(0, 10), true);
  h += kv('Status', s.status);
  h += kv('Created', new Date(s.createdAt).toLocaleDateString());
  h += kv('Updated', new Date(s.updatedAt).toLocaleDateString());
  h += '</div></div>';

  h += '</div>';
  dp.innerHTML = h;
  // Load file tree after DOM is updated
  loadSkillFiles(s.id);
}

function filterSkillsList(filter) {
  const list = document.getElementById('skills-list');
  if (!list || !window._allSkills) return;
  if (filter) window._currentFilter = filter;
  const f = window._currentFilter || 'all';
  const q = (document.getElementById('skill-search')?.value || '').toLowerCase();
  let filtered = window._allSkills;
  if (f === 'git') filtered = filtered.filter(s => s.sourceType === 'git');
  else if (f === 'local') filtered = filtered.filter(s => s.sourceType === 'local');
  else if (f.startsWith('tag:')) filtered = filtered.filter(s => (s.tags||[]).includes(f.slice(4)));
  if (q) filtered = filtered.filter(s => (s.name||'').toLowerCase().includes(q) || (s.description||'').toLowerCase().includes(q));
  list.innerHTML = renderSkillRows(filtered);
  // Update filter pill active states
  const fp = document.getElementById('skill-filters');
  if (fp) {
    fp.querySelectorAll('button').forEach(btn => {
      const isActive = btn.onclick && btn.onclick.toString().includes("'" + f + "'");
      btn.style.background = isActive ? 'var(--accent)' : '';
      btn.style.color = isActive ? '#fff' : '';
    });
  }
}

function checkAllUpdates() {
  const el = document.getElementById('check-status');
  if (el) el.textContent = 'Checking...';
  fetch('/api/skills/check-all-updates', {method:'POST'}).then(r=>r.json()).then(res => {
    if (el) el.textContent = `Done: ${res.updatable||0} updatable`;
    setTimeout(() => renderSkillsList(), 800);
  }).catch(e => { if (el) el.textContent = 'Error: ' + e; });
}

function batchUpdate() {
  if (!confirm('Update all skills with available updates?')) return;
  fetch('/api/skills/batch-update', {method:'POST'}).then(r=>r.json()).then(res => {
    toast(`Updated ${res.updated||0} of ${res.total||0} skills`, 'success');
    renderSkillsList();
  }).catch(e => toast('Batch update failed: ' + e, 'error'));
}

// Batch select operations
function toggleSelectMode() {
  window._selectMode = !window._selectMode;
  window._selectedSkills = {};
  const btn = document.getElementById('select-toggle');
  if (btn) btn.style.color = window._selectMode ? 'var(--accent)' : '';
  updateBatchCount();
  renderBatchDetail();
  filterSkillsList();
}

function toggleSkillSelect(id, force) {
  if (!window._selectedSkills) window._selectedSkills = {};
  if (force !== undefined) window._selectedSkills[id] = force;
  else window._selectedSkills[id] = !window._selectedSkills[id];
  if (!window._selectedSkills[id]) delete window._selectedSkills[id];
  updateBatchCount();
  renderBatchDetail();
}

function shiftSelectSkill(event, id) {
  if (window._shiftHeld && window._lastClickedSkillId) {
    const rows = [...document.querySelectorAll('#skills-list .list-row')];
    const ids = rows.map(r => r.dataset.id);
    const from = ids.indexOf(window._lastClickedSkillId);
    const to = ids.indexOf(id);
    if (from !== -1 && to !== -1) {
      const start = Math.min(from, to);
      const end = Math.max(from, to);
      for (let i = start; i <= end; i++) {
        window._selectedSkills[ids[i]] = true;
      }
      updateBatchCount();
      renderBatchDetail();
      filterSkillsList();
      window._lastClickedSkillId = id;
      return;
    }
  }
  toggleSkillSelect(id);
  filterSkillsList();
  window._lastClickedSkillId = id;
}

function getSelectedIds() {
  return Object.keys(window._selectedSkills || {}).filter(k => window._selectedSkills[k]);
}

function updateBatchCount() {
  const cnt = getSelectedIds().length;
  const el = document.getElementById('batch-count');
  if (el) el.textContent = cnt + ' selected';
}

function renderBatchDetail() {
  const dp = document.getElementById('skill-detail');
  if (!dp || !window._selectMode) return;
  const ids = getSelectedIds();
  const tools = window._enabledToolsList || [];
  const tags = window._allTagsList || [];

  let h = '<div>';
  h += `<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
    <div class="dp-title" style="margin-bottom:0"><span id="batch-count">${ids.length} selected</span></div>
    <div style="display:flex;gap:6px">
      <button class="btn btn-sm" onclick="batchSelectAll()">Select All</button>
      <button class="btn btn-sm" onclick="batchDeselectAll()">Deselect</button>
    </div>
  </div>`;

  if (!ids.length) {
    h += '<div class="dp-desc" style="color:var(--text3)">Click skills in the list to select them for batch operations.</div>';
    h += '</div>';
    dp.innerHTML = h;
    return;
  }

  // Synced Tools batch
  h += `<div class="dp-section"><h3 style="margin-bottom:8px">Sync to Tools</h3>`;
  h += `<div style="display:flex;flex-direction:column;gap:4px">`;
  for (const t of tools) {
    const iconKey = t.key.replace(/_/g, '-');
    h += `<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:6px;background:var(--surface);border:1px solid var(--border)">
      <span class="row-icon" style="width:18px;height:18px;flex-shrink:0">${svg(iconKey)}</span>
      <span style="flex:1;font-size:.8rem">${esc(t.displayName || t.key)}</span>
      <button onclick="batchSyncTo('${esc(t.key)}')" class="btn btn-sm btn-green" style="font-size:.66rem;padding:2px 8px">sync</button>
      <button onclick="batchUnsyncFrom('${esc(t.key)}')" class="btn btn-sm btn-warn" style="font-size:.66rem;padding:2px 8px">unsync</button>
    </div>`;
  }
  h += `</div></div>`;

  // Tags batch
  h += `<div class="dp-section"><h3 style="margin-bottom:8px">Tags</h3>`;
  h += `<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px">`;
  for (const t of tags) {
    h += `<button class="btn btn-sm" style="font-size:.72rem;padding:2px 10px" onclick="batchToggleTag('${esc(t)}')">${esc(t)}</button>`;
  }
  h += `</div>`;
  h += `<div style="display:flex;gap:6px;align-items:center">
    <input class="tag-input" id="batch-new-tag" placeholder="New tag..." onkeydown="if(event.key==='Enter')batchAddNewTag()">
    <button class="btn btn-sm" onclick="batchAddNewTag()">Add</button>
  </div></div>`;

  // Favorites batch
  h += `<div class="dp-section"><h3 style="margin-bottom:8px">Favorites</h3>
    <div style="display:flex;gap:8px">
      <button class="btn btn-sm" style="flex:1" onclick="batchFavorite(true)">\u2605 Add to Favorites</button>
      <button class="btn btn-sm" style="flex:1" onclick="batchFavorite(false)">Remove</button>
    </div></div>`;

  // Delete batch
  h += `<div class="dp-section">
    <button class="btn btn-warn" style="width:100%" onclick="batchDelete()">Delete ${ids.length} selected skills</button>
  </div>`;

  h += `<div id="batch-status" style="font-size:.72rem;color:var(--text3);margin-top:8px;min-height:16px"></div>`;
  h += '</div>';
  dp.innerHTML = h;
}

function batchSelectAll() {
  if (!window._allSkills) return;
  window._selectedSkills = {};
  window._allSkills.forEach(s => { window._selectedSkills[s.id] = true; });
  updateBatchCount();
  renderBatchDetail();
  filterSkillsList();
}

function batchDeselectAll() {
  window._selectedSkills = {};
  updateBatchCount();
  renderBatchDetail();
  filterSkillsList();
}

function batchStatus(msg) {
  const el = document.getElementById('batch-status');
  if (el) el.textContent = msg;
}

async function batchToggleTag(tag) {
  const ids = getSelectedIds();
  if (!ids.length) return;
  // Check if most selected skills already have this tag -> remove, else add
  const withTag = window._allSkills.filter(s => ids.includes(s.id) && (s.tags||[]).includes(tag)).length;
  const shouldAdd = withTag < ids.length / 2;
  batchStatus(shouldAdd ? `Adding "${tag}"...` : `Removing "${tag}"...`);
  let ok = 0;
  for (const id of ids) {
    try {
      if (shouldAdd) {
        const r = await fetch('/api/skills/' + encodeURIComponent(id) + '/tags', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tag})});
        if (r.ok) ok++;
      } else {
        const r = await fetch('/api/skills/' + encodeURIComponent(id) + '/tags/' + encodeURIComponent(tag), {method:'DELETE'});
        if (r.ok) ok++;
      }
    } catch(e) {}
  }
  batchStatus(`${shouldAdd?'Added':'Removed'} "${tag}" for ${ok}/${ids.length} skills`);
  setTimeout(() => renderSkillsList(), 600);
}

async function batchAddNewTag() {
  const input = document.getElementById('batch-new-tag');
  const tag = (input?.value || '').trim();
  if (!tag) return;
  const ids = getSelectedIds();
  if (!ids.length) return;
  batchStatus(`Adding "${tag}"...`);
  let ok = 0;
  for (const id of ids) {
    try {
      const r = await fetch('/api/skills/' + encodeURIComponent(id) + '/tags', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tag})});
      if (r.ok) ok++;
    } catch(e) {}
  }
  batchStatus(`Added "${tag}" to ${ok}/${ids.length} skills`);
  if (input) input.value = '';
  setTimeout(() => renderSkillsList(), 600);
}

async function batchSyncTo(toolKey) {
  const ids = getSelectedIds();
  if (!ids.length) return;
  const name = (window._enabledToolsList||[]).find(t=>t.key===toolKey)?.displayName || toolKey;
  batchStatus(`Syncing to ${name}...`);
  let ok = 0;
  for (const id of ids) {
    try {
      const r = await fetch('/api/skills/' + encodeURIComponent(id) + '/sync', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tool:toolKey})});
      if (r.ok) { ok++; addToActiveScenario(id); }
    } catch(e) {}
  }
  batchStatus(`Synced ${ok}/${ids.length} skills to ${name}`);
  setTimeout(() => renderSkillsList(), 600);
}

async function batchUnsyncFrom(toolKey) {
  const ids = getSelectedIds();
  if (!ids.length) return;
  const name = (window._enabledToolsList||[]).find(t=>t.key===toolKey)?.displayName || toolKey;
  batchStatus(`Unsyncing from ${name}...`);
  let ok = 0;
  for (const id of ids) {
    try {
      const r = await fetch('/api/skills/' + encodeURIComponent(id) + '/sync/' + encodeURIComponent(toolKey), {method:'DELETE'});
      if (r.ok) ok++;
    } catch(e) {}
  }
  batchStatus(`Unsynced ${ok}/${ids.length} skills from ${name}`);
  setTimeout(() => renderSkillsList(), 600);
}

async function batchDelete() {
  const ids = getSelectedIds();
  if (!ids.length) return;
  if (!confirm(`Delete ${ids.length} selected skill(s)? This removes them from the central repo and all synced tools.`)) return;
  batchStatus(`Deleting ${ids.length} skills...`);
  let ok = 0;
  for (const id of ids) {
    try {
      const r = await fetch('/api/skills/' + encodeURIComponent(id), {method:'DELETE'});
      if (r.ok) ok++;
    } catch(e) {}
  }
  window._selectedSkills = {};
  toast(`Deleted ${ok}/${ids.length} skills`, 'success');
  batchStatus(`Deleted ${ok}/${ids.length} skills`);
  setTimeout(() => renderSkillsList(), 600);
}

function renderSkillDetail(id) {
  // If we're in split view, just select the row
  if (document.querySelector('.split-view')) {
    selectSkillRow(id);
    return;
  }
  // Otherwise redirect to skills list and select
  window._selectedSkillId = id;
  location.hash = '#/skills';
}

// Skill actions — refresh detail panel inline
// ── File tree + markdown viewer ──
function loadSkillFiles(skillId) {
  const tree = document.getElementById('skill-file-tree');
  const viewer = document.getElementById('skill-file-viewer');
  if (!tree || !viewer) return;
  tree.innerHTML = '<div style="padding:8px;color:var(--text3)">Loading...</div>';
  fetch(`/api/skills/${encodeURIComponent(skillId)}/files`).then(r=>r.json()).then(data => {
    const files = (data.files || []).filter(f => !f.isDir).sort((a,b) => {
      // SKILL.md first, then alphabetical
      if (a.path === 'SKILL.md') return -1;
      if (b.path === 'SKILL.md') return 1;
      return a.path.localeCompare(b.path);
    });
    if (!files.length) { tree.innerHTML = '<div style="padding:8px;color:var(--text3)">No files</div>'; return; }

    // Build tree structure
    const dirs = {};
    files.forEach(f => {
      const parts = f.path.split('/');
      if (parts.length > 1) {
        const dir = parts.slice(0, -1).join('/');
        if (!dirs[dir]) dirs[dir] = [];
        dirs[dir].push(f);
      }
    });
    const rootFiles = files.filter(f => !f.path.includes('/'));

    let h = '';
    rootFiles.forEach(f => { h += fileNode(skillId, f.path, f.path, 0); });
    Object.keys(dirs).sort().forEach(dir => {
      h += `<div style="padding:3px 8px;font-weight:600;color:var(--text3);font-size:.68rem;margin-top:4px">${esc(dir)}/</div>`;
      dirs[dir].forEach(f => { h += fileNode(skillId, f.path, f.path.split('/').pop(), 1); });
    });
    tree.innerHTML = h;

    // Auto-load SKILL.md
    loadSkillFile(skillId, 'SKILL.md');
  }).catch(() => { tree.innerHTML = '<div style="padding:8px;color:var(--red)">Error loading files</div>'; });
}

function fileNode(skillId, path, name, depth) {
  const indent = depth * 12 + 8;
  const ext = name.split('.').pop().toLowerCase();
  const icon = ext === 'md' ? '\u{1F4C4}' : ext === 'py' ? '\u{1F40D}' : ext === 'js' || ext === 'ts' ? '\u{1F4DC}' : ext === 'sh' ? '\u{1F4BB}' : '\u{1F4C3}';
  return `<div class="ft-node" data-path="${esc(path)}" onclick="loadSkillFile('${esc(skillId)}','${esc(path)}')" style="padding:3px ${indent}px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" title="${esc(path)}">${icon} ${esc(name)}</div>`;
}

function loadSkillFile(skillId, path) {
  const viewer = document.getElementById('skill-file-viewer');
  if (!viewer) return;
  // Highlight active file
  document.querySelectorAll('.ft-node').forEach(n => {
    n.style.background = n.dataset.path === path ? 'var(--accent-bg)' : '';
    n.style.color = n.dataset.path === path ? 'var(--accent)' : '';
  });
  viewer.innerHTML = '<div style="color:var(--text3)">Loading...</div>';
  fetch(`/api/skills/${encodeURIComponent(skillId)}/file?path=${encodeURIComponent(path)}`).then(r=>r.json()).then(data => {
    if (data.error) { viewer.innerHTML = `<div style="color:var(--red)">${esc(data.error)}</div>`; return; }
    const ext = path.split('.').pop().toLowerCase();
    if (ext === 'md') {
      viewer.innerHTML = renderMarkdown(data.content || '');
    } else {
      viewer.innerHTML = `<pre style="font-family:var(--mono);font-size:.76rem;white-space:pre-wrap;margin:0">${esc(data.content || '')}</pre>`;
    }
  }).catch(e => { viewer.innerHTML = `<div style="color:var(--red)">Error: ${esc(String(e))}</div>`; });
}

function renderMarkdown(md) {
  // Strip YAML frontmatter
  let text = md.replace(/^---[\s\S]*?---\n?/, '');
  const lines = text.split('\n');
  let html = '';
  let i = 0;
  let inCode = false;
  let codeBlock = '';

  while (i < lines.length) {
    const line = lines[i];

    // Code block toggle
    if (line.trimStart().startsWith('```')) {
      if (inCode) {
        html += `<pre style="background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:10px;font-family:var(--mono);font-size:.74rem;overflow-x:auto;margin:8px 0">${esc(codeBlock)}</pre>`;
        codeBlock = '';
        inCode = false;
      } else {
        inCode = true;
      }
      i++; continue;
    }
    if (inCode) { codeBlock += (codeBlock ? '\n' : '') + line; i++; continue; }

    // Table: detect header row followed by separator row
    if (line.includes('|') && i + 1 < lines.length && /^[\s|:\-]+$/.test(lines[i + 1])) {
      let tableHtml = '<table style="width:100%;border-collapse:collapse;margin:8px 0;font-size:.76rem">';
      // Header
      const hCells = line.split('|').map(c => c.trim()).filter(c => c !== '');
      tableHtml += '<tr>';
      hCells.forEach(c => { tableHtml += `<th style="border:1px solid var(--border);padding:4px 8px;background:var(--surface);text-align:left;font-weight:600">${inlineMd(esc(c))}</th>`; });
      tableHtml += '</tr>';
      i += 2; // skip header + separator
      // Body rows
      while (i < lines.length && lines[i].includes('|')) {
        const cells = lines[i].split('|').map(c => c.trim()).filter(c => c !== '');
        tableHtml += '<tr>';
        cells.forEach(c => { tableHtml += `<td style="border:1px solid var(--border);padding:4px 8px">${inlineMd(esc(c))}</td>`; });
        tableHtml += '</tr>';
        i++;
      }
      tableHtml += '</table>';
      html += tableHtml;
      continue;
    }

    // Headers
    const hm = line.match(/^(#{1,4})\s+(.+)$/);
    if (hm) {
      const lvl = hm[1].length;
      const sizes = ['1.1rem','1rem','.9rem','.85rem'];
      html += `<h${lvl} style="font-size:${sizes[lvl-1]};margin:16px 0 8px;color:var(--text)">${inlineMd(esc(hm[2]))}</h${lvl}>`;
      i++; continue;
    }

    // Horizontal rule
    if (/^---+$/.test(line.trim())) {
      html += '<hr style="border:none;border-top:1px solid var(--border);margin:12px 0">';
      i++; continue;
    }

    // Unordered list
    if (/^[\-\*]\s+/.test(line)) {
      html += `<li style="margin-left:16px;list-style:disc;font-size:.78rem">${inlineMd(esc(line.replace(/^[\-\*]\s+/, '')))}</li>`;
      i++; continue;
    }

    // Ordered list
    if (/^\d+\.\s+/.test(line)) {
      html += `<li style="margin-left:16px;list-style:decimal;font-size:.78rem">${inlineMd(esc(line.replace(/^\d+\.\s+/, '')))}</li>`;
      i++; continue;
    }

    // Empty line = paragraph break
    if (line.trim() === '') {
      html += '<div style="height:8px"></div>';
      i++; continue;
    }

    // Regular text
    html += `<p style="margin:4px 0;line-height:1.5">${inlineMd(esc(line))}</p>`;
    i++;
  }

  return `<div class="md-view" style="line-height:1.6;color:var(--text)">${html}</div>`;
}

function inlineMd(text) {
  // Code spans
  text = text.replace(/`([^`]+)`/g, '<code style="background:var(--surface);padding:1px 5px;border-radius:3px;font-family:var(--mono);font-size:.76rem">$1</code>');
  // Bold
  text = text.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  // Italic
  text = text.replace(/\*(.+?)\*/g, '<em>$1</em>');
  // Links
  text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" style="color:var(--accent)">$1</a>');
  return text;
}

function refreshSkillDetail(skillId) {
  fetch('/api/skills').then(r=>r.json()).then(skills => {
    window._allSkills = skills;
    const s = skills.find(sk => sk.id === skillId);
    if (!s) return;
    fetch(`/api/skills/${encodeURIComponent(skillId)}/document`).then(r=>r.json()).catch(()=>({})).then(doc => {
      renderDetailPanel(s, doc);
      // Also refresh list rows
      const list = document.getElementById('skills-list');
      if (list) list.innerHTML = renderSkillRows(skills);
    });
  });
}

function addToActiveScenario(skillId) {
  fetch('/api/skills/scenarios/active').then(r => r.ok ? r.json() : null).then(active => {
    if (active && active.id) {
      return fetch(`/api/skills/scenarios/${encodeURIComponent(active.id)}/add-skill`,
        {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({skill_id:skillId})});
    }
    // No active scenario — create Default and activate it, then add skill
    return fetch('/api/skills/scenarios',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'Default',description:'Default scenario',icon:'\u{1F4CB}'})})
      .then(r => r.ok ? r.json() : null)
      .then(created => {
        if (!created || !created.id) return;
        return fetch(`/api/skills/scenarios/${encodeURIComponent(created.id)}/activate`,{method:'POST'})
          .then(() => fetch(`/api/skills/scenarios/${encodeURIComponent(created.id)}/add-skill`,
            {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({skill_id:skillId})}));
      });
  }).catch(()=>{});
}
function syncTool(skillId, tool) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/sync`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tool})})
    .then(() => { addToActiveScenario(skillId); refreshSkillDetail(skillId); });
}
function unsyncTool(skillId, tool) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/sync/${encodeURIComponent(tool)}`, {method:'DELETE'})
    .then(() => refreshSkillDetail(skillId));
}
function syncAll(skillId) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/sync-all`, {method:'POST'})
    .then(() => { addToActiveScenario(skillId); refreshSkillDetail(skillId); });
}
function uninstallSkill(skillId) {
  if (!confirm('Uninstall this skill? This removes it from the central repo and all synced tools.')) return;
  fetch(`/api/skills/${encodeURIComponent(skillId)}`, {method:'DELETE'})
    .then(() => { window._selectedSkillId = null; renderSkillsList(); });
}
function checkUpdate(skillId) {
  const btn = document.getElementById('check-btn');
  if (btn) { btn.disabled = true; btn.textContent = 'Checking...'; }
  fetch(`/api/skills/${encodeURIComponent(skillId)}/check-update`, {method:'POST'})
    .then(r=>r.json()).then(() => refreshSkillDetail(skillId))
    .catch(e => { toast('Check failed: ' + e, 'error'); if (btn) { btn.disabled = false; btn.textContent = 'Check for Updates'; } });
}
function updateSkill(skillId) {
  if (!confirm('Update this skill to the latest version?')) return;
  fetch(`/api/skills/${encodeURIComponent(skillId)}/update`, {method:'POST'})
    .then(r=>r.json()).then(res => {
      if (res.error) { toast('Update failed: ' + res.error, 'error'); return; }
      refreshSkillDetail(skillId);
    }).catch(e => toast('Update failed: ' + e, 'error'));
}
function reimportSkill(skillId) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/reimport`, {method:'POST'})
    .then(r=>r.json()).then(res => {
      if (res.error) { toast('Re-import failed: ' + res.error, 'error'); return; }
      refreshSkillDetail(skillId);
    }).catch(e => toast('Re-import failed: ' + e, 'error'));
}
function relinkSkill(skillId) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/relink`, {method:'POST'})
    .then(r=>r.json()).then(res => {
      if (res.error) { toast('Re-link failed: ' + res.error, 'error'); return; }
      refreshSkillDetail(skillId);
    }).catch(e => toast('Re-link failed: ' + e, 'error'));
}
function detachSkill(skillId) {
  if (!confirm('Detach this skill from its local source? The skill remains installed but loses its source link.')) return;
  fetch(`/api/skills/${encodeURIComponent(skillId)}/detach`, {method:'POST'})
    .then(r=>r.json()).then(res => {
      if (res.error) { toast('Detach failed: ' + res.error, 'error'); return; }
      refreshSkillDetail(skillId);
    }).catch(e => toast('Detach failed: ' + e, 'error'));
}
function toggleSkillEnabled(skillId) {
  fetch(`/api/skills/${encodeURIComponent(skillId)}/toggle-enabled`, {method:'POST'})
    .then(r=>r.json()).then(res => {
      if (res.error) { toast('Toggle failed: ' + res.error, 'error'); return; }
      const label = res.enabled ? 'enabled' : 'disabled';
      toast(`Skill ${label}`, 'success');
      refreshSkillDetail(skillId);
    }).catch(e => toast('Toggle failed: ' + e, 'error'));
}

// Tag management
function addTag(skillId) {
  const input = document.getElementById('new-tag');
  const tag = (input.value || '').trim().toLowerCase().replace(/[^a-z0-9_-]/g, '');
  if (!tag) return;
  fetch('/api/skills').then(r=>r.json()).then(skills => {
    const s = skills.find(sk => sk.id === skillId);
    const tags = [...new Set([...(s ? s.tags : []), tag])];
    return fetch(`/api/skills/${encodeURIComponent(skillId)}/tags`, {method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({tags})});
  }).then(() => { if (input) input.value = ''; refreshSkillDetail(skillId); });
}
function removeTag(skillId, tag) {
  fetch('/api/skills').then(r=>r.json()).then(skills => {
    const s = skills.find(sk => sk.id === skillId);
    const tags = (s ? s.tags : []).filter(t => t !== tag);
    return fetch(`/api/skills/${encodeURIComponent(skillId)}/tags`, {method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({tags})});
  }).then(() => refreshSkillDetail(skillId));
}

// ── Marketplace ──

function renderSkillsMarketplace() {
  const app = document.getElementById('app');
  const tab = window._installTab || 'marketplace';
  let h = `<div class="page-hdr"><h1>Install Skills</h1></div>`;
  h += `<div class="tabs">
    <button class="tab${tab==='marketplace'?' active':''}" onclick="window._installTab='marketplace';renderSkillsMarketplace()">Marketplace</button>
    <button class="tab${tab==='discover'?' active':''}" onclick="window._installTab='discover';renderSkillsMarketplace()">Discover Local</button>
    <button class="tab${tab==='manual'?' active':''}" onclick="window._installTab='manual';renderSkillsMarketplace()">Manual Install</button>
  </div>`;
  h += '<div id="install-content"><div class="empty"><span class="spinner"></span> Loading...</div></div>';
  app.innerHTML = h;

  if (tab === 'marketplace') { loadMarketplaceTab(); }
  else if (tab === 'discover') { loadDiscoverTab(); }
  else { loadManualInstallTab(); }
}

function loadMarketplaceTab() {
  const el = document.getElementById('install-content');
  Promise.all([
    fetch('/api/skills/marketplace').then(r=>r.json()),
    fetch('/api/skills').then(r=>r.json()).catch(()=>[]),
    fetch('/api/skills/marketplace/repos').then(r=>r.json()).catch(()=>[])
  ]).then(async ([skills, installed, repos]) => {
    window._mktRepos = repos;
    window._installedSources = new Set(installed.map(s => s.sourceRef).filter(Boolean));

    // Scan saved repos and merge their skills into the marketplace grid
    const repoSkills = [];
    for (const repo of repos) {
      try {
        const rs = await fetch(`/api/skills/marketplace/repos/scan?url=${encodeURIComponent(repo.url)}`).then(r=>r.json());
        if (Array.isArray(rs)) {
          for (const s of rs) {
            repoSkills.push({
              id: `${repo.name}/${s.name}`,
              skillId: s.name,
              name: s.name,
              source: repo.name,
              installs: 0,
              _repoUrl: repo.url,
              _repoPath: s.path,
              _isRepo: true,
              _description: s.description
            });
          }
        }
      } catch {}
    }

    const allSkills = [...skills, ...repoSkills];
    // Sort: by installs desc (default marketplace), then by name asc (repo skills with 0 installs)
    allSkills.sort((a, b) => {
      if ((b.installs||0) !== (a.installs||0)) return (b.installs||0) - (a.installs||0);
      return (a.name||'').localeCompare(b.name||'');
    });
    window._mktSkills = allSkills;

    // Separate default marketplace sources from custom repo sources
    const repoNames = new Set(repos.map(r => r.name));
    const srcCount = {};
    allSkills.forEach(s => { srcCount[s.source] = (srcCount[s.source]||0) + 1; });
    const defaultSources = Object.entries(srcCount).filter(([src]) => !repoNames.has(src)).sort((a,b) => b[1]-a[1]);
    const repoSources = Object.entries(srcCount).filter(([src]) => repoNames.has(src)).sort((a,b) => b[1]-a[1]);
    const maxInstalls = Math.max(...skills.map(s => s.installs||0), 1);
    window._mktMaxInstalls = maxInstalls;
    let h = '';
    // Search and filter
    h += `<div style="margin-bottom:12px;display:flex;gap:8px;align-items:center">
      <input id="mkt-search" type="text" placeholder="Search skills..." style="flex:1;padding:8px 12px;background:var(--surface);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:.85rem" oninput="filterMkt()" onkeydown="if(event.key==='Enter')searchMkt()">
      <button class="btn" onclick="searchMkt()">Search</button>
    </div>`;
    h += `<div style="margin-bottom:14px;display:flex;gap:6px;flex-wrap:wrap;align-items:center;max-height:60px;overflow-y:auto">
      <button class="btn btn-sm" style="font-size:.64rem" data-src="all" onclick="filterMktBySource('all')">All (${allSkills.length})</button>`;
    for (const [src, cnt] of defaultSources.slice(0, 20)) {
      const label = src.split('/')[0];
      h += `<button class="btn btn-sm" style="font-size:.64rem" data-src="${esc(src)}" onclick="filterMktBySource('${esc(src)}')">${esc(label)} (${cnt})</button>`;
    }
    // Custom repo labels with distinct style
    for (const [src, cnt] of repoSources) {
      h += `<button class="btn btn-sm" style="font-size:.64rem;border-color:var(--green);color:var(--green)" data-src="${esc(src)}" data-repo="1" onclick="filterMktBySource('${esc(src)}')">${esc(src)} (${cnt})</button>`;
    }
    h += '</div>';
    h += '<div class="grid" id="mkt-grid">';
    h += renderMktCards(allSkills);
    h += '</div>';
    el.innerHTML = h;
    window._mktSource = 'all';
  }).catch(e => { el.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function filterMktBySource(src) {
  window._mktSource = src;
  document.querySelectorAll('[data-src]').forEach(btn => {
    const isActive = btn.dataset.src === src;
    const isRepo = btn.dataset.repo === '1';
    if (isActive) {
      btn.style.borderColor = 'var(--accent)';
      btn.style.color = 'var(--accent)';
    } else {
      btn.style.borderColor = isRepo ? 'var(--green)' : '';
      btn.style.color = isRepo ? 'var(--green)' : '';
    }
  });
  filterMkt();
}

function filterMkt() {
  const grid = document.getElementById('mkt-grid');
  if (!grid || !window._mktSkills) return;
  const q = (document.getElementById('mkt-search')?.value || '').toLowerCase();
  const src = window._mktSource || 'all';
  let filtered = window._mktSkills;
  if (src !== 'all') filtered = filtered.filter(s => s.source === src);
  if (q) filtered = filtered.filter(s => s.name.toLowerCase().includes(q) || s.source.toLowerCase().includes(q));
  grid.innerHTML = renderMktCards(filtered);
}

 function loadDiscoverTab() {
  const el = document.getElementById('install-content');
  fetch('/api/skills/discover').then(r=>r.json()).then(discovered => {
    if (!discovered.length) {
      el.innerHTML = `<div class="empty" style="padding:40px 20px">
        <svg viewBox="0 0 24 24" fill="none" stroke="var(--text3)" stroke-width="1.5" style="width:48px;height:48px;margin-bottom:12px"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg>
        <div style="margin-top:8px">No unmanaged skills found.</div>
        <div style="font-size:.78rem;color:var(--text3);margin-top:4px">All skills on your system are already managed.</div>
      </div>`;
      return;
    }
    window._discovered = discovered;
    window._discoverFilter = 'all';
    window._selectedDiscover = null;
    const toolSet = {};
    discovered.forEach(d => { toolSet[d.tool] = (toolSet[d.tool]||0) + 1; });
    const tools = Object.entries(toolSet).sort((a,b) => b[1]-a[1]);

    let h = '<div class="split-view">';
    // Left: list
    h += '<div class="list-panel">';
    h += `<div style="padding:8px 10px;font-size:.78rem;color:var(--text2);border-bottom:1px solid var(--border)">${discovered.length} unmanaged skill${discovered.length!==1?'s':''}</div>`;
    if (tools.length > 1) {
      h += `<div id="discover-filters" style="display:flex;gap:4px;padding:4px 10px;flex-wrap:wrap;border-bottom:1px solid var(--border)">`;
      h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px;background:var(--accent);color:#fff" data-dtool="all" onclick="filterDiscover('all')">All (${discovered.length})</button>`;
      for (const [tool, cnt] of tools) {
        h += `<button class="btn btn-sm" style="font-size:.66rem;padding:2px 8px" data-dtool="${esc(tool)}" onclick="filterDiscover('${esc(tool)}')">${esc(tool)} (${cnt})</button>`;
      }
      h += '</div>';
    }
    h += '<div class="list-scroll" id="discover-list">';
    h += renderDiscoverRows(discovered);
    h += '</div></div>';
    // Right: detail
    h += '<div class="detail-panel" id="discover-detail"><div class="empty" style="padding:40px 20px;font-size:.84rem;color:var(--text3)">Select a skill to view details</div></div>';
    h += '</div>';
    el.innerHTML = h;
  }).catch(e => { el.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function renderDiscoverRows(items) {
  if (!items.length) return '<div class="empty" style="padding:20px;font-size:.82rem">No skills match this filter.</div>';
  let h = '';
  for (const d of items) {
    const name = d.nameGuess || d.foundPath.split('/').pop();
    const iconKey = d.tool.replace(/_/g, '-');
    const sel = window._selectedDiscover === d.id;
    h += `<div class="list-row${sel?' active':''}" data-did="${esc(d.id)}" onclick="selectDiscoverRow('${esc(d.id)}')">
      <span class="row-icon">${svg(iconKey)}</span>
      <div style="flex:1;min-width:0"><div class="row-name">${esc(name)}</div>
        <div class="row-meta">${esc(d.tool)}</div></div>
      <button class="btn btn-sm" style="font-size:.68rem;flex-shrink:0" onclick="event.stopPropagation();importDiscovered('${esc(d.id)}')">Import</button>
    </div>`;
  }
  return h;
}

function selectDiscoverRow(id) {
  window._selectedDiscover = id;
  document.querySelectorAll('#discover-list .list-row').forEach(r => {
    r.classList.toggle('active', r.dataset.did === id);
  });
  const d = (window._discovered || []).find(x => x.id === id);
  if (!d) return;
  renderDiscoverDetail(d);
}

function renderDiscoverDetail(d) {
  const dp = document.getElementById('discover-detail');
  if (!dp) return;
  const name = d.nameGuess || d.foundPath.split('/').pop();
  let h = '<div style="padding:16px">';
  h += `<h2 style="margin:0 0 12px 0;font-size:1.1rem">${esc(name)}</h2>`;
  h += `<div class="kv"><span class="kv-k">Tool</span><span class="kv-v">${esc(d.tool)}</span></div>`;
  h += `<div class="kv"><span class="kv-k">Path</span><span class="kv-v code" style="word-break:break-all">${esc(d.foundPath)}</span></div>`;
  if (d.fingerprint) h += `<div class="kv"><span class="kv-k">Fingerprint</span><span class="kv-v code" style="font-size:.7rem">${esc(d.fingerprint)}</span></div>`;
  h += `<div class="kv"><span class="kv-k">Found</span><span class="kv-v">${new Date(d.foundAt).toLocaleString()}</span></div>`;
  h += `<div style="margin:14px 0"><button class="btn" onclick="importDiscovered('${esc(d.id)}')">Import to Library</button></div>`;
  h += '<div id="discover-detail-content"><span class="spinner"></span> Loading content...</div>';
  h += '</div>';
  dp.innerHTML = h;
  // Load SKILL.md content
  fetch('/api/skills/preview-path?path=' + encodeURIComponent(d.foundPath))
    .then(r => r.ok ? r.json() : null)
    .then(data => {
      const cel = document.getElementById('discover-detail-content');
      if (!cel) return;
      if (data && data.content) {
        cel.innerHTML = '<div style="background:var(--surface);border-radius:6px;padding:12px;overflow-y:auto;max-height:400px;font-size:.82rem">' + renderMarkdown(data.content) + '</div>';
      } else {
        cel.innerHTML = '<div style="color:var(--text3);font-size:.82rem">No skill description available.</div>';
      }
    })
    .catch(() => {
      const cel = document.getElementById('discover-detail-content');
      if (cel) cel.innerHTML = '<div style="color:var(--text3);font-size:.82rem">No skill description available.</div>';
    });
}

function filterDiscover(tool) {
  window._discoverFilter = tool;
  document.querySelectorAll('[data-dtool]').forEach(btn => {
    const active = btn.dataset.dtool === tool;
    btn.style.background = active ? 'var(--accent)' : '';
    btn.style.color = active ? '#fff' : '';
  });
  const list = document.getElementById('discover-list');
  if (!list || !window._discovered) return;
  const filtered = tool === 'all' ? window._discovered : window._discovered.filter(d => d.tool === tool);
  list.innerHTML = renderDiscoverRows(filtered);
}

function renderDiscoverCards(discovered) {
  let h = '';
  for (const d of discovered) {
    const imported = d.importedSkillId;
    const name = d.nameGuess || d.foundPath.split('/').pop();
    h += `<div class="card" style="cursor:pointer" id="discover-${esc(d.id)}" onclick="showDiscoverDetail(${esc(JSON.stringify(JSON.stringify(d)))})">
      <div class="card-hd">
        <div class="card-icon" style="background:rgba(59,130,246,.1)"><svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg></div>
        <div class="card-body"><h2>${esc(name)}</h2>
          <div class="meta" style="font-size:.72rem;color:var(--text3)">${esc(d.tool)} \u00b7 ${esc(shortPath(d.foundPath))}</div>
        </div>
      </div>
      <div style="margin-top:8px" id="discover-action-${esc(d.id)}">${imported
        ? '<span style="font-size:.78rem;color:var(--green);font-weight:500">\u2713 Imported</span>'
        : `<button class="btn btn-sm" onclick="event.stopPropagation();importDiscovered('${esc(d.id)}')">Import</button>`
      }</div>
    </div>`;
  }
  return h || '<div class="empty">No skills match this filter.</div>';
}

function loadManualInstallTab() {
  const el = document.getElementById('install-content');
  el.innerHTML = `<section class="section">
    <h3>Install from Git</h3>
    <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
      <input class="path-input" id="git-url" placeholder="https://github.com/user/repo" style="flex:1">
      <button class="btn" onclick="installFromGit()">Install</button>
    </div>
    <p style="font-size:.72rem;color:var(--text3);margin-top:8px">Supports GitHub, GitLab, and any public git repository.</p>
  </section>
  <section class="section" style="margin-top:14px">
    <h3>Install from Local Path</h3>
    <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
      <input class="path-input" id="local-path" placeholder="/path/to/skill/directory" style="flex:1">
      <button class="btn" onclick="installFromLocal()">Install</button>
    </div>
  </section>`;
}

function installFromGit() {
  const url = document.getElementById('git-url').value.trim();
  if (!url) return;
  fetch('/api/skills/install', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({source:url,source_type:'git'})})
    .then(r=>r.json()).then(result => {
      if (result.error) { toast('Install failed: ' + result.error, 'error'); return; }
      location.hash = '#/skills';
    }).catch(e => toast('Install failed: ' + e, 'error'));
}

function installFromLocal() {
  const path = document.getElementById('local-path').value.trim();
  if (!path) return;
  fetch('/api/skills/install', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({source:path,source_type:'local'})})
    .then(r=>r.json()).then(result => {
      if (result.error) { toast('Install failed: ' + result.error, 'error'); return; }
      location.hash = '#/skills';
    }).catch(e => toast('Install failed: ' + e, 'error'));
}

function importDiscovered(id) {
  const actionEl = document.getElementById('discover-action-' + id);
  if (actionEl) actionEl.innerHTML = '<span class="spinner"></span> Importing...';
  fetch('/api/skills/import', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({discovered_id:id})})
    .then(r=>r.json()).then(result => {
      if (result.error) { if (actionEl) actionEl.innerHTML = `<span style="color:var(--red);font-size:.78rem">${esc(result.error)}</span>`; return; }
      toast('Imported successfully', 'success');
      loadDiscoverTab();
    }).catch(e => { if (actionEl) actionEl.innerHTML = `<span style="color:var(--red);font-size:.78rem">Error: ${esc(String(e))}</span>`; });
}

function renderMktCards(skills) {
  if (!skills.length) return '<div class="empty">No skills found</div>';
  const maxI = window._mktMaxInstalls || 1;
  const installed = window._installedSources || new Set();
  let h = '';
  for (const s of skills) {
    const data = esc(JSON.stringify(s));
    const isRepo = s._isRepo;
    const gitUrl = isRepo ? s._repoUrl : ('https://github.com/' + s.source);
    const isInstalled = installed.has(gitUrl) || installed.has(gitUrl + '.git');
    const pct = Math.max(2, Math.round(((s.installs||0) / maxI) * 100));
    h += `<div class="card" onclick='showSkillModal(${data})'>
      <div class="card-hd">
        <div class="card-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M8 12l2 2 4-4"/></svg></div>
        <div class="card-body"><h2>${esc(s.name)} ${isInstalled ? '<span class="installed-badge">\u2713 Installed</span>' : ''}</h2>
          <div class="meta" style="font-size:.72rem;color:var(--text3)">${esc(isRepo ? (s._description || s.source) : s.source)}</div>
        </div>
      </div>
      ${isRepo
        ? `<div style="font-size:.68rem;color:var(--text3);margin-top:6px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(s._repoUrl)}</div>`
        : `<div class="mkt-installs"><span>${(s.installs||0).toLocaleString()} installs</span><div class="mkt-bar"><div class="mkt-bar-fill" style="width:${pct}%"></div></div></div>`}
    </div>`;
  }
  return h;
}

function showSkillModal(skill) {
  let overlay = document.getElementById('modal-overlay');
  if (overlay) overlay.remove();
  const isRepo = skill._isRepo;
  const gitUrl = isRepo ? skill._repoUrl : ('https://github.com/' + skill.source + (skill.skillId ? '/' : ''));
  const isInstalled = isRepo ? false : ((window._installedSources || new Set()).has('https://github.com/' + skill.source) ||
                      (window._installedSources || new Set()).has('https://github.com/' + skill.source + '.git'));
  let h = `<div class="modal-overlay" onclick="if(event.target===this)this.remove()">
    <div class="modal">
      <div class="modal-hdr"><h2>${esc(skill.name)}</h2><button class="modal-close" onclick="this.closest('.modal-overlay').remove()">\u{00D7}</button></div>
      <div class="kv"><span class="kv-k">Source</span><span class="kv-v code">${esc(isRepo ? skill._repoUrl : skill.source)}</span></div>
      ${isRepo ? `<div class="kv"><span class="kv-k">Path</span><span class="kv-v code">${esc(skill._repoPath)}</span></div>` : `<div class="kv"><span class="kv-k">Skill ID</span><span class="kv-v code">${esc(skill.skillId || skill.name)}</span></div>`}
      ${!isRepo ? `<div class="kv"><span class="kv-k">Installs</span><span class="kv-v">${(skill.installs||0).toLocaleString()}</span></div>` : ''}
      ${skill._description ? `<div class="kv"><span class="kv-k">Description</span><span class="kv-v">${esc(skill._description)}</span></div>` : ''}
      <div class="kv"><span class="kv-k">Repository</span><span class="kv-v"><a href="${esc(gitUrl)}" target="_blank" style="color:var(--accent)">${esc(gitUrl)}</a></span></div>
      ${isInstalled ? '<div style="margin-top:12px"><span class="installed-badge" style="font-size:.78rem;padding:3px 10px">\u2713 Already installed</span></div>' : ''}
      <div id="mkt-readme" style="margin-top:12px"><span class="spinner"></span> Loading README...</div>
      <div style="display:flex;gap:8px;margin-top:16px">
        ${isInstalled ? '' : (isRepo
          ? `<button class="btn btn-green" style="flex:1" onclick="installRepoSkillFromModal('${esc(skill._repoUrl)}','${esc(skill._repoPath)}','${esc(skill.name)}')">Install</button>`
          : `<button class="btn btn-green" style="flex:1" onclick="installMktSkill('${esc(skill.source)}','${esc(skill.skillId)}')">Install</button>`)}
        <button class="btn" onclick="this.closest('.modal-overlay').remove()">${isInstalled ? 'Close' : 'Cancel'}</button>
      </div>
      <div id="install-status" style="margin-top:10px;font-size:.78rem;color:var(--text3)"></div>
    </div>
  </div>`;
  document.body.insertAdjacentHTML('beforeend', h);
  // Fetch README
  if (isRepo) {
    // For repo skills, try GitHub API using repo URL
    const match = skill._repoUrl.match(/github\.com\/([^/]+)\/([^/.]+)/);
    if (match) {
      fetch(`https://api.github.com/repos/${match[1]}/${match[2]}/readme`, {headers:{'Accept':'application/vnd.github.v3.raw'}})
        .then(r => r.ok ? r.text() : null).then(text => {
          const el = document.getElementById('mkt-readme');
          if (!el) return;
          if (text) { const preview = text.length > 2000 ? text.substring(0, 2000) + '\n...' : text; el.innerHTML = '<div style="max-height:250px;overflow-y:auto;padding:12px;background:var(--elevated);border-radius:6px;font-size:.76rem;white-space:pre-wrap;font-family:var(--mono);line-height:1.5">' + esc(preview) + '</div>'; }
          else { el.innerHTML = '<div style="color:var(--text3);font-size:.78rem">No README available.</div>'; }
        }).catch(() => { const el = document.getElementById('mkt-readme'); if (el) el.innerHTML = ''; });
    } else { const el = document.getElementById('mkt-readme'); if (el) el.innerHTML = ''; }
  } else {
    const [owner, repo] = skill.source.split('/');
    if (owner && repo) {
      fetch(`https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/readme`, {headers:{'Accept':'application/vnd.github.v3.raw'}})
        .then(r => r.ok ? r.text() : null).then(text => {
          const el = document.getElementById('mkt-readme');
          if (!el) return;
          if (text) { const preview = text.length > 2000 ? text.substring(0, 2000) + '\n...' : text; el.innerHTML = '<div style="max-height:250px;overflow-y:auto;padding:12px;background:var(--elevated);border-radius:6px;font-size:.76rem;white-space:pre-wrap;font-family:var(--mono);line-height:1.5">' + esc(preview) + '</div>'; }
          else { el.innerHTML = '<div style="color:var(--text3);font-size:.78rem">No README available.</div>'; }
        }).catch(() => { const el = document.getElementById('mkt-readme'); if (el) el.innerHTML = '<div style="color:var(--text3);font-size:.78rem">Could not load README.</div>'; });
    }
  }
}

function installRepoSkillFromModal(repoUrl, skillPath, name) {
  const el = document.getElementById('install-status');
  if (el) el.innerHTML = '<span class="spinner"></span> Installing...';
  fetch('/api/skills/marketplace/repos/install', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({repo_url:repoUrl,skill_path:skillPath,name:name})})
    .then(r=>r.json()).then(result => {
      if (result.error) { if (el) el.innerHTML = '<span style="color:var(--red)">Failed: ' + esc(result.error) + '</span>'; return; }
      const overlay = document.querySelector('.modal-overlay');
      if (overlay) overlay.remove();
      toast('Skill installed successfully', 'success');
      location.hash = '#/skills';
    }).catch(e => { if (el) el.innerHTML = '<span style="color:var(--red)">Error: ' + esc(String(e)) + '</span>'; });
}

function installMktSkill(source, skillId) {
  const el = document.getElementById('install-status');
  if (el) el.innerHTML = '<span class="spinner"></span> Installing...';
  const url = 'https://github.com/' + source + '/' + skillId;
  fetch('/api/skills/install', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({source:url,source_type:'git'})})
    .then(r=>r.json()).then(result => {
      if (result.error) { if (el) el.innerHTML = '<span style="color:var(--red)">Failed: ' + esc(result.error) + '</span>'; return; }
      const overlay = document.querySelector('.modal-overlay');
      if (overlay) overlay.remove();
      toast('Skill installed successfully', 'success');
      location.hash = '#/skills';
    }).catch(e => { if (el) el.innerHTML = '<span style="color:var(--red)">Error: ' + esc(String(e)) + '</span>'; });
}

function searchMkt() {
  const q = document.getElementById('mkt-search').value.trim();
  if (!q) return;
  const grid = document.getElementById('mkt-grid');
  if (grid) grid.innerHTML = '<div class="empty"><span class="spinner"></span> Searching...</div>';
  fetch(`/api/skills/marketplace/search?q=${encodeURIComponent(q)}&limit=20`).then(r=>r.json()).then(skills => {
    if (grid) grid.innerHTML = renderMktCards(skills);
  });
}

// ── Tools Config ──

function renderToolsConfig() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading tools configuration...</div>';
  fetch('/api/skills/tools').then(r=>r.json()).then(tools => {
    let h = `<div class="page-hdr"><h1>Coding Tools</h1></div>`;
    h += `<p style="color:var(--text2);margin-bottom:16px;font-size:.84rem">Manage which coding tools sync with your skill library. Only detected and custom tools are shown.</p>`;

    const detected = tools.filter(t => t.installed);
    const custom = tools.filter(t => t.isCustom);
    const shown = [...detected, ...custom.filter(c => !detected.find(d => d.key === c.key))];

    if (shown.length) {
      h += `<section class="section" style="margin-bottom:14px"><h3>Active Tools (${shown.length})</h3>`;
      for (const t of shown) {
        h += renderToolConfigRow(t, true);
      }
      h += '</section>';
    } else {
      h += '<div class="empty">No coding tools detected on this system.</div>';
    }

    // Add custom tool
    h += `<section class="section"><h3>Add Custom Tool</h3>
      <div style="display:flex;gap:8px;align-items:flex-end;flex-wrap:wrap;margin-top:8px">
        <div style="flex:1;min-width:120px">
          <label style="font-size:.68rem;color:var(--text3);display:block;margin-bottom:4px">Name</label>
          <input class="path-input" id="custom-tool-name" placeholder="My Tool" style="width:100%">
        </div>
        <div style="flex:2;min-width:200px">
          <label style="font-size:.68rem;color:var(--text3);display:block;margin-bottom:4px">Skills Path</label>
          <div style="display:flex;gap:4px">
            <input class="path-input" id="custom-tool-path" placeholder="~/.mytool/skills" style="flex:1">
            <button class="btn btn-sm" onclick="pickFolder('custom-tool-path')" title="Browse" style="white-space:nowrap">${SI.folder || '\u{1F4C2}'}</button>
          </div>
        </div>
        <div style="min-width:80px">
          <label style="font-size:.68rem;color:var(--text3);display:block;margin-bottom:4px">Icon (PNG)</label>
          <label class="btn btn-sm" style="cursor:pointer;display:inline-flex;align-items:center;gap:4px;font-size:.72rem">
            <span style="width:14px;height:14px;display:inline-flex">${SI.upload || '\u{2B06}'}</span>Choose
            <input type="file" id="custom-tool-icon" accept="image/png" style="display:none" onchange="previewIcon(this)">
          </label>
          <span id="icon-preview-name" style="font-size:.68rem;color:var(--text3);margin-left:4px"></span>
        </div>
        <button class="btn" onclick="addCustomTool()">Add Tool</button>
      </div>
    </section>`;

    app.innerHTML = h;
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function renderToolConfigRow(t, showPath) {
  const isEnabled = t.enabled !== false;
  const iconKey = t.key.replace(/_/g, '-');
  const icon = svg(iconKey, '');
  const customBadge = t.isCustom ? '<span class="ver" style="background:rgba(168,85,247,.1);color:#a855f7">custom</span>' : '';
  return `<div class="tool-cfg-row">
    <div class="tool-cfg-name">${icon} ${esc(t.displayName)} ${customBadge}</div>
    <div class="tool-cfg-path">${esc(shortPath(t.configPath || t.skillsPath || ''))}</div>
    <div class="tool-cfg-actions">
      ${t.isCustom ? `<button class="btn btn-sm btn-warn" onclick="removeCustomTool('${esc(t.key)}')" title="Remove">\u{00D7}</button>` : ''}
      <label class="toggle"><input type="checkbox" ${isEnabled ? 'checked' : ''} onchange="toggleTool('${esc(t.key)}', this.checked)"><span class="slider"></span></label>
    </div>
  </div>`;
}

function previewIcon(input) {
  const span = document.getElementById('icon-preview-name');
  if (input.files && input.files[0]) {
    span.textContent = input.files[0].name;
    window._customIconFile = input.files[0];
  } else {
    span.textContent = '';
    window._customIconFile = null;
  }
}

function addCustomTool() {
  const name = document.getElementById('custom-tool-name').value.trim();
  const path = document.getElementById('custom-tool-path').value.trim();
  if (!name || !path) { toast('Name and skills path are required', 'error'); return; }
  const key = name.toLowerCase().replace(/[^a-z0-9]+/g, '_');

  const doAdd = () => fetch('/api/skills/tools-custom', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key,display_name:name,skills_dir:path})})
    .then(r => { if (!r.ok) return r.json().then(d => { throw new Error(d.error); }); renderToolsConfig(); })
    .catch(e => toast('Failed to add: ' + e, 'error'));

  if (window._customIconFile) {
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = reader.result.split(',')[1];
      fetch('/api/icons/upload', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key,icon:base64})})
        .then(r => { if (!r.ok) throw new Error('Icon upload failed'); return doAdd(); })
        .catch(e => toast('Icon upload failed: ' + e, 'error'));
    };
    reader.readAsDataURL(window._customIconFile);
  } else {
    doAdd();
  }
}

function removeCustomTool(key) {
  if (!confirm('Remove this custom tool?')) return;
  fetch('/api/skills/tools-custom/' + encodeURIComponent(key), {method:'DELETE'})
    .then(r => { if (!r.ok) throw new Error('Failed'); renderToolsConfig(); })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function toggleTool(key, enabled) {
  fetch('/api/skills/tools/' + encodeURIComponent(key), {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled})})
    .then(r => { if (!r.ok) throw new Error('Failed'); })
    .catch(e => { toast('Failed: ' + e, 'error'); renderToolsConfig(); });
}

function setAllToolsEnabled(enabled) {
  fetch('/api/skills/tools-enable-all', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled})})
    .then(() => renderToolsConfig())
    .catch(e => toast('Failed: ' + e, 'error'));
}

// ── Scenarios ──

window._scenarioSelectedId = null;
window._scenarioSkillFilter = 'in';
window._scenarioSkillSearch = '';

function renderScenarios() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading scenarios...</div>';
  fetch('/api/skills/scenarios').then(r=>r.json()).then(scenarios => {
    if (!scenarios.length) {
      return fetch('/api/skills/scenarios', {method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({name:'Default'})})
        .then(r=>r.json()).then(() => fetch('/api/skills/scenarios').then(r=>r.json()));
    }
    return scenarios;
  }).then(scenarios => {
    if (!window._scenarioSelectedId && scenarios.length) {
      window._scenarioSelectedId = scenarios[0].id;
    }
    let h = '<div class="split-view">';
    h += '<div class="list-panel" style="width:210px;min-width:160px">';
    h += `<div class="list-toolbar">
      <span style="flex:1;font-weight:600;font-size:.84rem">Scenarios</span>
      <button class="tb-btn" onclick="createScenarioPrompt()" title="New Scenario">${SI.plus}</button>
      <button class="tb-btn" onclick="renderScenarios()" title="Refresh">${SI.refresh}</button>
    </div>`;
    h += '<div class="list-scroll" id="scenario-list">';
    for (const s of scenarios) {
      const active = s.id === window._scenarioSelectedId ? ' active' : '';
      const badge = s.isActive ? '<span class="status-badge status-on" style="font-size:.6rem;padding:1px 5px;margin-left:6px">ACTIVE</span>' : '';
      h += `<div class="list-row${active}" data-id="${esc(s.id)}" onclick="selectScenarioRow('${esc(s.id)}')">
        <span style="font-size:1rem;flex-shrink:0">${esc(s.icon || '\u{1F4CB}')}</span>
        <span class="row-name">${esc(s.name)}${badge}</span>
        <span class="row-extra">${s.skillCount}</span>
      </div>`;
    }
    h += '</div></div>';
    h += '<div class="detail-panel" id="scenario-detail">';
    h += '<div class="empty" style="padding:60px 20px;color:var(--text3)">Select a scenario</div>';
    h += '</div></div>';
    app.innerHTML = h;
    if (window._scenarioSelectedId) selectScenarioRow(window._scenarioSelectedId);
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function selectScenarioRow(id) {
  window._scenarioSelectedId = id;
  document.querySelectorAll('#scenario-list .list-row').forEach(r => {
    r.classList.toggle('active', r.dataset.id === id);
  });
  renderScenarioDetailPanel(id);
}

function renderScenarioDetailPanel(id) {
  const dp = document.getElementById('scenario-detail');
  if (!dp) return;
  dp.innerHTML = '<div class="empty"><span class="spinner"></span></div>';
  Promise.all([
    fetch(`/api/skills/scenarios/${encodeURIComponent(id)}`).then(r=>r.json()),
    fetch('/api/skills').then(r=>r.json())
  ]).then(([detail, allSkills]) => {
    const s = detail.scenario;
    const inIds = new Set(detail.skills.map(sk => sk.id));
    const isDefault = s.name === 'Default';
    let h = '';

    // Header
    h += `<div style="display:flex;align-items:center;gap:12px;margin-bottom:4px">
      <span style="font-size:1.5rem">${esc(s.icon || '\u{1F4CB}')}</span>
      <span class="dp-title sc-editable" contenteditable="true" data-field="name" data-id="${esc(s.id)}"
        onblur="saveScenarioField(this)" onkeydown="if(event.key==='Enter'){event.preventDefault();this.blur()}"
      >${esc(s.name)}</span>
      ${s.isActive
        ? '<span class="status-badge status-on" style="margin-left:auto">ACTIVE</span>'
        : `<button class="btn btn-sm btn-green" style="margin-left:auto" onclick="activateScenario('${esc(s.id)}')">Activate</button>`}
    </div>`;
    h += `<div class="sc-editable dp-desc" contenteditable="true" data-field="description" data-id="${esc(s.id)}"
      style="min-height:1.4em;color:var(--text2);font-size:.88rem;margin-bottom:20px;outline:none;border-bottom:1px solid transparent;cursor:text"
      data-placeholder="Add description..."
      onblur="saveScenarioField(this)" onkeydown="if(event.key==='Enter'){event.preventDefault();this.blur()}"
    >${esc(s.description || '')}</div>`;

    // Skills filter bar
    h += `<div style="display:flex;gap:8px;align-items:center;margin-bottom:12px">
      <input type="text" id="sc-skill-search" placeholder="Search skills..." value="${esc(window._scenarioSkillSearch)}"
        oninput="window._scenarioSkillSearch=this.value;renderScenarioSkillList('${esc(s.id)}')"
        style="flex:1;padding:7px 12px;background:var(--elevated);border:1px solid transparent;border-radius:8px;color:var(--text);font-size:.84rem;font-family:inherit">
      <button class="btn btn-sm" id="sc-pill-in" style="font-size:.72rem;padding:3px 10px;${window._scenarioSkillFilter==='in'?'background:var(--accent);color:#fff;':''}"
        onclick="window._scenarioSkillFilter='in';renderScenarioSkillList('${esc(s.id)}')">In Scenario</button>
      <button class="btn btn-sm" id="sc-pill-avail" style="font-size:.72rem;padding:3px 10px;${window._scenarioSkillFilter==='available'?'background:var(--accent);color:#fff;':''}"
        onclick="window._scenarioSkillFilter='available';renderScenarioSkillList('${esc(s.id)}')">Available</button>
    </div>`;

    h += `<div id="sc-skill-list" style="overflow:hidden;min-width:0"></div>`;

    // Delete button
    if (!isDefault) {
      h += `<div style="margin-top:32px;border-top:1px solid var(--border);padding-top:16px">
        <button class="btn btn-warn" onclick="deleteScenario('${esc(s.id)}','${esc(s.name)}')">Delete Scenario</button>
      </div>`;
    }

    dp.innerHTML = h;

    // Placeholder styling for empty contenteditable
    dp.querySelectorAll('.sc-editable[data-placeholder]').forEach(el => {
      if (!el.textContent.trim()) el.classList.add('sc-empty');
      el.addEventListener('focus', () => el.classList.remove('sc-empty'));
      el.addEventListener('blur', () => { if (!el.textContent.trim()) el.classList.add('sc-empty'); });
    });

    // Store data for skill list rendering
    window._scenarioDetail = detail;
    window._scenarioAllSkills = allSkills;
    renderScenarioSkillList(s.id);
  }).catch(e => { dp.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function renderScenarioSkillList(scenarioId) {
  const container = document.getElementById('sc-skill-list');
  if (!container) return;
  const detail = window._scenarioDetail;
  const allSkills = window._scenarioAllSkills;
  if (!detail || !allSkills) return;
  const inIds = new Set(detail.skills.map(sk => sk.id));
  const q = (window._scenarioSkillSearch || '').toLowerCase();
  const filter = window._scenarioSkillFilter || 'in';

  let skills;
  if (filter === 'in') {
    skills = detail.skills.filter(sk => !q || sk.name.toLowerCase().includes(q));
  } else {
    skills = allSkills.filter(sk => !inIds.has(sk.id) && (!q || sk.name.toLowerCase().includes(q)));
  }
  skills.sort((a,b) => (a.name||'').localeCompare(b.name||''));

  if (!skills.length) {
    container.innerHTML = `<div style="color:var(--text3);font-size:.82rem;padding:12px 0">${filter==='in' ? 'No skills in this scenario.' : 'No available skills.'}</div>`;
    return;
  }
  let h = '';
  for (const sk of skills) {
    const isIn = inIds.has(sk.id);
    h += `<div style="display:flex;align-items:center;gap:10px;padding:8px 4px;border-bottom:1px solid var(--border);overflow:hidden;${!isIn?'opacity:.6':''}">
      <div style="flex:1;width:0;overflow:hidden">
        <div style="font-weight:500;font-size:.84rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(sk.name)}</div>
        ${sk.description ? `<div style="font-size:.72rem;color:var(--text3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(sk.description)}</div>` : ''}
      </div>
      ${isIn
        ? `<button class="btn btn-sm" style="flex-shrink:0;color:var(--green)" onclick="removeSkillFromScenario('${esc(scenarioId)}','${esc(sk.id)}')">\u{2713}</button>`
        : `<button class="btn btn-sm" style="flex-shrink:0" onclick="addSkillToScenario('${esc(scenarioId)}','${esc(sk.id)}')">+ Add</button>`}
    </div>`;
  }
  container.innerHTML = h;

  // Update pill highlights
  const pillIn = document.getElementById('sc-pill-in');
  const pillAvail = document.getElementById('sc-pill-avail');
  if (pillIn) pillIn.style.cssText = `font-size:.72rem;padding:3px 10px;${filter==='in'?'background:var(--accent);color:#fff;':''}`;
  if (pillAvail) pillAvail.style.cssText = `font-size:.72rem;padding:3px 10px;${filter==='available'?'background:var(--accent);color:#fff;':''}`;
}

function saveScenarioField(el) {
  const id = el.dataset.id;
  const field = el.dataset.field;
  const value = el.textContent.trim();
  if (!value && field === 'name') {
    renderScenarioDetailPanel(id);
    return;
  }
  const body = {};
  body[field] = value || '';
  fetch(`/api/skills/scenarios/${encodeURIComponent(id)}`, {method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
    .then(r => { if (!r.ok) throw new Error('Save failed'); return r.json(); })
    .then(() => {
      toast('Saved', 'success');
      refreshScenarioList();
    })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function refreshScenarioList() {
  fetch('/api/skills/scenarios').then(r=>r.json()).then(scenarios => {
    const container = document.getElementById('scenario-list');
    if (!container) return;
    let h = '';
    for (const s of scenarios) {
      const active = s.id === window._scenarioSelectedId ? ' active' : '';
      const badge = s.isActive ? '<span class="status-badge status-on" style="font-size:.6rem;padding:1px 5px;margin-left:6px">ACTIVE</span>' : '';
      h += `<div class="list-row${active}" data-id="${esc(s.id)}" onclick="selectScenarioRow('${esc(s.id)}')">
        <span style="font-size:1rem;flex-shrink:0">${esc(s.icon || '\u{1F4CB}')}</span>
        <span class="row-name">${esc(s.name)}${badge}</span>
        <span class="row-extra">${s.skillCount}</span>
      </div>`;
    }
    container.innerHTML = h;
  });
}

function createScenarioPrompt() {
  const name = prompt('Scenario name:');
  if (!name) return;
  const desc = prompt('Description (optional):');
  fetch('/api/skills/scenarios', {method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({name, description:desc||undefined})})
    .then(r=>r.json()).then(s => {
      if (s.error) { toast(s.error, 'error'); return; }
      window._scenarioSelectedId = s.id;
      renderScenarios();
    }).catch(e => toast('Failed: ' + e, 'error'));
}

function activateScenario(id) {
  fetch(`/api/skills/scenarios/${encodeURIComponent(id)}/activate`, {method:'POST'})
    .then(() => {
      refreshScenarioList();
      renderScenarioDetailPanel(id);
    })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function deleteScenario(id, name) {
  if (!confirm(`Delete scenario "${name}"?`)) return;
  fetch(`/api/skills/scenarios/${encodeURIComponent(id)}`, {method:'DELETE'})
    .then(() => {
      if (window._scenarioSelectedId === id) window._scenarioSelectedId = null;
      renderScenarios();
    })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function addSkillToScenario(scenarioId, skillId) {
  fetch(`/api/skills/scenarios/${encodeURIComponent(scenarioId)}/add-skill`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({skill_id:skillId})})
    .then(() => {
      refreshScenarioList();
      renderScenarioDetailPanel(scenarioId);
    })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function removeSkillFromScenario(scenarioId, skillId) {
  fetch(`/api/skills/scenarios/${encodeURIComponent(scenarioId)}/remove-skill`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({skill_id:skillId})})
    .then(() => {
      refreshScenarioList();
      renderScenarioDetailPanel(scenarioId);
    })
    .catch(e => toast('Failed: ' + e, 'error'));
}

// ── Backup ──

function renderBackup() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading backup status...</div>';
  fetch('/api/skills/backup/status').then(r=>r.json()).then(status => {
    let h = '';

    if (!status.isRepo) {
      h += `<div class="section" style="text-align:center;padding:40px 20px">
        <h3 style="margin-bottom:12px">Git Backup Not Initialized</h3>
        <p style="color:var(--text2);margin-bottom:16px;font-size:.84rem">Initialize a git repository in your skills directory to enable version control and remote backup.</p>
        <button class="btn" onclick="initBackup()">Initialize Git Backup</button>
        <div style="margin-top:16px"><span style="font-size:.78rem;color:var(--text3)">or</span></div>
        <div style="margin-top:8px"><button class="btn btn-sm" onclick="cloneBackupPrompt()">Clone from Remote</button></div>
      </div>`;
      app.innerHTML = h;
      return;
    }

    // Status section
    h += `<section class="section" style="margin-bottom:14px"><h3>Repository Status</h3>`;
    h += `<div class="kv"><span class="kv-k">Branch</span><span class="kv-v code">${esc(status.branch || 'unknown')}</span></div>`;
    h += `<div class="kv"><span class="kv-k">Changes</span><span class="kv-v" style="color:${status.hasChanges ? 'var(--red)' : 'var(--green)'}">${status.hasChanges ? 'Uncommitted changes' : 'Clean'}</span></div>`;
    if (status.remoteURL) {
      h += `<div class="kv"><span class="kv-k">Remote</span><span class="kv-v code">${esc(status.remoteURL)}</span></div>`;
      h += `<div class="kv"><span class="kv-k">Ahead/Behind</span><span class="kv-v">${status.ahead} ahead, ${status.behind} behind</span></div>`;
    }
    if (status.lastCommit) {
      h += `<div class="kv"><span class="kv-k">Last Commit</span><span class="kv-v">${esc(status.lastCommit)}</span></div>`;
    }
    if (status.currentSnapshotTag) {
      h += `<div class="kv"><span class="kv-k">Snapshot at HEAD</span><span class="kv-v code">${esc(status.currentSnapshotTag)}</span></div>`;
    }
    h += '</section>';

    // Actions
    h += `<section class="section" style="margin-bottom:14px"><h3>Actions</h3>
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px">`;
    if (status.hasChanges) {
      h += `<button class="btn btn-sm btn-green" onclick="commitBackup()">Commit Changes</button>`;
    }
    h += `<button class="btn btn-sm" onclick="snapshotBackup()">Create Snapshot</button>`;
    if (status.remoteURL) {
      h += `<button class="btn btn-sm" onclick="pushBackup()">Push</button>`;
      h += `<button class="btn btn-sm" onclick="pullBackup()">Pull</button>`;
    }
    h += `</div>`;

    // Remote config
    h += `<div style="display:flex;gap:8px;align-items:center">
      <input class="path-input" id="remote-url" placeholder="Remote URL (https://...)" value="${esc(status.remoteURL || '')}" style="flex:1">
      <button class="btn btn-sm" onclick="setRemoteURL()">Set Remote</button>
    </div></section>`;

    // Versions
    h += `<section class="section"><h3>Snapshots</h3><div id="versions-list">Loading...</div></section>`;

    app.innerHTML = h;
    loadVersions();
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function loadVersions() {
  const el = document.getElementById('versions-list');
  if (!el) return;
  fetch('/api/skills/backup/versions?limit=20').then(r=>r.json()).then(versions => {
    if (!versions.length) { el.innerHTML = '<div style="color:var(--text3);font-size:.82rem">No snapshots yet</div>'; return; }
    let h = '';
    for (const v of versions) {
      h += `<div style="display:flex;align-items:center;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--border);font-size:.82rem">
        <div>
          <span style="font-family:var(--mono);font-weight:500;color:var(--accent)">${esc(v.tag)}</span>
          <span style="color:var(--text3);margin-left:8px">${esc(v.commit)}</span>
          ${v.message ? `<div style="font-size:.72rem;color:var(--text3);margin-top:2px">${esc(v.message)}</div>` : ''}
        </div>
        <button class="btn btn-sm" onclick="restoreVersion('${esc(v.tag)}')">Restore</button>
      </div>`;
    }
    el.innerHTML = h;
  }).catch(e => { el.innerHTML = `<div style="color:var(--red);font-size:.82rem">Error: ${esc(String(e))}</div>`; });
}

function initBackup() {
  fetch('/api/skills/backup/init', {method:'POST'}).then(() => renderBackup()).catch(e => toast('Failed: ' + e, 'error'));
}

function commitBackup() {
  const msg = prompt('Commit message:', 'Update skill library');
  if (!msg) return;
  fetch('/api/skills/backup/commit', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:msg})})
    .then(r => { if (!r.ok) return r.json().then(d => { throw new Error(d.error); }); renderBackup(); })
    .catch(e => toast('Commit failed: ' + e, 'error'));
}

function snapshotBackup() {
  fetch('/api/skills/backup/snapshot', {method:'POST'}).then(r=>r.json()).then(d => {
    if (d.error) { toast(d.error, 'error'); return; }
    toast('Snapshot created: ' + (d.tag || 'ok'), 'success');
    renderBackup();
  }).catch(e => toast('Failed: ' + e, 'error'));
}

function pushBackup() {
  fetch('/api/skills/backup/push', {method:'POST'}).then(r => {
    if (!r.ok) return r.json().then(d => { throw new Error(d.error); });
    toast('Pushed successfully', 'success'); renderBackup();
  }).catch(e => toast('Push failed: ' + e, 'error'));
}

function pullBackup() {
  fetch('/api/skills/backup/pull', {method:'POST'}).then(r => {
    if (!r.ok) return r.json().then(d => { throw new Error(d.error); });
    toast('Pulled successfully', 'success'); renderBackup();
  }).catch(e => toast('Pull failed: ' + e, 'error'));
}

function setRemoteURL() {
  const url = document.getElementById('remote-url').value.trim();
  if (!url) return;
  fetch('/api/skills/backup/remote', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url})})
    .then(r => { if (!r.ok) return r.json().then(d => { throw new Error(d.error); }); renderBackup(); })
    .catch(e => toast('Failed: ' + e, 'error'));
}

function cloneBackupPrompt() {
  const url = prompt('Remote URL to clone:');
  if (!url) return;
  fetch('/api/skills/backup/clone', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url})})
    .then(r => { if (!r.ok) return r.json().then(d => { throw new Error(d.error); }); toast('Cloned successfully', 'success'); renderBackup(); })
    .catch(e => toast('Clone failed: ' + e, 'error'));
}

function restoreVersion(tag) {
  if (!confirm(`Restore skills to snapshot "${tag}"? This will overwrite current state.`)) return;
  fetch('/api/skills/backup/restore', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tag})})
    .then(r => { if (!r.ok) return r.json().then(d => { throw new Error(d.error); }); toast('Restored to ' + tag, 'success'); renderBackup(); })
    .catch(e => toast('Restore failed: ' + e, 'error'));
}

// ── Projects ──

function renderProjects() {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading projects...</div>';
  fetch('/api/skills/projects').then(r=>r.json()).then(projects => {
    let html = '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">';
    html += '<h2 style="margin:0">Projects</h2>';
    html += '<div><button class="btn" onclick="addProjectPrompt()">+ Add Project</button> ';
    html += '<button class="btn" onclick="scanProjectsPrompt()">Scan</button></div></div>';
    if (!projects.length) {
      html += '<div class="empty">No projects yet. Add a project directory or scan for existing ones.</div>';
    } else {
      html += '<div class="grid">';
      for (const p of projects) {
        const icon = '\u{1F4C1}';
        const health = p.syncHealth || {};
        const total = (health.inSync||0)+(health.projectNewer||0)+(health.centerNewer||0)+(health.diverged||0)+(health.projectOnly||0);
        let statusHtml = '';
        if (health.diverged > 0) statusHtml = `<span style="display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;background:#fef2f2;color:#dc2626;font-weight:500">${health.diverged} diverged</span>`;
        else if ((health.projectNewer||0)+(health.centerNewer||0) > 0) { const n=(health.projectNewer||0)+(health.centerNewer||0); statusHtml = `<span style="display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;background:#fffbeb;color:#d97706;font-weight:500">${n} update${n>1?'s':''}</span>`; }
        else if (health.projectOnly > 0) statusHtml = `<span style="display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;background:#eff6ff;color:#2563eb;font-weight:500">${health.projectOnly} local</span>`;
        else if (total > 0) statusHtml = '<span style="display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;background:#f0fdf4;color:#16a34a;font-weight:500">\u2713 synced</span>';
        html += `<a class="card" href="#/skills-project/${esc(p.id)}" style="cursor:pointer">`;
        html += `<strong>${icon} ${esc(p.name)}</strong>`;
        html += `<div class="meta">${esc(p.path)}</div>`;
        html += `<div class="meta" style="display:flex;align-items:center;gap:6px">${p.skillCount} skills${statusHtml ? ' \u00b7 ' + statusHtml : ''}</div>`;
        html += `<div style="margin-top:6px"><button class="btn btn-sm" onclick="event.preventDefault();removeProject('${esc(p.id)}')">Remove</button></div>`;
        html += '</a>';
      }
      html += '</div>';
    }
    app.innerHTML = html;
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function addProjectPrompt() {
  fetch('/api/pick-folder', {method:'POST'}).then(r=>r.json()).then(data => {
    if (data.cancelled || !data.path) return;
    fetch('/api/skills/projects',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:data.path})})
      .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});return r.json()})
      .then(()=>renderProjects())
      .catch(e=>toast('Failed: '+e, 'error'));
  });
}

function scanProjectsPrompt() {
  fetch('/api/pick-folder', {method:'POST'}).then(r=>r.json()).then(data => {
    if (data.cancelled || !data.path) return;
    fetch('/api/skills/projects/scan',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({root:data.path,maxDepth:4})})
      .then(r=>r.json()).then(paths => {
        if (!paths.length) { toast('No projects found.', 'error'); return; }
        const selected = paths.filter(p => confirm(`Add project: ${p}?`));
        return Promise.all(selected.map(p =>
          fetch('/api/skills/projects',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p})})
        ));
      }).then(()=>renderProjects())
      .catch(e=>toast('Scan failed: '+e, 'error'));
  });
}

function removeProject(id) {
  if (!confirm('Remove this project from tracking? (Files will NOT be deleted)')) return;
  fetch(`/api/skills/projects/${id}`,{method:'DELETE'})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});renderProjects()})
    .catch(e=>toast('Failed: '+e, 'error'));
}

function renderProjectDetail(id) {
  const app = document.getElementById('app');
  app.innerHTML = '<div class="empty"><span class="spinner"></span> Loading project...</div>';
  Promise.all([
    fetch(`/api/skills/projects/${id}`).then(r=>r.json()),
    fetch(`/api/skills/projects/${id}/agents`).then(r=>r.json()),
    fetch(`/api/skills/projects/${id}/skills`).then(r=>r.json()),
    fetch('/api/skills').then(r=>r.json()),
  ]).then(([project, agents, skills, centerSkills]) => {
    const icon = '\u{1F4C1}';
    let html = `<div style="margin-bottom:16px">`;
    html += `<div style="display:flex;justify-content:space-between;align-items:center">`;
    html += `<h2 style="margin:0">${icon} ${esc(project.name)}</h2>`;
    html += `<a class="btn" href="#/skills-projects">\u{2190} All Projects</a></div>`;
    html += `<div class="meta">${esc(project.path)}</div>`;
    html += `<div class="meta">${project.skillCount} skills</div>`;
    html += '</div>';

    // Agent targets
    if (agents.length > 1) {
      html += '<div style="margin-bottom:12px"><strong>Agents:</strong> ';
      for (const a of agents) {
        html += `<span class="tag-badge" style="margin-right:4px">${esc(a.displayName)} (${a.enabledCount}/${a.skillCount})</span>`;
      }
      html += '</div>';
    }

    // Agent filter
    html += `<div style="margin-bottom:12px">`;
    html += `<label>Filter by agent: </label><select id="agent-filter" onchange="filterProjectSkills('${esc(id)}')">`;
    html += '<option value="">All</option>';
    for (const a of agents) {
      html += `<option value="${esc(a.key)}">${esc(a.displayName)}</option>`;
    }
    html += '</select>';
    html += ` <button class="btn btn-sm" onclick="exportSkillToProjectPrompt('${esc(id)}')">Export from Center</button>`;
    html += '</div>';

    // Skills table
    html += '<div id="project-skills-list">';
    html += renderProjectSkillsTable(skills, project, id);
    html += '</div>';

    app.innerHTML = html;
  }).catch(e => { app.innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`; });
}

function renderProjectSkillsTable(skills, project, projectId) {
  if (!skills.length) return '<div class="empty">No skills in this project.</div>';
  let html = '<table style="width:100%;border-collapse:collapse">';
  html += '<thead><tr><th style="text-align:left;padding:6px;border-bottom:1px solid var(--border)">Skill</th>';
  html += '<th style="text-align:left;padding:6px;border-bottom:1px solid var(--border)">Agent</th>';
  html += '<th style="text-align:center;padding:6px;border-bottom:1px solid var(--border)">Status</th>';
  html += '<th style="text-align:center;padding:6px;border-bottom:1px solid var(--border)">Sync</th>';
  html += '<th style="text-align:right;padding:6px;border-bottom:1px solid var(--border)">Actions</th></tr></thead><tbody>';
  for (const s of skills) {
    const syncBadge = syncStatusBadge(s.syncStatus);
    const enabledLabel = s.enabled ? '\u{2705}' : '\u{26D4}';
    html += '<tr>';
    html += `<td style="padding:6px;border-bottom:1px solid var(--border)">${enabledLabel} <strong>${esc(s.name)}</strong>`;
    if (s.tags && s.tags.length) html += ' ' + renderTagBadges(s.tags);
    html += '</td>';
    html += `<td style="padding:6px;border-bottom:1px solid var(--border)">${esc(s.agentDisplayName)}</td>`;
    html += `<td style="text-align:center;padding:6px;border-bottom:1px solid var(--border)">${s.inCenter ? 'In Center' : 'Local Only'}</td>`;
    html += `<td style="text-align:center;padding:6px;border-bottom:1px solid var(--border)">${syncBadge}</td>`;
    html += '<td style="text-align:right;padding:6px;border-bottom:1px solid var(--border)">';
    // Toggle
    if (project.supportsSkillToggle) {
      const toggleLabel = s.enabled ? 'Disable' : 'Enable';
      html += `<button class="btn btn-sm" onclick="toggleSkill('${esc(projectId)}','${esc(s.path)}','${esc(s.agent)}',${!s.enabled})">${toggleLabel}</button> `;
    }
    // Import to center
    if (!s.inCenter) {
      html += `<button class="btn btn-sm" onclick="importSkillToCenter('${esc(projectId)}','${esc(s.path)}','${esc(s.agent)}')">Import</button> `;
    }
    // Sync actions
    if (s.centerSkillId && s.syncStatus !== 'in_sync') {
      html += `<button class="btn btn-sm" onclick="updateFromCenter('${esc(projectId)}','${esc(s.path)}','${esc(s.centerSkillId)}')" title="Overwrite project skill with center version">\u{2B07} Center</button> `;
      html += `<button class="btn btn-sm" onclick="updateToCenter('${esc(projectId)}','${esc(s.path)}','${esc(s.centerSkillId)}')" title="Push project changes to center">\u{2B06} Center</button> `;
      html += `<button class="btn btn-sm" onclick="showDiff('${esc(projectId)}','${esc(s.path)}','${esc(s.centerSkillId)}')" title="View differences">Diff</button> `;
    }
    // View doc
    html += `<button class="btn btn-sm" onclick="viewProjectDoc('${esc(projectId)}','${esc(s.path)}')">Doc</button> `;
    // Delete
    html += `<button class="btn btn-sm" style="color:#ef4444" onclick="deleteProjectSkill('${esc(projectId)}','${esc(s.path)}','${esc(s.agent)}')">Del</button>`;
    html += '</td></tr>';
  }
  html += '</tbody></table>';
  return html;
}

function syncStatusBadge(status) {
  switch(status) {
    case 'in_sync': return '<span style="color:#22c55e">\u{2705} In Sync</span>';
    case 'project_newer': return '<span style="color:#f59e0b">\u{2B06} Project Newer</span>';
    case 'center_newer': return '<span style="color:#3b82f6">\u{2B07} Center Newer</span>';
    case 'diverged': return '<span style="color:#ef4444">\u{26A0} Diverged</span>';
    case 'project_only': return '<span style="color:#8b5cf6">\u{1F195} Local Only</span>';
    default: return status || '';
  }
}

function filterProjectSkills(projectId) {
  const agent = document.getElementById('agent-filter').value;
  const url = agent ? `/api/skills/projects/${projectId}/skills?agent=${agent}` : `/api/skills/projects/${projectId}/skills`;
  Promise.all([
    fetch(url).then(r=>r.json()),
    fetch(`/api/skills/projects/${projectId}`).then(r=>r.json()),
  ]).then(([skills, project]) => {
    document.getElementById('project-skills-list').innerHTML = renderProjectSkillsTable(skills, project, projectId);
  });
}

function toggleSkill(projectId, skillPath, agent, enabled) {
  fetch(`/api/skills/projects/${projectId}/toggle`,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,agent,enabled})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});renderProjectDetail(projectId)})
    .catch(e=>toast('Toggle failed: '+e, 'error'));
}

function importSkillToCenter(projectId, skillPath, agent) {
  fetch(`/api/skills/projects/${projectId}/import`,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,agent})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});return r.json()})
    .then(d=>{toast('Imported! Skill ID: '+d.skillId, 'success');renderProjectDetail(projectId)})
    .catch(e=>toast('Import failed: '+e, 'error'));
}

function exportSkillToProjectPrompt(projectId) {
  fetch('/api/skills').then(r=>r.json()).then(skills => {
    if (!skills.length) { toast('No center skills to export.', 'error'); return; }
    const name = prompt('Enter skill name to export:\n' + skills.map(s=>s.name).join(', '));
    if (!name) return;
    const skill = skills.find(s => s.name === name);
    if (!skill) { toast('Skill not found: ' + name, 'error'); return; }
    fetch(`/api/skills/projects/${projectId}/export`,{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({skillId:skill.id})})
      .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});toast('Exported!','success');renderProjectDetail(projectId)})
      .catch(e=>toast('Export failed: '+e, 'error'));
  });
}

function updateFromCenter(projectId, skillPath, centerSkillId) {
  if (!confirm('Overwrite project skill with center version?')) return;
  fetch(`/api/skills/projects/${projectId}/update-from-center`,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,centerSkillId})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});renderProjectDetail(projectId)})
    .catch(e=>toast('Update failed: '+e, 'error'));
}

function updateToCenter(projectId, skillPath, centerSkillId) {
  if (!confirm('Push project changes to center? This overwrites the center skill.')) return;
  fetch(`/api/skills/projects/${projectId}/update-to-center`,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,centerSkillId})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});renderProjectDetail(projectId)})
    .catch(e=>toast('Update failed: '+e, 'error'));
}

function viewProjectDoc(projectId, skillPath) {
  fetch(`/api/skills/projects/${projectId}/document?skillPath=${encodeURIComponent(skillPath)}`)
    .then(r=>r.json()).then(d => {
      const content = d.content || 'No document found.';
      const w = window.open('','_blank','width=700,height=500');
      w.document.write('<pre style="white-space:pre-wrap;font-family:monospace;padding:16px">'+content.replace(/</g,'&lt;')+'</pre>');
    }).catch(e=>toast('Error: '+e, 'error'));
}

function deleteProjectSkill(projectId, skillPath, agent) {
  if (!confirm('Delete this skill from the project? This cannot be undone.')) return;
  fetch(`/api/skills/projects/${projectId}/skills`,{method:'DELETE',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,agent})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});renderProjectDetail(projectId)})
    .catch(e=>toast('Delete failed: '+e, 'error'));
}

function showDiff(projectId, skillPath, centerSkillId) {
  fetch(`/api/skills/projects/${projectId}/diff`,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({skillPath,centerSkillId})})
    .then(r=>{if(!r.ok) return r.json().then(d=>{throw new Error(d.error)});return r.json()})
    .then(diff => {
      const app = document.getElementById('app');
      let html = `<div style="margin-bottom:12px"><button class="btn" onclick="renderProjectDetail('${esc(projectId)}')">\u{2190} Back</button>`;
      html += ` <h2 style="display:inline;margin-left:8px">Diff: ${esc(diff.skillName)}</h2></div>`;
      if (!diff.files.length) {
        html += '<div class="empty">Files are identical.</div>';
      } else {
        for (const f of diff.files) {
          html += `<div class="card" style="margin-bottom:8px"><strong>${esc(f.fileName)}</strong> <span class="tag-badge">${esc(f.status)}</span>`;
          if (f.status === 'modified') {
            html += '<div style="display:flex;gap:8px;margin-top:8px">';
            html += `<div style="flex:1"><div style="font-weight:600;margin-bottom:4px;color:#3b82f6">Project</div><pre style="background:var(--card-bg);padding:8px;border-radius:4px;overflow:auto;max-height:300px;font-size:12px">${esc(f.projectContent||'')}</pre></div>`;
            html += `<div style="flex:1"><div style="font-weight:600;margin-bottom:4px;color:#22c55e">Center</div><pre style="background:var(--card-bg);padding:8px;border-radius:4px;overflow:auto;max-height:300px;font-size:12px">${esc(f.centerContent||'')}</pre></div>`;
            html += '</div>';
          } else if (f.status === 'project_only') {
            html += `<pre style="background:var(--card-bg);padding:8px;border-radius:4px;overflow:auto;max-height:200px;font-size:12px;margin-top:8px">${esc(f.projectContent||'')}</pre>`;
          } else {
            html += `<pre style="background:var(--card-bg);padding:8px;border-radius:4px;overflow:auto;max-height:200px;font-size:12px;margin-top:8px">${esc(f.centerContent||'')}</pre>`;
          }
          html += '</div>';
        }
      }
      app.innerHTML = html;
    }).catch(e=>toast('Diff failed: '+e, 'error'));
}

function loadData(forceRefresh) {
  const url = forceRefresh ? '/api/tools/refresh' : '/api/tools';
  const opts = forceRefresh ? {method:'POST'} : {};
  fetch(url, opts).then(r => r.json()).then(tools => {
    toolsCache = tools;
    const ts = document.getElementById('ts');
    if (ts) ts.textContent = new Date().toLocaleTimeString();
    navigate();
  }).catch(e => {
    document.getElementById('app').innerHTML = `<div class="empty">Error: ${esc(String(e))}</div>`;
  });
}

window._shiftHeld = false;
window.addEventListener('keydown', e => { if (e.key === 'Shift') window._shiftHeld = true; });
window.addEventListener('keyup', e => { if (e.key === 'Shift') window._shiftHeld = false; });
window.addEventListener('hashchange', navigate);
loadData();
