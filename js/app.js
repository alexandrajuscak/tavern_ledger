import { supabase, isConfigured, redirectUrl } from './supabase.js?v=4';
import {
  state, isDM, loadProfile, listProfiles, updateProfile, listCharacters, createCharacter, loadBundle, saver,
} from './store.js?v=4';
import { CLASSES } from './dnd.js?v=4';
import { $, $$, esc, toast, openModal, cacheGet, cacheSet, cacheClear } from './utils.js?v=4';
import { mountSheet, unmountSheet } from './sheet.js?v=4';
import { importCharacter, parseCharacterJson } from './transfer.js?v=4';

const app = $('#app');
let routeToken = 0; // guards against out-of-order async renders

// -----------------------------------------------------------------------------
// Boot
// -----------------------------------------------------------------------------

async function init() {
  if (!isConfigured) {
    renderSetupNeeded();
    return;
  }

  saver.onStatus(renderSaveStatus);
  $('#btn-signout').addEventListener('click', signOut);

  const { data: { session } } = await supabase.auth.getSession();
  cleanAuthParams();
  await handleSession(session);

  supabase.auth.onAuthStateChange((event, newSession) => {
    // Defer: calling Supabase inside this callback can deadlock the auth lock.
    setTimeout(() => {
      if (event === 'SIGNED_OUT') handleSession(null);
      else if (newSession && !state.session) handleSession(newSession);
      else if (newSession) state.session = newSession;
    }, 0);
  });

  window.addEventListener('hashchange', route);
}

function cleanAuthParams() {
  const url = new URL(window.location.href);
  if (url.searchParams.has('code') || url.searchParams.has('error')) {
    const err = url.searchParams.get('error_description');
    if (err) toast(err, 'bad', 6000);
    url.searchParams.delete('code');
    url.searchParams.delete('error');
    url.searchParams.delete('error_code');
    url.searchParams.delete('error_description');
    history.replaceState(null, '', url.pathname + url.search + url.hash);
  }
}

async function handleSession(session) {
  state.session = session;
  if (!session) {
    state.profile = null;
    unmountSheet();
    $('#topbar').hidden = true;
    renderAuth();
    return;
  }
  try {
    await loadProfile(session.user);
  } catch (err) {
    console.error(err);
    renderError('Could not load your profile. Did you run supabase/schema.sql?', err);
    return;
  }
  $('#topbar').hidden = false;
  $('#dm-badge').hidden = !isDM();
  $('#user-name').textContent = state.profile.display_name || session.user.email;
  route();
}

async function signOut() {
  await saver.flush();
  cacheClear();
  await supabase.auth.signOut();
}

function renderSaveStatus(s) {
  const el = $('#save-status');
  if (!el) return;
  const labels = {
    idle: '', pending: 'Editing…', saving: 'Saving…', saved: 'Saved ✓',
    error: 'Save failed — retrying', offline: 'Offline — will sync',
  };
  el.dataset.state = s;
  el.textContent = labels[s] ?? '';
}

// -----------------------------------------------------------------------------
// Router: #/  ·  #/c/<id>  ·  #/players
// -----------------------------------------------------------------------------

