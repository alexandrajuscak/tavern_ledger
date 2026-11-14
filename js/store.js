import { supabase, announceGovernance } from './supabase.js?v=37';
import { toast, friendlyError } from './utils.js?v=37';
import { CLASS_HIT_DIE, NOTE_KINDS, dieSize } from './dnd.js?v=37';
import { fetchView } from './read-layer.js?v=37';

export const state = {
  session: null,
  profile: null,
  profiles: [], // every profile you can see (admins: everyone; others: people in your campaigns)
  campaigns: [], // campaigns you can see
  members: [], // campaign_members rows you can see
};

/** Global admin: sees and manages every campaign, character and person. */
export const isAdmin = () => state.profile?.role === 'admin';
/** DM of this particular campaign. */
export const isCampaignDM = (campaignId) =>
  !!campaignId && state.members.some((m) => m.campaign_id === campaignId && m.user_id === state.profile?.id && m.role === 'dm');
/** DM of at least one campaign (or admin). */
export const isAnyDM = () => isAdmin() || state.members.some((m) => m.user_id === state.profile?.id && m.role === 'dm');
/** Can edit this character's ownership, delete it, level it up as a DM… */
export const canManageCharacter = (c) => isAdmin() || isCampaignDM(c?.campaign_id);
/** Campaigns the current user can put a character into. */
export const myCampaigns = () =>
  (isAdmin() ? state.campaigns : state.campaigns.filter((c) => state.members.some((m) => m.campaign_id === c.id && m.user_id === state.profile?.id)));
export const campaignMembers = (campaignId) => state.members.filter((m) => m.campaign_id === campaignId);
export const profileName = (id) => {
  const p = state.profiles.find((x) => x.id === id);
  return p ? p.display_name || p.email : 'Unknown player';
};

function check({ data, error }) {
  if (error) throw error;
  return data;
}

// ---- Profiles ---------------------------------------------------------------

export async function loadProfile(user) {
  let profile = check(await supabase.from('profiles').select('*').eq('id', user.id).maybeSingle());
  if (!profile) {
    // Fallback for users created before the auth trigger existed.
    const meta = user.user_metadata || {};
    profile = check(
      await supabase
        .from('profiles')
        .insert({ id: user.id, email: user.email, display_name: meta.full_name || meta.name || user.email?.split('@')[0] })
        .select()
        .single(),
    );
  }
  state.profile = profile;
  return profile;
}

export async function listProfiles() {
  state.profiles = check(await supabase.from('profiles').select('*').order('display_name'));
  return state.profiles;
}

export async function updateProfile(id, patch) {
  return check(await supabase.from('profiles').update(patch).eq('id', id).select().single());
}

// ---- Campaigns ----------------------------------------------------------------

/** Load campaigns, memberships and the profiles you can see. */
export async function loadCampaigns() {
  const [campaigns, members, profiles] = await Promise.all([
    supabase.from('campaigns').select('*').order('name').then(check),
    supabase.from('campaign_members').select('*').then(check),
    supabase.from('profiles').select('*').order('display_name').then(check),
  ]);
  Object.assign(state, { campaigns, members, profiles });
  return state;
}

export async function createCampaign(name, description = '') {
  return check(await supabase.from('campaigns').insert({ name, description }).select().single());
}

export async function updateCampaign(id, patch) {
  check(await supabase.from('campaigns').update(patch).eq('id', id));
}

export async function deleteCampaign(id) {
  check(await supabase.from('campaigns').delete().eq('id', id));
}

export async function setMember(campaignId, userId, role) {
  check(await supabase.from('campaign_members')
    .upsert({ campaign_id: campaignId, user_id: userId, role }, { onConflict: 'campaign_id,user_id' }));
}

export async function removeMember(campaignId, userId) {
  check(await supabase.from('campaign_members').delete().eq('campaign_id', campaignId).eq('user_id', userId));
}

// ---- Characters -------------------------------------------------------------

export async function listCharacters() {
  return check(
    await supabase
      .from('characters')
      .select('id, owner_id, campaign_id, name, race, class_name, subclass, level, hp_current, hp_max, hp_temp, ac, portrait_url, conditions, pending_choices, updated_at')
      .order('name'),
  );
}

/**
 * At-a-glance state for the character list (one batched read per table, RLS decides what is visible): classes, an active
 * Wild Shape, the lock and open requests. Any part that cannot be read is simply missing; the cards still render.
 */
