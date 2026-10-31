import { supabase, isConfigured, isLocalOrigin, redirectUrl, environment } from './supabase.js?v=17';
import {
  state, isAdmin, isAnyDM, isCampaignDM, myCampaigns, campaignMembers, profileName,
  loadProfile, loadCampaigns, createCampaign, updateCampaign, deleteCampaign, setMember, removeMember,
  updateProfile, listCharacters, listCharacterBadges, createCharacter, loadBundle, loadCharacterView, saver,
} from './store.js?v=17';
import { getDerivedStats, getProficiencies } from './inventory-api.js?v=17';
import { icon, classIcon, iconSrc } from './icons.js?v=17';
import { $, $$, esc, toast, openModal, confirmDialog, cacheGet, cacheSet, cacheClear, cacheClearPrefix, friendlyError } from './utils.js?v=17';
import { mountSheet, unmountSheet, activeTabKey } from './sheet.js?v=17';
import { fluentEnabled, prefetchView, cancelPrefetches, clearReadCaches, markFluentBroken, isFluentUnavailable } from './read-layer.js?v=17';
import { mountDmSpace, unmountDmSpace } from './dm-space.js?v=17';
import { importCharacter, parseCharacterJson, getLastImportReport } from './transfer.js?v=17';
import { openLineagePicker } from './lineage-ui.js?v=17';
import { getCharacterLineage } from './lineage-api.js?v=17';
import { openAddClass } from './class-setup.js?v=17';
import { getClassSummary } from './class-api.js?v=17';

const app = $('#app');
let routeToken = 0; // guards against out-of-order async renders

// -----------------------------------------------------------------------------
// Boot
// -----------------------------------------------------------------------------

async function init() {
  // a staging page says so on every screen, so it is never mistaken for the real table (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md)
  if (environment === 'staging') {
    document.title = `STAGING · ${document.title}`;
    document.body.insertAdjacentHTML('afterbegin', '<div class="env-banner" role="status">STAGING: test project, not the real table</div>');
  }
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
    routeToken += 1;          // a character still being opened must not appear after sign-out
    bundleReads?.abort();
    clearReadCaches();        // views, prefetches and seeds of this user (memory only)
    cacheClearPrefix('list', 'bundle:', 'cardstats:');   // the session ended (here, in another tab, or expired): no user data stays
    unmountSheet();
    unmountDmSpace();
    $('#topbar').hidden = true;
    renderAuth();
    return;
  }
  try {
    await loadProfile(session.user);
    await loadCampaigns();
  } catch (err) {
    console.error(err);
    renderError('Could not load your profile or campaigns. Did you run the latest supabase/schema.sql?', err);
    return;
  }
  $('#topbar').hidden = false;
  updateBadges();
  route();
}

if (fluentEnabled()) cacheClearPrefix('bundle:');   // fluent read path: no character payload is persisted in localStorage

async function signOut() {
  await saver.flush();
  clearReadCaches();
  cacheClear();
  await supabase.auth.signOut();
}

function renderSaveStatus(s) {
  const el = $('#save-status');
  if (!el) return;
  const labels = {
    idle: '', pending: 'Editing…', saving: 'Saving…', saved: 'Saved ✓',
    error: 'Save failed — retrying', offline: 'Offline — will sync', stalled: 'Not saved yet — retries on your next edit',
  };
  el.dataset.state = s;
  el.textContent = labels[s] ?? '';
}

// -----------------------------------------------------------------------------
// Router: #/  ·  #/c/<id>  ·  #/campaigns (admin)
// -----------------------------------------------------------------------------

