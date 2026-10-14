import { supabase } from './supabase.js?v=5';
import { CLASS_HIT_DIE, NOTE_KINDS, dieSize } from './dnd.js?v=5';

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
      .select('id, owner_id, campaign_id, name, race, class_name, subclass, level, hp_current, hp_max, hp_temp, ac, portrait_url, conditions, updated_at')
      .order('name'),
  );
}

export async function createCharacter({ name, race, class_name, level, owner_id, campaign_id }) {
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
  if (owner_id) row.owner_id = owner_id;
  if (campaign_id) row.campaign_id = campaign_id;
  return check(await supabase.from('characters').insert(row).select().single());
}

export async function deleteCharacter(id) {
  check(await supabase.from('characters').delete().eq('id', id));
}

export async function loadBundle(id) {
  const [character, inventory, notes, slots, trackers, features, attacks, spells] = await Promise.all([
    supabase.from('characters').select('*').eq('id', id).single().then(check),
    supabase.from('inventory_items').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('notes').select('*').eq('character_id', id).then(check),
    supabase.from('spell_slots').select('*').eq('character_id', id).order('level').then(check),
    supabase.from('feature_trackers').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('features').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('attacks').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('spells').select('*').eq('character_id', id).order('level').order('sort_order').order('created_at').then(check),
  ]);

  // Self-heal characters that are missing seeded rows.
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

export async function insertRow(table, row) {
  return check(await supabase.from(table).insert(row).select().single());
}

export async function insertRows(table, rows) {
  if (!rows.length) return [];
  return check(await supabase.from(table).insert(rows).select());
}

export async function updateRow(table, id, patch) {
  check(await supabase.from(table).update(patch).eq('id', id));
}

export async function deleteRow(table, id) {
  saver.discard(table, id);
  check(await supabase.from(table).delete().eq('id', id));
}

// ---- Auto-save queue --------------------------------------------------------
// Field edits are merged per row and flushed after a short pause. Failed writes
// are re-queued and retried with backoff; nothing is lost while the tab is open.

const pending = new Map(); // "table:id" -> { table, id, patch }
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

  const failed = results.filter((r) => r.error);
  failed.forEach(({ b }) => {
    const key = `${b.table}:${b.id}`;
    const newer = pending.get(key)?.patch;
    pending.set(key, { table: b.table, id: b.id, patch: { ...b.patch, ...newer } });
  });

  if (failed.length) {
    failures += 1;
    console.error('Auto-save failed:', failed[0].error);
    setStatus(navigator.onLine ? 'error' : 'offline');
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

const CHILD_TABLES = ['inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells'];

/**
 * Subscribe to every change affecting one character.
 * handler(table, eventType, newRow, oldRow)
 */
export function subscribeCharacter(id, handler) {
  let channel = supabase
    .channel(`character-${id}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'characters', filter: `id=eq.${id}` },
      (p) => handler('characters', p.eventType, p.new, p.old));

  for (const table of CHILD_TABLES) {
    channel = channel
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table, filter: `character_id=eq.${id}` },
        (p) => handler(table, p.eventType, p.new, p.old))
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table, filter: `character_id=eq.${id}` },
        (p) => handler(table, p.eventType, p.new, p.old))
      // DELETE events cannot be filtered server-side; the handler ignores unknown ids.
      .on('postgres_changes', { event: 'DELETE', schema: 'public', table },
        (p) => handler(table, p.eventType, p.new, p.old));
  }

  channel.subscribe();
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