function route() {
  if (!state.session) return;
  const hash = window.location.hash || '#/';
  const token = ++routeToken;
  window.scrollTo(0, 0);

  const charMatch = hash.match(/^#\/c\/([0-9a-f-]{36})$/i);
  if (charMatch) return openCharacter(charMatch[1], token);

  unmountSheet();
  if (hash === '#/players' && isDM()) return renderPlayers(token);
  return renderList(token);
}

// -----------------------------------------------------------------------------
// Views
// -----------------------------------------------------------------------------

function renderSetupNeeded() {
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card narrow">
      <h1 class="title">Almost there</h1>
      <p>Open <code>js/config.js</code> and paste your Supabase project URL and publishable key.</p>
      <p class="muted small">See README.md for the full setup guide.</p>
    </div>
  </div>`;
}

function renderError(message, err) {
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card narrow">
      <h1 class="title">Something went wrong</h1>
      <p>${esc(message)}</p>
      ${err ? `<pre class="error-detail">${esc(err.message || String(err))}</pre>` : ''}
      <button class="btn btn-gold" onclick="location.reload()">Reload</button>
    </div>
  </div>`;
}

function renderAuth() {
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card auth-card">
      <div class="auth-logo" aria-hidden="true">⚔</div>
      <h1 class="title">Tavern Ledger</h1>
      <p class="muted center">Character sheets for our table.</p>

      <button type="button" class="btn btn-google btn-block" id="btn-google">
        <svg viewBox="0 0 48 48" width="18" height="18" aria-hidden="true"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>
        Continue with Google
      </button>

      <div class="divider"><span>or use email</span></div>

      <form id="auth-form" class="stack" novalidate>
        <label class="field"><span>Email</span>
          <input type="email" name="email" autocomplete="email" required></label>
        <label class="field"><span>Password</span>
          <input type="password" name="password" autocomplete="current-password" minlength="6"></label>
        <div class="row gap">
          <button class="btn btn-gold grow" type="submit" value="signin">Sign in</button>
          <button class="btn grow" type="submit" value="signup">Create account</button>
        </div>
        <button type="button" class="btn-link" id="btn-magic">Email me a sign-in link instead</button>
      </form>
    </div>
  </div>`;

  $('#btn-google').addEventListener('click', async () => {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: redirectUrl() },
    });
    if (error) toast(error.message, 'bad');
  });

  const form = $('#auth-form');
  const busy = (on) => $$('button', form).forEach((b) => { b.disabled = on; });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const mode = e.submitter?.value || 'signin';
    const email = form.email.value.trim();
    const password = form.password.value;
    if (!email) return toast('Enter your email', 'bad');
    if (password.length < 6) return toast('Password must be at least 6 characters', 'bad');
    busy(true);
    try {
      if (mode === 'signup') {
        const { data, error } = await supabase.auth.signUp({
          email, password, options: { emailRedirectTo: redirectUrl() },
        });
        if (error) throw error;
        if (!data.session) toast('Check your inbox to confirm your account.', 'good', 6000);
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
    } catch (err) {
      toast(err.message, 'bad', 5000);
    } finally {
      busy(false);
    }
  });

  $('#btn-magic').addEventListener('click', async () => {
    const email = form.email.value.trim();
    if (!email) {
      form.email.focus();
      return toast('Enter your email first', 'bad');
    }
    busy(true);
    const { error } = await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: redirectUrl() } });
    busy(false);
    if (error) toast(error.message, 'bad', 5000);
    else toast('Magic link sent — check your inbox.', 'good', 6000);
  });
}

function hpPct(c) {
  return Math.max(0, Math.min(100, (c.hp_current / Math.max(1, c.hp_max)) * 100));
}

const initials = (name) =>
  String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || '?';

function importDialog() {
  const dm = isDM();
  const ownerField = dm && state.profiles.length ? `
    <label class="field"><span>Player</span>
      <select name="owner_id">
        ${state.profiles.map((p) => `<option value="${p.id}" ${p.id === state.profile.id ? 'selected' : ''}>${esc(p.display_name || p.email)}</option>`).join('')}
      </select>
    </label>` : '';
  const m = openModal({
    title: 'Import character',
    body: `
      <form id="import-form" class="stack">
        <p class="muted small">Choose a character <code>.json</code> file, e.g. one downloaded from a sheet's Bio tab.</p>
        <label class="field"><span>File</span><input type="file" name="file" accept=".json,application/json" required></label>
        ${ownerField}
        <div id="import-preview" class="muted small"></div>
      </form>`,
    footer: `
      <button type="button" class="btn" data-close>Cancel</button>
      <button type="submit" form="import-form" class="btn btn-gold" disabled>Import</button>`,
  });
  const form = $('#import-form', m.el);
  const submit = $('button[type="submit"]', m.el);
  let parsed = null;

  form.elements.file.addEventListener('change', async () => {
    parsed = null;
    submit.disabled = true;
    const file = form.elements.file.files[0];
    const preview = $('#import-preview', m.el);
    if (!file) { preview.textContent = ''; return; }
    try {
      const json = JSON.parse(await file.text());
      const p = parseCharacterJson(json);
      parsed = json;
      submit.disabled = false;
      const c = p.character;
      preview.innerHTML = `Ready: <strong>${esc(c.name)}</strong>, level ${c.level} ${esc([c.race, c.class_name].filter(Boolean).join(' '))}
        · ${p.attacks.length} attacks · ${p.features.length} features · ${p.spells.length} spells · ${p.inventory.length} items`;
    } catch (err) {
      preview.innerHTML = `<span class="error-text">${esc(err instanceof SyntaxError ? 'That file is not valid JSON.' : err.message)}</span>`;
    }
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!parsed) return;
    submit.disabled = true;
    try {
      const id = await importCharacter(parsed, form.elements.owner_id?.value);
      m.close();
      toast('Character imported.', 'good');
      window.location.hash = `#/c/${id}`;
    } catch (err) {
      console.error(err);
      toast(err.message || 'Import failed', 'bad', 6000);
      submit.disabled = false;
    }
  });
}