function route() {
  if (!state.session) return;
  const hash = window.location.hash || '#/';
  const token = ++routeToken;
  bundleReads?.abort();
  window.scrollTo(0, 0);

  const charMatch = hash.match(/^#\/c\/([0-9a-f-]{36})$/i);
  unmountDmSpace();
  if (charMatch) return openCharacter(charMatch[1], token);

  unmountSheet();
  const dmMatch = hash.match(/^#\/dm(?:\/([a-z]+))?(?:\/([0-9a-f-]{36}))?$/i);
  if (dmMatch) {
    if (!isAnyDM()) { window.location.hash = '#/'; return undefined; }
    return mountDmSpace(app, { section: dmMatch[1] || 'overview', id: dmMatch[2] || null });
  }
  if ((hash === '#/campaigns' || hash === '#/players') && isAdmin()) return renderCampaigns(token);
  return renderList(token);
}

// -----------------------------------------------------------------------------
// Views
// -----------------------------------------------------------------------------

function renderSetupNeeded() {
  if (environment === 'staging') {
    app.innerHTML = `
    <div class="center-wrap">
      <div class="card narrow">
        <h1 class="title">Staging is not configured</h1>
        <p>Create the git-ignored <code>js/config.staging.js</code> with the staging project URL and its publishable key, then reload.</p>
        <p class="muted small">See docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md.</p>
      </div>
    </div>`;
    return;
  }
  if (environment === 'unknown-host') {
    app.innerHTML = `
    <div class="center-wrap">
      <div class="card narrow">
        <h1 class="title">Unknown address</h1>
        <p>This copy of Tavern Ledger is not served from an approved address, so it does not connect to any database.</p>
        <p class="muted small">Approved hosts are listed in <code>js/config.js</code> (PRODUCTION_HOSTS).</p>
      </div>
    </div>`;
    return;
  }
  if (isLocalOrigin) {
    app.innerHTML = `
    <div class="center-wrap">
      <div class="card narrow">
        <h1 class="title">Local Supabase is not configured</h1>
        <p>On localhost the app only talks to the local Supabase stack. Start it with <code>start-local.bat</code>
          (or <code>.\\scripts\\start-local.ps1</code>), then reload this page.</p>
        <p class="muted small">See docs/LOCAL_DEVELOPMENT.md.</p>
      </div>
    </div>`;
    return;
  }
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card narrow">
      <h1 class="title">Almost there</h1>
      <p>Open <code>js/config.js</code> and paste your Supabase project URL and publishable key.</p>
      <p class="muted small">See README.md for the full setup guide.</p>
    </div>
  </div>`;
}

function renderError(message, err, { expected = false } = {}) {
  if (err) (expected ? console.warn : console.error)('[load]', err?.code || '', err?.message || err);
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card narrow">
      <h1 class="title">Something went wrong</h1>
      <p>${esc(message)}</p>
      ${err ? `<p class="muted small error-detail">${esc(friendlyError(err, 'The server did not answer as expected.'))}</p>` : ''}
      <div class="error-actions"><button class="btn btn-gold" onclick="location.reload()">Reload</button>
        <a class="btn" href="#/">Back to your characters</a></div>
    </div>
  </div>`;
}

function renderAuth() {
  app.innerHTML = `
  <div class="center-wrap">
    <div class="card auth-card">
      <img class="auth-logo" src="${iconSrc('classes/fighter')}" alt="" width="72" height="72">
      <h1 class="title">Tavern Ledger</h1>
      <p class="muted center">Your characters, ready for the table.</p>

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
    if (error) toast(friendlyError(error, 'Sign-in failed. Please try again.'), 'bad');
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
      toast(friendlyError(err, 'Sign-in failed. Please try again.'), 'bad', 5000);
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
    if (error) toast(friendlyError(error, 'Sign-in failed. Please try again.'), 'bad', 5000);
    else toast('Magic link sent — check your inbox.', 'good', 6000);
  });
}

function hpPct(c, max = c.hp_max) {
  return Math.max(0, Math.min(100, (c.hp_current / Math.max(1, max)) * 100));
}

// Character list extras: classes / Wild Shape / lock / requests (batched reads) and the derived max HP and AC (one read per
// character, few at a time, cached per character version so the list does not flicker on the next visit).
let listBadges = {};
const titleCase = (id) => String(id || '').split(/[-_]/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(' ');
const statsKey = (c) => `cardstats:${c.id}:${c.updated_at}`;

/** Home cards: fetch the character view on clear intent; one at a time, cancellable, nothing on save-data connections. */
function wirePrefetch(list) {
  if (!list || list.__prefetch) return;
  list.__prefetch = true;
  let timer = null;
  const go = (e, delay) => {
    const card = e.target.closest?.('.char-card[data-char]');
    if (!card || !fluentEnabled()) return;
    clearTimeout(timer);
    timer = setTimeout(() => prefetchView(state.profile?.id, card.dataset.char), delay);
  };
  list.addEventListener('pointerover', (e) => go(e, 150));
  list.addEventListener('pointerout', (e) => { if (e.target.closest?.('.char-card')) clearTimeout(timer); });
  list.addEventListener('focusin', (e) => go(e, 0));
  list.addEventListener('pointerdown', (e) => go(e, 0));
}

async function loadCardStats(chars, token) {
  const queue = chars.filter((c) => !cacheGet(statsKey(c)));
  const worker = async () => {
    while (queue.length && token === routeToken) {
      const c = queue.shift();
      try {
        const d = await getDerivedStats(c.id);
        const st = { max: d?.hit_points?.max ?? null, ac: d?.armor_class?.value ?? null, lineage: d?.lineage?.name || null };
        cacheSet(statsKey(c), st);
        if (token === routeToken) updateCard(c, st);
      } catch {   // the card never keeps a loading mark: base maximum, unknown AC, and a hint
        if (token === routeToken) updateCard(c, { max: null, ac: null, failed: true });
      }
    }
  };
  await Promise.all(Array.from({ length: 6 }, worker));   // six reads at a time: 35 local cards complete in ~1.6 s instead of ~2.7 s
}

function updateCard(c, st) {
  const el = document.querySelector(`.char-card[data-char="${CSS.escape(c.id)}"]`);
  if (!el) return;
  const max = st.max ?? c.hp_max;
  const hp = el.querySelector('[data-cc-hp]');
  if (hp) hp.textContent = `${c.hp_current} / ${max}`;   // replaces the loading mark
  const ac = el.querySelector('[data-cc-ac]');
  if (ac) ac.textContent = st.ac != null ? String(st.ac) : '—';
  if (st.failed) el.title = 'Current values could not be loaded; open the character to see them.';
  const fill = el.querySelector('.hp-fill');
  if (fill) fill.style.width = `${hpPct(c, max)}%`;
  const sub = el.querySelector('[data-cc-sub]');
  if (sub && st.lineage) sub.textContent = cardSubtitle(c, st);
}

function cardSubtitle(c, st) {
  const b = listBadges[c.id];
  const cls = b?.classes?.length
    ? [...b.classes].sort((x, y) => (y.is_primary ? 1 : 0) - (x.is_primary ? 1 : 0)).map((k) => `${titleCase(k.class_id)} ${k.level}`).join(' / ')
    : [c.class_name && `${c.class_name} ${c.level}`, c.subclass && `(${c.subclass})`].filter(Boolean).join(' ');
  return [cls || `Level ${c.level}`, st?.lineage || c.race].filter(Boolean).join(' · ');
}

const initials = (name) =>
  String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || '?';

// ---- Campaign + owner pickers shared by "New character" and "Import" ------------

/** Owners the current user may assign in a campaign: admin → anyone; campaign DM → its members. */
function ownerOptions(campaignId) {
  if (isAdmin()) return state.profiles;
  if (campaignId && isCampaignDM(campaignId)) {
    const ids = new Set(campaignMembers(campaignId).map((m) => m.user_id));
    return state.profiles.filter((p) => ids.has(p.id));
  }
  return [];
}

function campaignOwnerFields() {
  const camps = myCampaigns();
  const campField = camps.length ? `
    <label class="field"><span>Campaign</span>
      <select name="campaign_id">
        ${camps.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}
        ${isAdmin() ? '<option value="">— No campaign —</option>' : ''}
      </select>
    </label>` : '';
  return `${campField}<label class="field" data-owner-field hidden><span>Player</span><select name="owner_id"></select></label>`;
}

/** Fill the Player select for the chosen campaign and keep it in sync. */
function wireOwnerField(form) {
  const fill = () => {
    const owners = ownerOptions(form.elements.campaign_id?.value || null);
    const field = $('[data-owner-field]', form);
    field.hidden = owners.length === 0;
    form.elements.owner_id.innerHTML = owners.map((p) =>
      `<option value="${p.id}" ${p.id === state.profile.id ? 'selected' : ''}>${esc(p.display_name || p.email)}</option>`).join('');
  };
  form.elements.campaign_id?.addEventListener('change', fill);
  fill();
}

const formCampaign = (f) => f.elements.campaign_id?.value || null;
const formOwner = (f) => ($('[data-owner-field]', f).hidden ? undefined : f.elements.owner_id.value || undefined);

function importDialog() {
  const m = openModal({
    title: 'Import character',
    body: `
      <form id="import-form" class="stack">
        <p class="muted small">Choose a character <code>.json</code> file, e.g. one downloaded from a sheet's Bio tab.</p>
        <label class="field"><span>File</span><input type="file" name="file" accept=".json,application/json" required></label>
        <div class="form-grid">${campaignOwnerFields()}</div>
        <div id="import-preview" class="muted small"></div>
      </form>`,
    footer: `
      <button type="button" class="btn" data-close>Cancel</button>
      <button type="submit" form="import-form" class="btn btn-gold" disabled>Import</button>`,
  });
  const form = $('#import-form', m.el);
  const submit = $('button[type="submit"]', m.el);
  wireOwnerField(form);
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
      const id = await importCharacter(parsed, formOwner(form), formCampaign(form));
      m.close();
      const rep = getLastImportReport();
      const notes = rep ? [...(rep.warnings || []).map((w) => w.message), ...(rep.unresolved || []).length
        ? [`${rep.unresolved.length} class feature entr${rep.unresolved.length === 1 ? 'y' : 'ies'} kept under Pending choices for review`] : [],
        rep.error ? `Class features not restored: ${rep.error}` : ''].filter(Boolean) : [];
      toast(`Character imported.${notes.length ? ` ${notes.join(' · ')}` : ''}`, notes.length ? 'info' : 'good', notes.length ? 8000 : 3200);
      window.location.hash = `#/c/${id}`;
    } catch (err) {
      console.error(err);
      toast(err.message || 'Import failed', 'bad', 6000);
      submit.disabled = false;
    }
  });
}