export async function listCharacterBadges(ids) {
  if (!ids.length) return {};
  const safe = async (q) => { try { const { data, error } = await q; return error ? [] : data || []; } catch { return []; } };
  const [classes, forms, gov, reqs] = await Promise.all([
    safe(supabase.from('character_classes').select('character_id, class_id, level, is_primary').in('character_id', ids)),
    safe(supabase.from('character_transformations').select('character_id, creature_id, hp_current, hp_max').in('character_id', ids)),
    safe(supabase.from('character_governance').select('character_id, lock_mode').in('character_id', ids)),
    safe(supabase.from('change_requests').select('character_id, status').in('character_id', ids).in('status', ['submitted', 'returned_for_changes'])),
  ]);
  const out = Object.fromEntries(ids.map((id) => [id, { classes: [], form: null, lock: null, waiting: 0, returned: 0 }]));
  for (const k of classes) out[k.character_id]?.classes.push(k);
  for (const f of forms) if (out[f.character_id]) out[f.character_id].form = f;
  for (const g of gov) if (out[g.character_id]) out[g.character_id].lock = g.lock_mode;
  for (const r of reqs) if (out[r.character_id]) out[r.character_id][r.status === 'submitted' ? 'waiting' : 'returned'] += 1;
  return out;
}

export async function createCharacter({ name, race, class_name, level, owner_id, campaign_id, portrait_url = '' }) {
  const hit_die = CLASS_HIT_DIE[class_name] || 'd8';
  const lvl = Math.min(20, Math.max(1, Number(level) || 1));
  // First level: max die; later levels: average. CON is 10 by default, so no modifier yet.
  const hp = dieSize(hit_die) + (lvl - 1) * (dieSize(hit_die) / 2 + 1);
  const row = {
    name: name || 'New Adventurer',
    race: race || '',
    class_name: class_name || '',
    level: lvl,
    hit_die,
    hit_dice_current: lvl,
    hp_max: hp,
    hp_current: hp,
  };
  if (portrait_url) row.portrait_url = portrait_url;
  if (owner_id) row.owner_id = owner_id;
  if (campaign_id) row.campaign_id = campaign_id;
  return check(await supabase.from('characters').insert(row).select().single());
}

export async function deleteCharacter(id) {
  check(await supabase.from('characters').delete().eq('id', id));
}

/** The stored rows of one character. `signal` cancels the reads when the user opens something else (never the self-heal writes). */
export async function loadBundle(id, signal) {
  const r = (q) => (signal ? q.abortSignal(signal) : q).then(check);
  const [character, inventory, notes, slots, trackers, features, attacks, spells] = await Promise.all([
    r(supabase.from('characters').select('*').eq('id', id).single()),
    r(supabase.from('inventory_items').select('*').eq('character_id', id).order('sort_order').order('created_at')),
    r(supabase.from('notes').select('*').eq('character_id', id)),
    r(supabase.from('spell_slots').select('*').eq('character_id', id).order('level')),
    r(supabase.from('feature_trackers').select('*').eq('character_id', id).order('sort_order').order('created_at')),
    r(supabase.from('features').select('*').eq('character_id', id).order('sort_order').order('created_at')),
    r(supabase.from('attacks').select('*').eq('character_id', id).order('sort_order').order('created_at')),
    r(supabase.from('spells').select('*').eq('character_id', id).order('level').order('sort_order').order('created_at')),
  ]);
  if (signal?.aborted) throw Object.assign(new Error('AbortError: superseded'), { name: 'AbortError' });
  return healBundle(id, { character, inventory, notes, slots, trackers, features, attacks, spells });
}

/** Self-heal characters that are missing seeded rows (notes of every kind, spell slot rows 1-9); shared by both read paths. */
async function healBundle(id, { character, inventory, notes, slots, trackers, features, attacks, spells }) {
  const missingKinds = NOTE_KINDS.filter((k) => !notes.some((n) => n.kind === k));
  if (missingKinds.length) {
    const rows = check(
      await supabase
        .from('notes')
        .upsert(missingKinds.map((kind) => ({ character_id: id, kind })), { onConflict: 'character_id,kind' })
        .select(),
    );
    notes.push(...rows.filter((r) => !notes.some((n) => n.id === r.id)));
  }
  const missingLevels = [1, 2, 3, 4, 5, 6, 7, 8, 9].filter((l) => !slots.some((s) => s.level === l));
  if (missingLevels.length) {
    const rows = check(
      await supabase
        .from('spell_slots')
        .upsert(missingLevels.map((level) => ({ character_id: id, level })), { onConflict: 'character_id,level' })
        .select(),
    );
    slots.push(...rows.filter((r) => !slots.some((s) => s.id === r.id)));
    slots.sort((a, b) => a.level - b.level);
  }

  return { character, inventory, notes, slots, trackers, features, attacks, spells };
}