function characterCard(c) {
  const cls = [c.class_name, c.subclass && `(${c.subclass})`].filter(Boolean).join(' ');
  return `
  <a class="char-card card" href="#/c/${c.id}">
    <div class="cc-top">
      <div class="avatar avatar-sm">${c.portrait_url ? `<img src="${esc(c.portrait_url)}" alt="" loading="lazy">` : `<span>${esc(initials(c.name))}</span>`}</div>
      <div class="cc-id">
        <div class="cc-name">${esc(c.name)}</div>
        <div class="cc-sub">${esc([c.race, cls].filter(Boolean).join(' · ') || 'Adventurer')}</div>
      </div>
      <div class="cc-level" title="Level"><small>LVL</small>${c.level}</div>
    </div>
    <div class="cc-stats">
      <span title="Hit points">❤ ${c.hp_current}/${c.hp_max}${c.hp_temp ? ` <small>+${c.hp_temp}</small>` : ''}</span>
      <span title="Armor class">🛡 ${c.ac}</span>
    </div>
    ${Array.isArray(c.conditions) && c.conditions.length ? `<div class="cc-conditions">${c.conditions.map((x) => `<span class="condition-chip small">${esc(x)}</span>`).join('')}</div>` : ''}
    <div class="hp-bar small"><div class="hp-fill" style="width:${hpPct(c)}%"></div></div>
  </a>`;
}

async function renderList(token) {
  const dm = isDM();
  app.innerHTML = `
  <div class="page">
    <div class="page-head">
      <h1 class="title">${dm ? 'The Party' : 'Your Characters'}</h1>
      <div class="row gap">
        ${dm ? '<a class="btn" href="#/players">Players</a>' : ''}
        <button type="button" class="btn" id="btn-import">⬆ Import JSON</button>
        <button type="button" class="btn btn-gold" id="btn-new">+ New Character</button>
      </div>
    </div>
    <div id="char-list"><div class="spinner"></div></div>
  </div>`;
  $('#btn-new').addEventListener('click', newCharacterDialog);
  $('#btn-import').addEventListener('click', importDialog);

  const paint = (chars) => {
    if (token !== routeToken) return;
    const host = $('#char-list');
    if (!chars.length) {
      host.innerHTML = `
        <div class="empty-state card">
          <div class="big-icon">🎲</div>
          <p>No characters yet.</p>
          <button type="button" class="btn btn-gold" id="btn-new-empty">Create your first character</button>
        </div>`;
      $('#btn-new-empty').addEventListener('click', newCharacterDialog);
      return;
    }
    if (!dm) {
      host.innerHTML = `<div class="char-grid">${chars.map(characterCard).join('')}</div>`;
      return;
    }
    const groups = new Map();
    chars.forEach((c) => {
      if (!groups.has(c.owner_id)) groups.set(c.owner_id, []);
      groups.get(c.owner_id).push(c);
    });
    const nameOf = (id) => {
      const p = state.profiles.find((x) => x.id === id);
      return p ? p.display_name || p.email : 'Unknown player';
    };
    host.innerHTML = [...groups.entries()]
      .sort(([a], [b]) => (a === state.profile.id ? -1 : b === state.profile.id ? 1 : nameOf(a).localeCompare(nameOf(b))))
      .map(([owner, list]) => `
        <section class="owner-group">
          <h2 class="owner-title">${esc(nameOf(owner))}${owner === state.profile.id ? ' <span class="badge">you</span>' : ''}</h2>
          <div class="char-grid">${list.map(characterCard).join('')}</div>
        </section>`).join('');
  };

  const cached = cacheGet('list');
  if (cached) paint(cached);

  try {
    const [chars] = await Promise.all([listCharacters(), dm ? listProfiles() : null]);
    cacheSet('list', chars);
    paint(chars);
  } catch (err) {
    console.error(err);
    toast('Could not load characters — showing cached data.', 'bad');
  }
}