// Until the authoritative maximum HP and AC of a card arrive, the card says so instead of showing the stored legacy values
// (the old `ac` column and the base maximum would flash wrong numbers, e.g. AC 10 for an armoured Paladin).
const WAIT = '<span class="cc-wait" aria-label="loading">…</span>';

function characterCard(c) {
  const st = cacheGet(statsKey(c)) || {};
  const b = listBadges[c.id] || {};
  const max = st.max ?? c.hp_max;
  const primary = b.classes?.find((k) => k.is_primary)?.class_id || b.classes?.[0]?.class_id || c.class_name;
  const chips = [];
  if (b.form) chips.push(`<span class="chip chip-nature">${icon('actions/wild-shape', { size: 16 })}Wild Shape: ${esc(titleCase(b.form.creature_id))}</span>`);
  if (b.lock && b.lock !== 'unlocked') chips.push(`<span class="chip chip-locked">${icon('ui/locked', { size: 16 })}${b.lock === 'archived' ? 'Archived' : 'Locked'}</span>`);
  const own = c.owner_id === state.profile.id;
  if (b.returned) chips.push(`<span class="chip chip-pending">${icon('ui/pending', { size: 16 })}${b.returned} returned ${own ? 'to you' : 'to the player'}</span>`);
  else if (b.waiting) chips.push(`<span class="chip chip-pending">${icon('ui/pending', { size: 16 })}${b.waiting} ${own ? 'waiting for the DM' : 'to review'}</span>`);
  const choices = Array.isArray(c.pending_choices) ? c.pending_choices.length : 0;
  if (choices) chips.push(`<span class="chip chip-warn choices-badge">${choices} reminder${choices === 1 ? '' : 's'}</span>`);
  (Array.isArray(c.conditions) ? c.conditions : []).slice(0, 3).forEach((x) => chips.push(`<span class="chip">${esc(x)}</span>`));
  return `
  <a class="char-card card" href="#/c/${c.id}" data-char="${c.id}">
    <div class="cc-top">
      <div class="avatar avatar-sm">${c.portrait_url ? `<img src="${esc(c.portrait_url)}" alt="" loading="lazy">` : classIcon(primary, { size: 34, cls: 'avatar-emblem' })}</div>
      <div class="cc-id">
        <div class="cc-name">${esc(c.name)}</div>
        <div class="cc-sub" data-cc-sub>${esc(cardSubtitle(c, st))}</div>
      </div>
    </div>
    <div class="cc-stats">
      <span class="cc-stat">${icon('actions/heal', { size: 18 })}<span class="sr-only">Hit points </span><span data-cc-hp>${c.hp_current} / ${st.max ?? WAIT}</span>${c.hp_temp ? ` <small>+${c.hp_temp} temp</small>` : ''}</span>
      <span class="cc-stat">${icon('equipment-slots/shield', { size: 18 })}<span class="sr-only">Armor Class </span><span data-cc-ac>${st.ac ?? WAIT}</span></span>
    </div>
    <div class="hp-bar small" aria-hidden="true"><div class="hp-fill" style="width:${hpPct(c, max)}%"></div></div>
    ${chips.length ? `<div class="cc-chips">${chips.join('')}</div>` : ''}
  </a>`;
}