/**
 * Fluent read path (js/read-layer.js): ONE request for the stored rows and every read the mounted sheet makes. Returns the
 * same bundle as loadBundle plus the view, whose reads seed the sheet's loaders. A part the server could not read is left to
 * its loader (it then reads it itself, as before).
 */
export async function loadCharacterView(id, tab, signal) {
  const view = await fetchView(state.profile?.id || state.session?.user?.id, id, { signal });
  if (signal?.aborted) throw Object.assign(new Error('AbortError: superseded'), { name: 'AbortError' });
  const r = view.reads || {};
  if (!r.characters) {
    const e = view.errors?.characters;
    throw Object.assign(new Error(e?.message || 'This character could not be loaded.'), { code: e?.code });
  }
  const bundle = await healBundle(id, { character: r.characters, inventory: r.inventory_items || [], notes: r.notes || [],
    slots: r.spell_slots || [], trackers: r.feature_trackers || [], features: r.features || [], attacks: r.attacks || [], spells: r.spells || [] });
  return { bundle, view };
}

export async function insertRow(table, row) {
  return check(await supabase.from(table).insert(row).select().single());
}

export async function insertRows(table, rows) {
  if (!rows.length) return [];
  return check(await supabase.from(table).insert(rows).select());
}

export async function updateRow(table, id, patch) {
  const res = await supabase.from(table).update(patch).eq('id', id);
  if (res.error && GOVERNANCE_CODES.has(res.error.code)) refuseWrite(table, id, patch, res.error);
  check(res);
}

// ---- governance refusals ------------------------------------------------------
// A write the campaign does not allow (docs/DM_GOVERNANCE.md) is never retried: the sheet reloads the row and may offer
// the change as an approval request (build fields go through update_character_build).
const GOVERNANCE_CODES = new Set(['TLAPR', 'TLDMO', 'TLDIS', 'TLLCK']);
const BUILD_FIELDS = new Set(['strength', 'dexterity', 'constitution', 'intelligence', 'wisdom', 'charisma', 'hp_max', 'ac_override', 'speed',
  'initiative_bonus', 'hit_die']);
function refuseWrite(table, id, patch, error) {
  const buildable = table === 'characters' && Object.keys(patch).every((k) => BUILD_FIELDS.has(k));
  announceGovernance(buildable ? 'update_character_build' : null, { p_character: table === 'characters' ? id : null, p_patch: patch }, error);
  window.dispatchEvent(new CustomEvent('tavern:save-refused', { detail: { table, id, patch, error } }));
}

/** One atomic HP change on the server (docs/COMBAT_BUILDER_ARCHITECTURE.md "Hit points"): damage | heal | temp | set.
 *  The sheet buttons and the Combat Builder use it, so a change made in one place is never overwritten by a stale value
 *  from the other. The result carries the values after the change (`after`, or `wild_shape` while a form is active). */
export async function applyCharacterHp(id, op, amount, reason = null) {
  const { data, error } = await supabase.rpc('apply_character_hp', { p_character: id, p_op: op, p_amount: amount, p_reason: reason });
  if (error) throw Object.assign(new Error(friendlyError(error, 'Hit points were not changed.')), { code: error.code, raw: error });
  return data;
}

// ---- Conditions and DM tags (20261112000200, docs/HIDDEN_DM_DATA.md "Conditions and tags on the sheet") ----------------------
// character_conditions is the one store; characters.conditions is only the server's mirror of the visible rows. The server
// returns the caller's view: a player never receives a hidden row. Results stay in memory (never in the bundle cache).
async function conditionRpc(fn, args, fallback) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw Object.assign(new Error(friendlyError(error, fallback)), { code: error.code, raw: error });
  return Array.isArray(data) ? data : [];
}
export const getCharacterConditions = (id) => conditionRpc('get_character_conditions', { p_character: id }, 'Conditions could not be loaded.');
/** spec: {kind: condition|exhaustion|tag, condition_key, level, tag_type, damage_type_id, name, note, duration_text, hidden, dm_note} */
export const applyCharacterEffect = (id, spec) => conditionRpc('apply_character_effect', { p_character: id, p_spec: spec }, 'The condition was not added.');
export const updateCharacterEffect = (conditionId, patch) => conditionRpc('update_character_effect', { p_condition: conditionId, p_patch: patch }, 'The condition was not changed.');
export const removeCharacterCondition = (conditionId) => conditionRpc('remove_character_condition', { p_condition: conditionId }, 'The condition was not removed.');