function newCharacterDialog() {
  const dm = isDM();
  const ownerField = dm && state.profiles.length ? `
    <label class="field"><span>Player</span>
      <select name="owner_id">
        ${state.profiles.map((p) => `<option value="${p.id}" ${p.id === state.profile.id ? 'selected' : ''}>${esc(p.display_name || p.email)}</option>`).join('')}
      </select>
    </label>` : '';
  const m = openModal({
    title: 'New Character',
    body: `
      <form id="new-char" class="stack">
        <label class="field"><span>Name</span><input name="name" required placeholder="Thorin Oakenshield"></label>
        <div class="form-grid">
          <label class="field"><span>Race</span><input name="race" placeholder="Dwarf"></label>
          <label class="field"><span>Class</span><input name="class_name" list="new-class-list" placeholder="Fighter"></label>
          <label class="field"><span>Level</span><input name="level" type="number" min="1" max="20" value="1"></label>
          ${ownerField}
        </div>
        <datalist id="new-class-list">${CLASSES.map((c) => `<option value="${c}">`).join('')}</datalist>
      </form>`,
    footer: `
      <button type="button" class="btn" data-close>Cancel</button>
      <button type="submit" form="new-char" class="btn btn-gold">Create</button>`,
  });

  $('#new-char', m.el).addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = e.target;
    const submit = $('button[type="submit"]', m.el);
    submit.disabled = true;
    try {
      const c = await createCharacter({
        name: f.elements.name.value.trim(),
        race: f.elements.race.value.trim(),
        class_name: f.elements.class_name.value.trim(),
        level: f.elements.level.value,
        owner_id: f.elements.owner_id?.value,
      });
      m.close();
      window.location.hash = `#/c/${c.id}`;
    } catch (err) {
      console.error(err);
      toast(err.message, 'bad');
      submit.disabled = false;
    }
  });
}

async function openCharacter(id, token) {
  const cached = cacheGet(`bundle:${id}`);
  if (cached) mountSheet(app, cached, { readOnly: true });
  else app.innerHTML = '<div class="center-wrap"><div class="spinner"></div></div>';

  try {
    await saver.flush();
    const [bundle] = await Promise.all([loadBundle(id), isDM() && !state.profiles.length ? listProfiles() : null]);
    if (token !== routeToken) return;
    mountSheet(app, bundle, {
      reload: () => openCharacter(id, routeToken),
      onDeleted: () => { window.location.hash = '#/'; },
    });
  } catch (err) {
    console.error(err);
    if (token !== routeToken) return;
    if (cached) {
      toast('Offline — showing a read-only cached copy.', 'bad', 5000);
    } else {
      renderError('This character could not be loaded. It may have been deleted, or you may not have access.', err);
    }
  }
}

async function renderPlayers(token) {
  app.innerHTML = `
  <div class="page">
    <div class="page-head">
      <h1 class="title">Players</h1>
      <a class="btn" href="#/">← Characters</a>
    </div>
    <p class="muted">Everyone who has signed in appears here. Promote a co-DM or rename players.</p>
    <div id="player-list"><div class="spinner"></div></div>
  </div>`;

  try {
    const [profiles, chars] = await Promise.all([listProfiles(), listCharacters()]);
    if (token !== routeToken) return;
    $('#player-list').innerHTML = `
      <div class="player-table">
        ${profiles.map((p) => `
          <div class="player-row card" data-id="${p.id}">
            <div class="player-info">
              <input type="text" class="player-name" value="${esc(p.display_name || '')}" placeholder="Display name" aria-label="Display name">
              <span class="muted small">${esc(p.email || '')} · ${chars.filter((c) => c.owner_id === p.id).length} character(s)</span>
            </div>
            <select class="player-role" aria-label="Role">
              <option value="player" ${p.role === 'player' ? 'selected' : ''}>Player</option>
              <option value="dm" ${p.role === 'dm' ? 'selected' : ''}>DM</option>
            </select>
          </div>`).join('')}
      </div>`;

    $('#player-list').addEventListener('change', async (e) => {
      const row = e.target.closest('.player-row');
      if (!row) return;
      const patch = e.target.classList.contains('player-role')
        ? { role: e.target.value }
        : { display_name: e.target.value.trim() };
      try {
        await updateProfile(row.dataset.id, patch);
        toast('Saved', 'good');
        if (row.dataset.id === state.profile.id) {
          Object.assign(state.profile, patch);
          $('#dm-badge').hidden = !isDM();
          $('#user-name').textContent = state.profile.display_name || state.profile.email;
          if (!isDM()) window.location.hash = '#/';
        }
      } catch (err) {
        toast(err.message, 'bad');
      }
    });
  } catch (err) {
    console.error(err);
    renderError('Could not load players.', err);
  }
}

init().catch((err) => {
  console.error(err);
  renderError('The app failed to start.', err);
});