function updateBadges() {
  const badge = $('#dm-badge');
  badge.textContent = isAdmin() ? 'ADMIN' : 'DM';
  badge.hidden = !isAnyDM();
  const dmLink = $('#dm-link');
  if (dmLink) dmLink.hidden = !isAnyDM();
  $('#user-name').textContent = state.profile.display_name || state.profile.email;
}

/** Characters of one campaign, grouped by player when you can see other people's. */
function ownerGroupsHTML(chars, showOwners) {
  if (!showOwners) return `<div class="char-grid">${chars.map(characterCard).join('')}</div>`;
  const groups = new Map();
  chars.forEach((c) => {
    if (!groups.has(c.owner_id)) groups.set(c.owner_id, []);
    groups.get(c.owner_id).push(c);
  });
  return [...groups.entries()]
    .sort(([a], [b]) => (a === state.profile.id ? -1 : b === state.profile.id ? 1 : profileName(a).localeCompare(profileName(b))))
    .map(([owner, list]) => `
      <div class="owner-group">
        <h3 class="owner-title">${esc(profileName(owner))}${owner === state.profile.id ? ' <span class="badge">you</span>' : ''} <span class="count">${list.length}</span></h3>
        <div class="char-grid">${list.map(characterCard).join('')}</div>
      </div>`).join('');
}

function campaignHeaderHTML(camp) {
  const members = campaignMembers(camp.id);
  const dms = members.filter((m) => m.role === 'dm').map((m) => profileName(m.user_id));
  const players = members.filter((m) => m.role === 'player').length;
  const myRole = isCampaignDM(camp.id) ? 'DM'
    : members.some((m) => m.user_id === state.profile.id) ? 'Player'
      : isAdmin() ? 'Admin' : '';
  return `
    <div class="campaign-head">
      <h2 class="campaign-title">${esc(camp.name)} ${myRole ? `<span class="badge ${myRole === 'Player' ? '' : 'badge-dm'}">${myRole}</span>` : ''}</h2>
      <div class="muted small">DM${dms.length === 1 ? '' : 's'}: ${esc(dms.join(', ') || '—')} · ${players} player${players === 1 ? '' : 's'}</div>
      ${camp.description ? `<p class="campaign-desc">${esc(camp.description)}</p>` : ''}
    </div>`;
}