export async function deleteRow(table, id) {
  saver.discard(table, id);
  check(await supabase.from(table).delete().eq('id', id));
}

// ---- Auto-save queue --------------------------------------------------------
// Field edits are merged per row and flushed after a short pause. Failed writes
// are re-queued and retried with backoff; nothing is lost while the tab is open.

const pending = new Map(); // "table:id" -> { table, id, patch }
// SQLSTATE / PostgREST codes that retrying cannot fix (validation, constraint, permission, unknown column / row)
const PERMANENT = /^(22\w{3}|23\w{3}|42501|42703|PGRST(1|2)\d\d)$/;
const MAX_AUTO_RETRIES = 6;   // 2 + 4 + 8 + 16 + 30 s: about a minute of automatic retries, then only on the next trigger
const inflight = new Map(); // "table:id" -> patch currently being written
const statusListeners = new Set();
let timer = null;
let flushing = false;
let failures = 0;
let status = 'idle';

function setStatus(s) {
  status = s;
  statusListeners.forEach((fn) => fn(s));
}

function schedule(ms) {
  clearTimeout(timer);
  timer = setTimeout(flush, ms);
}

async function flush() {
  clearTimeout(timer);
  timer = null;
  if (flushing || pending.size === 0) return;
  if (!navigator.onLine) {
    setStatus('offline');
    return;
  }

  flushing = true;
  setStatus('saving');
  const batch = [...pending.values()];
  pending.clear();
  batch.forEach((b) => inflight.set(`${b.table}:${b.id}`, b.patch));

  const results = await Promise.all(
    batch.map((b) =>
      supabase.from(b.table).update(b.patch).eq('id', b.id).then(
        ({ error }) => ({ b, error }),
        (error) => ({ b, error }),
      ),
    ),
  );

  inflight.clear();
  flushing = false;

  results.filter((r) => r.error && GOVERNANCE_CODES.has(r.error.code)).forEach(({ b, error }) => refuseWrite(b.table, b.id, b.patch, error));
  // A write the server will never accept (validation, permission, constraint) is not retried forever: it is dropped, the
  // player is told why, and the sheet reloads the stored values (the same path as a governance refusal).
  results.filter((r) => r.error && !GOVERNANCE_CODES.has(r.error.code) && PERMANENT.test(r.error.code || '')).forEach(({ b, error }) => {
    toast(`Not saved: ${friendlyError(error)}`, 'bad');
    window.dispatchEvent(new CustomEvent('tavern:save-refused', { detail: { table: b.table, id: b.id, patch: b.patch, error } }));
  });
  const failed = results.filter((r) => r.error && !GOVERNANCE_CODES.has(r.error.code) && !PERMANENT.test(r.error.code || ''));
  failed.forEach(({ b }) => {
    const key = `${b.table}:${b.id}`;
    const newer = pending.get(key)?.patch;
    pending.set(key, { table: b.table, id: b.id, patch: { ...b.patch, ...newer } });
  });

  if (failed.length) {
    failures += 1;
    console.error('Auto-save failed:', failed[0].error);
    // bounded: after MAX_AUTO_RETRIES the edits stay queued (nothing is lost) and are sent again on the next edit, when the
    // connection returns or when the tab is hidden or closed, but no timer keeps retrying (e.g. a server under load, 57014)
    if (!navigator.onLine) setStatus('offline');
    else if (failures >= MAX_AUTO_RETRIES) { setStatus('stalled'); return; }
    else setStatus('error');
    schedule(Math.min(30000, 1000 * 2 ** failures));
  } else {
    failures = 0;
    if (pending.size) {
      setStatus('pending');
      schedule(300);
    } else {
      setStatus('saved');
    }
  }
}

