import { supabase } from './supabase.js';
import { CLASS_HIT_DIE, NOTE_KINDS, dieSize } from './dnd.js';

export const state = {
  session: null,
  profile: null,
  profiles: [], // DM only: every profile
};

export const isDM = () => state.profile?.role === 'dm';

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

// ---- Characters -------------------------------------------------------------

export async function listCharacters() {
  return check(
    await supabase
      .from('characters')
      .select('id, owner_id, name, race, class_name, subclass, level, hp_current, hp_max, hp_temp, ac, updated_at')
      .order('name'),
  );
}

export async function createCharacter({ name, race, class_name, level, owner_id }) {
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
  return check(await supabase.from('characters').insert(row).select().single());
}

export async function deleteCharacter(id) {
  check(await supabase.from('characters').delete().eq('id', id));
}

export async function loadBundle(id) {
  const [character, inventory, notes, slots, trackers, features] = await Promise.all([
    supabase.from('characters').select('*').eq('id', id).single().then(check),
    supabase.from('inventory_items').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('notes').select('*').eq('character_id', id).then(check),
    supabase.from('spell_slots').select('*').eq('character_id', id).order('level').then(check),
    supabase.from('feature_trackers').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
    supabase.from('features').select('*').eq('character_id', id).order('sort_order').order('created_at').then(check),
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

  return { character, inventory, notes, slots, trackers, features };
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

const CHILD_TABLES = ['inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features'];

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