async function renderList(token) {
  app.innerHTML = `
  <div class="page home">
    <div class="page-head">
      <div>
        <h1 class="title">${isAnyDM() ? 'Characters and campaigns' : 'Your characters'}</h1>
        <p class="muted page-sub">Open a character to play, or create a new one.</p>
      </div>
      <div class="row gap">
        ${isAdmin() ? '<a class="btn btn-quiet" href="#/campaigns">Manage campaigns</a>' : ''}
        <button type="button" class="btn btn-quiet" id="btn-import">Import file</button>
        <button type="button" class="btn btn-gold" id="btn-new">+ New character</button>
      </div>
    </div>
    <div class="home-tools" id="home-tools" hidden>
      <label class="search-field">${icon('ui/skills', { size: 18 })}<span class="sr-only">Find a character</span>
        <input type="search" id="char-search" placeholder="Find a character by name, class or lineage" autocomplete="off"></label>
      <span class="muted small" id="char-search-count" role="status" aria-live="polite"></span>
    </div>
    <div id="char-list">${[0, 1, 2].map(() => '<div class="skeleton skeleton-block" aria-hidden="true"></div>').join('')}<span class="sr-only" role="status">Loading characters…</span></div>
  </div>`;
  $('#btn-new').addEventListener('click', newCharacterDialog);
  $('#btn-import').addEventListener('click', importDialog);

  const campaignBlock = (camp, list, showOwners) => `
    <section class="campaign-group" aria-label="${esc(camp ? camp.name : 'Not in a campaign')}">
      ${camp ? campaignHeaderHTML(camp) : `<div class="campaign-head"><h2 class="campaign-title">Not in a campaign</h2>
        <div class="muted small">Choose a campaign on the character's Bio tab.</div></div>`}
      ${list.length ? ownerGroupsHTML(list, showOwners) : '<p class="empty">No characters in this campaign yet.</p>'}
    </section>`;

  const paint = (chars) => {
    if (token !== routeToken) return;
    const host = $('#char-list');
    const archived = chars.filter((c) => listBadges[c.id]?.lock === 'archived');
    const active = chars.filter((c) => listBadges[c.id]?.lock !== 'archived');
    const mine = active.filter((c) => c.owner_id === state.profile.id);
    const others = active.filter((c) => c.owner_id !== state.profile.id);
    const sections = [];
    // My characters: grouped by campaign (a short campaign heading), never mixed with other players' sheets
    const myGroups = [];
    for (const camp of state.campaigns) {
      const list = mine.filter((c) => c.campaign_id === camp.id);
      if (list.length) myGroups.push(campaignBlock(camp, list, false));
    }
    const loose = mine.filter((c) => !c.campaign_id || !state.campaigns.some((k) => k.id === c.campaign_id));
    if (loose.length) myGroups.push(campaignBlock(null, loose, false));
    if (myGroups.length) sections.push(`<h2 class="home-section">${icon('ui/bio', { size: 24 })}My characters <span class="count">${mine.length}</span></h2>${myGroups.join('')}`);
    // Campaign characters: other players' sheets the user may open (DM, admin)
    const theirGroups = [];
    for (const camp of state.campaigns) {
      const list = others.filter((c) => c.campaign_id === camp.id);
      if (list.length) theirGroups.push(campaignBlock(camp, list, true));
    }
    const looseOthers = others.filter((c) => !c.campaign_id || !state.campaigns.some((k) => k.id === c.campaign_id));
    if (looseOthers.length) theirGroups.push(campaignBlock(null, looseOthers, true));
    if (theirGroups.length) sections.push(`<h2 class="home-section">${icon('dm/campaign', { size: 24 })}Campaign characters <span class="count">${others.length}</span></h2>${theirGroups.join('')}`);
    // campaigns the user runs or plays in that have no characters yet
    const emptyCamps = state.campaigns.filter((camp) => !chars.some((c) => c.campaign_id === camp.id)
      && (isCampaignDM(camp.id) || campaignMembers(camp.id).some((m) => m.user_id === state.profile.id)));
    if (emptyCamps.length) sections.push(`<details class="quiet-details home-empty-camps"><summary>Campaigns without characters (${emptyCamps.length})</summary>
      ${emptyCamps.map((camp) => campaignBlock(camp, [], false)).join('')}</details>`);
    if (archived.length) sections.push(`<details class="quiet-details home-archived"><summary>Archived characters (${archived.length})</summary>
      <div class="char-grid">${archived.map(characterCard).join('')}</div></details>`);
    if (!mine.length && !others.length && !archived.length) {
      host.innerHTML = `
        <div class="empty-state card">
          ${icon('portraits/explorer', { size: 96 })}
          <h2>Start your first adventure</h2>
          <p class="muted">Create a character and choose a class, lineage and background. The sheet helps you with each choice.</p>
          ${!myCampaigns().length && !isAdmin() ? '<p class="muted small">Playing in a campaign? Ask your DM to add you, then your characters can join it.</p>' : ''}
          <button type="button" class="btn btn-gold" id="btn-new-empty">Create your first character</button>
        </div>${sections.join('')}`;
      $('#btn-new-empty').addEventListener('click', newCharacterDialog);
      return;
    }
    host.innerHTML = sections.join('');
    $('#home-tools').hidden = chars.length <= 6;
    applySearch();
  };

  const applySearch = () => {
    const q = ($('#char-search')?.value || '').trim().toLowerCase();
    let shown = 0;
    $$('#char-list .char-card').forEach((card) => {
      const hit = !q || card.textContent.toLowerCase().includes(q);
      card.hidden = !hit;
      if (hit) shown += 1;
    });
    $$('#char-list .campaign-group, #char-list .owner-group').forEach((g) => { g.hidden = !!q && !g.querySelector('.char-card:not([hidden])'); });
    const count = $('#char-search-count');
    if (count) count.textContent = q ? `${shown} found` : '';
  };
  $('#char-search').addEventListener('input', applySearch);
  wirePrefetch($('#char-list'));

  const cached = cacheGet('list');
  if (cached && state.campaigns.length) paint(cached);

  try {
    const [chars] = await Promise.all([listCharacters(), loadCampaigns()]);
    cacheSet('list', chars);
    updateBadges();
    listBadges = await listCharacterBadges(chars.map((c) => c.id)).catch(() => ({}));
    paint(chars);
    loadCardStats(chars, token);
  } catch (err) {
    console.error(err);
    if (!cached) {
      $('#char-list').innerHTML = `<div class="empty-state card"><h2>Characters could not be loaded</h2>
        <p class="muted">Nothing was changed. Check that the local server is running, then try again.</p>
        <button type="button" class="btn btn-gold" onclick="location.reload()">Try again</button></div>`;
    } else toast('Could not refresh the characters: showing the last loaded list.', 'bad');
  }
}

// ---- New character (docs/CHARACTER_CREATION_AUDIT.md) ------------------------------------------------------------------
// Identity -> Lineage (canonical catalog) -> Lineage choices -> Class -> Review. The character is created after the identity
// step; every later step uses the same pickers and RPCs as the Build section, so campaign governance and the content policy
// apply exactly as there. There is no free-text Race field: the lineage comes from the versioned catalog.
const NC_STEPS = ['Identity', 'Lineage', 'Lineage choices', 'Class', 'Review'];

function newCharacterDialog() {
  let step = 0;
  let created = null;   // { id, campaign_id, name, level }
  let finished = false;
  const m = openModal({
    title: 'New character',
    wide: true,
    body: `<ol class="nc-steps" aria-label="Steps">${NC_STEPS.map((t, i) => `<li data-nc-step="${i}">${t}</li>`).join('')}</ol>
      <div data-nc-body></div>`,
    footer: '<div class="nc-footer row gap wrap" data-nc-footer></div>',
    onClose: () => {
      // the character exists from step 2 on: open it, so nothing is left half-made without the player seeing it
      if (created && !finished) {
        toast('Character saved. Finish the remaining choices on Build.', 'info', 5000);
        window.location.hash = `#/c/${created.id}`;
      }
    },
  });
  const bodyEl = $('[data-nc-body]', m.el);
  const footEl = $('[data-nc-footer]', m.el);

  const setStep = (i) => {
    step = i;
    $$('[data-nc-step]', m.el).forEach((li) => {
      const n = Number(li.dataset.ncStep);
      if (n === i) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
      li.classList.toggle('is-done', n < i);
    });
  };
  const footer = (html) => { footEl.innerHTML = html; };
  const focusFirst = () => setTimeout(() => $('input:not([type=hidden]), select, button', bodyEl)?.focus(), 30);

  // ---- 1. identity ----
  function identity() {
    setStep(0);
    bodyEl.innerHTML = `<form id="new-char" class="stack" novalidate>
        <h3 class="nc-step-title">Who is it?</h3>
        <p class="nc-step-help">Lineage and class come next, from the rules catalog. Everything can be finished later on Build.</p>
        <label class="field"><span>Name</span><input name="name" required placeholder="Thorin Oakenshield" autocomplete="off"></label>
        <div class="form-grid">
          <label class="field"><span>Starting level</span><input name="level" type="number" min="1" max="20" value="1"></label>
          ${campaignOwnerFields()}
          <label class="field span-2"><span>Portrait image link (optional; you can upload one on Bio)</span>
            <input name="portrait_url" type="url" inputmode="url" placeholder="https://…"></label>
        </div>
      </form>`;
    footer(`<button type="button" class="btn" data-close>Cancel</button>
      <button type="submit" form="new-char" class="btn btn-gold" data-nc-next>Create and choose lineage</button>`);
    const form = $('#new-char', bodyEl);
    wireOwnerField(form);
    focusFirst();
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const name = form.elements.name.value.trim();
      if (!name) { toast('Give the character a name first.', 'bad'); form.elements.name.focus(); return; }
      const btn = $('[data-nc-next]', footEl);
      btn.disabled = true;
      try {
        const c = await createCharacter({
          name, race: '', class_name: '', level: form.elements.level.value, owner_id: formOwner(form), campaign_id: formCampaign(form),
          portrait_url: form.elements.portrait_url.value.trim(),
        });
        created = { id: c.id, campaign_id: c.campaign_id, name: c.name, level: c.level };
        await lineageStep();
      } catch (err) {
        console.error(err);
        toast(err.message, 'bad');
        btn.disabled = false;
      }
    });
  }

  // ---- 2 + 3. lineage (the Build picker, embedded) ----
  async function lineageStep() {
    setStep(1);
    bodyEl.innerHTML = '<div data-nc-lineage></div>';
    footer(`<button type="button" class="btn btn-quiet" data-nc-skip>Skip lineage for now</button>
      <button type="button" class="btn btn-gold" data-nc-save hidden>Save lineage and continue</button>`);
    $('[data-nc-skip]', footEl).addEventListener('click', () => classStep());
    await openLineagePicker({
      characterId: created.id, current: null, level: created.level, campaignId: created.campaign_id || null,
      host: $('[data-nc-lineage]', bodyEl), saveButton: $('[data-nc-save]', footEl),
      onStep: (s) => setStep(s === 'configure' ? 2 : 1),
      onSaved: () => classStep(),
    });
    focusFirst();
  }

  // ---- 4. class (the Build "Choose your class" form, embedded) ----
  async function classStep() {
    setStep(3);
    bodyEl.innerHTML = '<h3 class="nc-step-title">Class</h3><div data-nc-class><p class="muted">Loading classes…</p></div>';
    footer(`<button type="button" class="btn btn-quiet" data-nc-skip>Skip class for now</button>
      <button type="button" class="btn btn-gold" data-nc-save disabled>Save class and continue</button>`);
    $('[data-nc-skip]', footEl).addEventListener('click', () => review());
    try {
      const summary = await getClassSummary(created.id);
      if ((summary.classes || []).length) { review(); return; }
      await openAddClass({ characterId: created.id, summary, host: $('[data-nc-class]', bodyEl), saveButton: $('[data-nc-save]', footEl),
        onSaved: (res, extra) => review(extra) });
      focusFirst();
    } catch (err) {
      $('[data-nc-class]', bodyEl).innerHTML = `<p class="muted">${esc(err.message)}</p>`;
    }
  }

  // ---- 5. review ----
  async function review(extra = {}) {
    setStep(4);
    bodyEl.innerHTML = '<h3 class="nc-step-title">Review</h3><p class="muted">Loading…</p>';
    footer('<button type="button" class="btn btn-gold" data-nc-open>Open the character</button>');
    $('[data-nc-open]', footEl).addEventListener('click', () => { finished = true; m.close(); window.location.hash = `#/c/${created.id}`; });
    const [lin, cls, d, prof] = await Promise.all([
      getCharacterLineage(created.id).catch(() => null), getClassSummary(created.id).catch(() => null), getDerivedStats(created.id).catch(() => null),
      getProficiencies(created.id).catch(() => null)]);
    const warn = [];
    if (!lin?.selected) warn.push('No lineage yet: choose one on Build → Lineage.');
    const open = (lin?.choices || []).filter((c) => c.status === 'missing');
    if (open.length) warn.push(`Lineage choices still open: ${open.map((c) => esc(c.label)).join(', ')}.`);
    if (!(cls?.classes || []).length) warn.push('No class yet: choose one on Build → Classes.');
    if (extra.equipment) warn.push(`Starting equipment of the ${esc(extra.className)} is waiting: choose it on Build → Classes.`);
    const row = (k, v) => `<div class="kv"><span>${k}</span><strong>${v || '<span class="muted small">none</span>'}</strong></div>`;
    const sp = d?.speed;
    const moves = sp ? [`Walk ${sp.value} ft`, ...Object.entries(sp.movement || {}).filter(([k, x]) => k !== 'walk' && x.active).map(([k, x]) => `${k} ${x.value} ft`)].join(', ') : '';
    const senses = Object.entries(d?.senses || {}).map(([k, x]) => `${k} ${x.value} ft`).join(', ');
    const label = (id) => String(id).replace(/-/g, ' ').replace(/^\w/, (x) => x.toUpperCase());
    const profs = (prof?.groups || []).filter((g) => (g.sources || []).length || g.manual).map((g) => label(g.id)).join(', ');
    const abil = (lin?.choices || []).filter((c) => c.kind === 'ability_scores' && c.values.length)
      .flatMap((c) => c.values.map((v) => `+${v.split(':')[1]} ${v.split(':')[0].toUpperCase()}`)).join(', ');
    bodyEl.innerHTML = `<h3 class="nc-step-title">Review</h3>
      <div class="nc-review" data-nc-review>
        <div class="kv-list">
          ${row('Name', esc(created.name))}
          ${row('Lineage', lin?.selected ? `${esc(lin.lineage.name)} <span class="muted small">${esc(lin.version.name)} · ${esc(lin.version.source_label)}</span>` : '')}
          ${row('Sub-lineage', lin?.subversion ? esc(lin.subversion.name) : '')}
          ${row('Class', (cls?.classes || []).map((k) => `${esc(k.class_name)} ${k.level}`).join(' / '))}
          ${row('Speed', esc(moves))}
          ${row('Senses', esc(senses))}
          ${row('Ability increases from the lineage', esc(abil))}
          ${row('Armor and weapon training', esc(profs))}
        </div>
        ${warn.length ? `<ul class="nc-warn" data-nc-warnings>${warn.map((w) => `<li>${w}</li>`).join('')}</ul>`
          : '<p class="calm-note">Everything needed to play is chosen.</p>'}
      </div>`;
    $('[data-nc-open]', footEl).focus();
  }

  identity();
}