export const saver = {
  queue(table, id, patch) {
    const key = `${table}:${id}`;
    const cur = pending.get(key);
    pending.set(key, { table, id, patch: { ...cur?.patch, ...patch } });
    setStatus('pending');
    schedule(600);
  },
  /** Fields with unsaved local edits — remote updates must not clobber them. */
  protectedFields(table, id) {
    const key = `${table}:${id}`;
    return { ...inflight.get(key), ...pending.get(key)?.patch };
  },
  discard(table, id) {
    pending.delete(`${table}:${id}`);
  },
  flush,
  hasPending: () => pending.size > 0 || flushing,
  onStatus(fn) {
    statusListeners.add(fn);
    fn(status);
    return () => statusListeners.delete(fn);
  },
};

window.addEventListener('online', () => flush());
window.addEventListener('offline', () => { if (pending.size) setStatus('offline'); });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flush(); });
window.addEventListener('beforeunload', (e) => {
  if (saver.hasPending()) {
    flush();
    e.preventDefault();
    e.returnValue = '';
  }
});

// ---- Realtime ---------------------------------------------------------------

const CHILD_TABLES = ['inventory_items', 'character_equipment', 'character_proficiencies', 'character_lineages', 'character_lineage_choices', 'character_backgrounds', 'character_transformations', 'character_spellcasting_sources', 'character_spells', 'character_classes', 'character_spell_slot_state', 'character_temporary_spell_slots', 'character_resources', 'character_feature_choices', 'character_optional_features', 'character_feats', 'character_feat_choices', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells'];

// A DELETE event carries only the primary key (RLS), and DELETE cannot be filtered server-side, so every open sheet receives
// the deletes of every character. Where the key holds no character_id, the subscription learns which keys belong to its
// character (one small read per table, on the first such delete) and drops the others: a delete on character X no longer
// makes every sheet re-read its derived stats (incident 2026-10-23, docs/REALTIME_SUBSCRIPTION_ARCHITECTURE.md).
const KEY_ONLY_DELETE = {
  character_classes: ['id'], character_feature_choices: ['id'], character_proficiencies: ['id'], character_resources: ['id'],
  character_spellcasting_sources: ['id'], character_spells: ['id'], character_temporary_spell_slots: ['id'], inventory_items: ['id'],
  character_optional_features: ['character_class_id', 'unlock_id'], character_feats: ['id'],
};
const keyOf = (table, row) => KEY_ONLY_DELETE[table].map((k) => row?.[k]).join('|');

/**
 * Subscribe to every change affecting one character.
 * handler(table, eventType, newRow, oldRow); onResync() once the connection is back after a drop.
 * Returns a function that removes the channel.
 */
export function subscribeCharacter(id, handler, onResync) {
  const owned = new Map();      // table -> Set of keys of this character's rows (learned on the first key-only DELETE)
  // table -> { inserted, deleted } keys seen while its read is in flight (the read's snapshot may predate them)
  const learning = new Map();
  let epoch = 0;                // a read started before a connection drop is discarded
  async function learn(table) {
    const mine = { inserted: new Set(), deleted: new Set() };
    const at = epoch;
    learning.set(table, mine);
    const { data, error } = await supabase.from(table).select(KEY_ONLY_DELETE[table].join(',')).eq('character_id', id);
    if (learning.get(table) === mine) learning.delete(table);
    if (error || at !== epoch) return;
    const keys = new Set((data || []).map((r) => keyOf(table, r)));
    mine.inserted.forEach((k) => keys.add(k));
    mine.deleted.forEach((k) => keys.delete(k));
    owned.set(table, keys);
  }
  /** Is this DELETE one of this character's rows? Unknown is treated as yes (the sheet re-reads, as before). */
  function ownsDeleted(table, old) {
    if (old?.character_id) return old.character_id === id;
    if (!KEY_ONLY_DELETE[table]) return true;
    const known = owned.get(table);
    if (known) return known.delete(keyOf(table, old));
    if (learning.has(table)) learning.get(table).deleted.add(keyOf(table, old));
    else learn(table);
    return true;
  }
  const deliver = (table) => (p) => {
    if (p.eventType === 'DELETE' && !ownsDeleted(table, p.old)) return;
    if (p.eventType === 'INSERT' && KEY_ONLY_DELETE[table]) {
      owned.get(table)?.add(keyOf(table, p.new));
      learning.get(table)?.inserted.add(keyOf(table, p.new));
    }
    handler(table, p.eventType, p.new, p.old);
  };

  let channel = supabase
    .channel(`character-${id}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'characters', filter: `id=eq.${id}` }, deliver('characters'));

  for (const table of CHILD_TABLES) {
    channel = channel
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table, filter: `character_id=eq.${id}` }, deliver(table))
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table, filter: `character_id=eq.${id}` }, deliver(table))
      // DELETE events cannot be filtered server-side: ownsDeleted() drops other characters' rows, the handler ignores unknown ids.
      .on('postgres_changes', { event: 'DELETE', schema: 'public', table }, deliver(table));
  }

  // after the connection dropped (laptop sleep, network loss) events of that time are lost: once the channel is back, the
  // sheet reloads its stored values (V6.2). The first SUBSCRIBED is the normal start, not a resync. Learned keys may be
  // stale after a drop, so they are learned again.
  let dropped = false;
  channel.subscribe((status) => {
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') dropped = true;
    else if (status === 'SUBSCRIBED' && dropped) { dropped = false; epoch += 1; owned.clear(); learning.clear(); onResync?.(); }
  });
  return () => supabase.removeChannel(channel);
}

/**
 * Fluent read path: ONE channel with 2 bindings instead of the legacy 70 (docs/REALTIME_SUBSCRIPTION_ARCHITECTURE.md).
 *  - characters UPDATE (filtered): the row itself, so HP / coins / notes fields are patched without any read;
 *  - character_revisions INSERT (filtered): {source_table, id = revision} once per committed transaction and table (an
 *    append-only log); the sheet refreshes only that table's domain.
 * Events carry no hidden data: a revision row says only which table of a readable character changed.
 * onRevision(table, rev); onResync() once after a dropped connection (the sheet reconciles revisions, no full reload);
 * onLive() each time Realtime confirms it delivers changes (after the first join AND after every rejoin). A reconnect therefore
 * calls both onResync and onLive: the caller must merge them (js/sheet.js catchUpSoon: one shared debounce, one read).
 */
export function subscribeCharacterFluent(id, handler, onRevision, onResync, onLive) {
  const rev = (p) => { if (p.new?.character_id === id && p.new?.source_table) onRevision(p.new.source_table, Number(p.new.id) || 0); };
  const channel = supabase
    .channel(`sheet-${id}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'characters', filter: `id=eq.${id}` }, (p) => handler('characters', p.eventType, p.new, p.old))
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'character_revisions', filter: `character_id=eq.${id}` }, rev)
    // 'SUBSCRIBED' (phx_reply) comes BEFORE Realtime delivers postgres changes: the server confirms that later with a system
    // message "Subscribed to PostgreSQL" (seconds later when Realtime is cold). A change committed in that gap is never
    // delivered, so once changes are live the sheet checks its revisions once (onLive: one small read, only changed domains).
    .on('system', {}, (p) => { if (p?.extension === 'postgres_changes' && p?.status === 'ok') onLive?.(); });
  let dropped = false;
  channel.subscribe((status) => {
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') dropped = true;
    else if (status === 'SUBSCRIBED' && dropped) { dropped = false; onResync?.(); }
  });
  return () => supabase.removeChannel(channel);
}

// ---- Portraits (Supabase Storage bucket "portraits") -------------------------------

const PORTRAIT_MARKER = '/storage/v1/object/public/portraits/';

/** Shrink an image file to at most `max` px on its longest side, as JPEG. */
async function resizeImage(file, max = 512) {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, max / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not process the image.'))), 'image/jpeg', 0.85));
}

export async function uploadPortrait(characterId, file) {
  if (!file.type.startsWith('image/')) throw new Error('Please choose an image file.');
  const blob = await resizeImage(file);
  const path = `${characterId}/${Date.now()}.jpg`;
  const { error } = await supabase.storage.from('portraits').upload(path, blob, {
    contentType: 'image/jpeg', cacheControl: '31536000', upsert: false,
  });
  if (error) throw error;
  return supabase.storage.from('portraits').getPublicUrl(path).data.publicUrl;
}

/** Delete a previously uploaded portrait file. Ignores external URLs and errors. */
export async function removePortraitFile(url) {
  const i = String(url || '').indexOf(PORTRAIT_MARKER);
  if (i < 0) return;
  const path = decodeURIComponent(url.slice(i + PORTRAIT_MARKER.length).split('?')[0]);
  await supabase.storage.from('portraits').remove([path]).catch(() => {});
}