// The stored rows of the character being opened; aborted as soon as the user opens something else (route()), so a quick
// A -> B -> C switch does not leave A's and B's reads running (incident 2026-10-23, docs/CHARACTER_LOAD_COORDINATOR.md).
let bundleReads = null;

async function openCharacter(id, token, { legacy = false } = {}) {
  bundleReads?.abort();
  const reads = bundleReads = new AbortController();
  cancelPrefetches(id);
  if (fluentEnabled() && !legacy) return openCharacterFluent(id, token, reads);
  const cached = cacheGet(`bundle:${id}`);
  if (cached) mountSheet(app, cached, { readOnly: true });
  else {
    unmountSheet({ keepRealtimeFor: id });   // the previous character stops reading and listening now, not when this one arrives
    app.innerHTML = '<div class="center-wrap"><div class="spinner"></div></div>';
  }

  try {
    await saver.flush();
    const [bundle] = await Promise.all([loadBundle(id, reads.signal), loadCampaigns()]);
    if (token !== routeToken) return;
    updateBadges();
    mountSheet(app, bundle, {
      reload: () => openCharacter(id, routeToken),
      onDeleted: () => { window.location.hash = '#/'; },
    });
  } catch (err) {
    if (token !== routeToken || reads.signal.aborted) return;   // superseded: nothing to report
    console.error(err);
    if (cached) {
      toast('Offline — showing a read-only cached copy.', 'bad', 5000);
    } else {
      unmountSheet();   // the previous character's top bar, subscriptions and state must not stay above the error (V6.2)
      renderError('This character could not be loaded. It may have been deleted, or you may not have access.', err);
    }
  }
}

/**
 * Fluent read path: one get_character_view request (shell + active tab) instead of 35. The previous character is unmounted
 * at once (its reads abort, its data is never shown as the new character); a stable placeholder stays until the whole sheet
 * paints in one step. If the fluent read functions are unavailable on the server, this session falls back to the legacy path.
 */
let campaignsLoadedAt = 0;
async function openCharacterFluent(id, token, reads) {
  unmountSheet({ keepRealtimeFor: id });
  app.innerHTML = '<div class="center-wrap" data-sheet-loading><div class="spinner"></div></div>';
  try {
    await saver.flush();
    // campaigns and members change rarely: refreshed at most once a minute, and never on the open's critical path once known
    const campaigns = Date.now() - campaignsLoadedAt > 60000 || !state.campaigns.length
      ? loadCampaigns().then(() => { campaignsLoadedAt = Date.now(); }, (e) => { if (!state.campaigns.length) throw e; console.warn('[campaigns]', e?.message || e); }) : null;
    const [{ bundle, view }] = await Promise.all([loadCharacterView(id, activeTabKey(), reads.signal), state.campaigns.length ? null : campaigns]);
    if (token !== routeToken) return;
    updateBadges();
    mountSheet(app, bundle, {
      view,
      reload: () => openCharacter(id, routeToken),
      onDeleted: () => { window.location.hash = '#/'; },
    });
  } catch (err) {
    if (token !== routeToken || reads.signal.aborted) return;   // superseded: nothing to report
    if (isFluentUnavailable(err)) { markFluentBroken(err); openCharacter(id, token); return; }
    // the one-request view hit the statement timeout: this sheet opens on the legacy per-read path (small reads, each retried
    // on its own); the next open tries the view again
    if (err?.code === '57014') { console.warn('[fluent] view timed out; legacy open for this sheet'); openCharacter(id, token, { legacy: true }); return; }
    const denied = err?.code === '42501';     // deleted or not yours: an expected answer, not a client error
    if (!denied) console.error(err);
    unmountSheet();
    renderError('This character could not be loaded. It may have been deleted, or you may not have access.', err, { expected: denied });
  }
}

// ---- Admin: campaigns & people ----------------------------------------------------

function manageHTML(chars) {
  const camps = state.campaigns.map((camp) => {
    const members = campaignMembers(camp.id)
      .sort((a, b) => (a.role === b.role ? profileName(a.user_id).localeCompare(profileName(b.user_id)) : a.role === 'dm' ? -1 : 1));
    const memberIds = new Set(members.map((m) => m.user_id));
    const addable = state.profiles.filter((p) => !memberIds.has(p.id));
    const count = chars.filter((c) => c.campaign_id === camp.id).length;
    return `
    <section class="card manage-campaign" data-campaign="${camp.id}">
      <div class="form-grid">
        <label class="field"><span>Campaign name</span><input type="text" data-camp-field="name" value="${esc(camp.name)}"></label>
        <label class="field"><span>Description</span><input type="text" data-camp-field="description" value="${esc(camp.description)}" placeholder="Optional"></label>
      </div>
      <h4>Members <span class="count">${members.length} · ${count} character${count === 1 ? '' : 's'}</span></h4>
      <div class="member-list">
        ${members.map((mb) => `
          <div class="member-row" data-user="${mb.user_id}">
            <span class="member-name">${esc(profileName(mb.user_id))}</span>
            <select data-member-role aria-label="Role">
              <option value="dm" ${mb.role === 'dm' ? 'selected' : ''}>DM</option>
              <option value="player" ${mb.role === 'player' ? 'selected' : ''}>Player</option>
            </select>
            <button type="button" class="icon-btn danger" data-remove-member aria-label="Remove from campaign">✕</button>
          </div>`).join('') || '<p class="empty">No members yet.</p>'}
      </div>
      ${addable.length ? `
      <div class="add-member">
        <select data-add-user aria-label="Person to add">${addable.map((p) => `<option value="${p.id}">${esc(p.display_name || p.email)}</option>`).join('')}</select>
        <select data-add-role aria-label="Role"><option value="player">as Player</option><option value="dm">as DM</option></select>
        <button type="button" class="btn btn-sm btn-gold" data-add-member>+ Add</button>
      </div>` : '<p class="muted small">Everyone who has signed in is already in this campaign.</p>'}
      <div class="row gap mt"><button type="button" class="btn btn-sm btn-bad" data-delete-campaign>Delete campaign</button></div>
    </section>`;
  }).join('');

  const people = state.profiles.map((p) => `
    <div class="player-row card" data-id="${p.id}">
      <div class="player-info">
        <input type="text" class="player-name" value="${esc(p.display_name || '')}" placeholder="Display name" aria-label="Display name">
        <span class="muted small">${esc(p.email || '')} · ${chars.filter((c) => c.owner_id === p.id).length} character(s)</span>
      </div>
      <select class="player-role" aria-label="Global role">
        <option value="player" ${p.role === 'player' ? 'selected' : ''}>Player</option>
        <option value="admin" ${p.role === 'admin' ? 'selected' : ''}>Admin</option>
      </select>
    </div>`).join('');

  return `
    <div class="section-head">
      <h3 class="section-title">Campaigns</h3>
      <button type="button" class="btn btn-gold btn-sm" data-new-campaign>+ New campaign</button>
    </div>
    <p class="muted small">A campaign's DMs can see and edit every character in it. Players see only their own characters.</p>
    ${camps || '<p class="empty">No campaigns yet.</p>'}

    <h3 class="section-title mt">People</h3>
    <p class="muted small">Everyone who has signed in. New players appear here after their first login; then add them to a campaign above. Admins see and manage everything.</p>
    <div class="player-table">${people}</div>`;
}

async function renderCampaigns(token) {
  app.innerHTML = `
  <div class="page">
    <div class="page-head">
      <h1 class="title">Manage</h1>
      <a class="btn" href="#/">← Characters</a>
    </div>
    <div id="manage"><div class="spinner"></div></div>
  </div>`;

  let chars = [];
  const refresh = async () => {
    [chars] = await Promise.all([listCharacters(), loadCampaigns()]);
    if (token === routeToken) $('#manage').innerHTML = manageHTML(chars);
  };
  const guard = (fn) => async (e) => {
    try {
      await fn(e);
    } catch (err) {
      console.error(err);
      toast(err.message || 'Something went wrong', 'bad', 5000);
      await refresh().catch(() => {});
    }
  };

  try {
    await refresh();
  } catch (err) {
    console.error(err);
    renderError('Could not load campaigns. Did you re-run supabase/schema.sql?', err);
    return;
  }

  const host = $('#manage');
  host.addEventListener('click', guard(async (e) => {
    const box = e.target.closest('[data-campaign]');
    const camp = box?.dataset.campaign;
    if (e.target.closest('[data-new-campaign]')) {
      const c = await createCampaign('New Campaign');
      await setMember(c.id, state.profile.id, 'dm');
      toast('Campaign created. You are its DM.', 'good');
      await refresh();
      $(`[data-campaign="${c.id}"] [data-camp-field="name"]`)?.select();
    } else if (e.target.closest('[data-add-member]')) {
      await setMember(camp, $('[data-add-user]', box).value, $('[data-add-role]', box).value);
      await refresh();
    } else if (e.target.closest('[data-remove-member]')) {
      const user = e.target.closest('[data-user]').dataset.user;
      const ok = await confirmDialog(
        `Remove ${profileName(user)} from this campaign? Their characters stay, but this campaign's DMs will no longer see them.`,
        { okLabel: 'Remove', danger: true },
      );
      if (!ok) return;
      await removeMember(camp, user);
      await refresh();
    } else if (e.target.closest('[data-delete-campaign]')) {
      const name = state.campaigns.find((c) => c.id === camp)?.name;
      const ok = await confirmDialog(
        `Delete the campaign “${name}”? Its characters are kept and move to “Not in a campaign”.`,
        { okLabel: 'Delete', danger: true },
      );
      if (!ok) return;
      await deleteCampaign(camp);
      await refresh();
    }
  }));

  host.addEventListener('change', guard(async (e) => {
    const box = e.target.closest('[data-campaign]');
    if (e.target.dataset.campField) {
      await updateCampaign(box.dataset.campaign, { [e.target.dataset.campField]: e.target.value.trim() });
      toast('Saved', 'good');
    } else if (e.target.hasAttribute('data-member-role')) {
      await setMember(box.dataset.campaign, e.target.closest('[data-user]').dataset.user, e.target.value);
      toast('Saved', 'good');
      await refresh();
    } else if (e.target.closest('.player-row')) {
      const row = e.target.closest('.player-row');
      const patch = e.target.classList.contains('player-role') ? { role: e.target.value } : { display_name: e.target.value.trim() };
      await updateProfile(row.dataset.id, patch);
      toast('Saved', 'good');
      if (row.dataset.id === state.profile.id) {
        Object.assign(state.profile, patch);
        updateBadges();
        if (!isAdmin()) { window.location.hash = '#/'; return; }
      }
      await refresh();
    }
  }));
}

init().catch((err) => {
  console.error(err);
  renderError('The app failed to start.', err);
});
