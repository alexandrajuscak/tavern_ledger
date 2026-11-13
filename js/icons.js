// One illustrated icon family (assets/icons, see docs/UI_ICON_SYSTEM.md). Icons support text, they never replace it:
// icon() is decorative (alt="") unless a label is given, and every caller shows the meaning in text or an accessible name.
// Every icon goes through the registry (js/icon-registry.js): semantic key -> asset, label, fallback. No other module builds
// asset paths. A name may be a semantic key ("spell.damage.fire") or the older asset name ("damage-types/fire").
import { esc } from './utils.js?v=28';
import { ICON_REGISTRY } from './icon-registry.js?v=28';

const BASE = 'assets/icons';
const GENERIC = 'generic';

// asset name ("ui/attack") -> its own (non-alias) semantic key; asset group ("ui") -> the group's fallback key
const BY_ASSET = new Map();
const GROUP_FALLBACK = new Map();
for (const [k, v] of Object.entries(ICON_REGISTRY)) {
  if (!v.alias_of && !BY_ASSET.has(v.asset)) BY_ASSET.set(v.asset, k);
  if (!v.alias_of && !GROUP_FALLBACK.has(v.group)) GROUP_FALLBACK.set(v.group, v.fallback || GENERIC);
}
const warned = new Set();

/**
 * The registry entry for a name, following the fallback chain: specific key -> category fallback -> generic.
 * Never returns nothing: an unknown name resolves to the generic icon (and warns once in the console).
 */
export function resolveIcon(name) {
  const raw = String(name || '');
  let key = ICON_REGISTRY[raw] ? raw : BY_ASSET.get(raw);
  if (!key) {
    if (!warned.has(raw)) { warned.add(raw); console.warn(`[icons] unknown icon "${raw}", using a fallback`); }
    key = GROUP_FALLBACK.get(raw.split('/')[0]) || GENERIC;
  }
  for (let i = 0; i < 4 && !ICON_REGISTRY[key]; i += 1) key = GENERIC;
  return { key, ...ICON_REGISTRY[key] };
}

/** Path of an icon (semantic key or asset name). The only place that builds icon URLs. */
export const iconSrc = (name) => `${BASE}/${resolveIcon(name).asset}.webp`;

/** Path of the fallback of an icon (used when its file fails to load). */
function fallbackSrc(key) {
  const fb = ICON_REGISTRY[key]?.fallback || GENERIC;
  return `${BASE}/${(ICON_REGISTRY[fb] || ICON_REGISTRY[GENERIC]).asset}.webp`;
}

/**
 * <img> for an icon. size in CSS px; label makes it meaningful (alt text), otherwise it is decorative.
 * labelled: true uses the registry label as the alt text.
 */
export function icon(name, { label = '', labelled = false, size = 20, cls = '' } = {}) {
  if (!name) return '';
  const r = resolveIcon(name);
  const alt = label || (labelled ? r.label : '');
  return `<img class="tl-icon ${esc(cls)}" src="${esc(`${BASE}/${r.asset}.webp`)}" width="${size}" height="${size}" loading="lazy" decoding="async"
    data-icon="${esc(r.key)}" alt="${esc(alt)}"${alt ? '' : ' aria-hidden="true"'}>`;
}

// A file that fails to load (missing, corrupt) is replaced by its fallback at the same size, then by the generic icon.
if (typeof document !== 'undefined') {
  document.addEventListener('error', (e) => {
    const img = e.target;
    if (!(img instanceof HTMLImageElement) || !img.classList.contains('tl-icon')) return;
    const step = Number(img.dataset.fallbackStep || 0);
    if (step >= 2) return;
    img.dataset.fallbackStep = String(step + 1);
    img.src = step === 0 ? fallbackSrc(img.dataset.icon) : `${BASE}/${ICON_REGISTRY[GENERIC].asset}.webp`;
  }, true);
}

const key = (s) => String(s || '').trim().toLowerCase().replace(/[^a-z]+/g, '-').replace(/^-|-$/g, '');
const has = (k) => !!ICON_REGISTRY[k];

export const conditionIcon = (name, opts) => icon(has(`condition.${key(name)}`) ? `condition.${key(name)}` : 'condition.generic-effect', opts);

/** Class emblem by class name ("Paladin", "Paladin (Devotion)"); falls back to the generic class icon. */
export function classIcon(name, opts) {
  const k = key(String(name || '').split(/[\s(/·]/)[0]);
  return icon(has(`class.${k}`) ? `class.${k}` : 'ui.build', opts);
}

/** Icon names of the sheet sections (also used by the bottom navigation). */
export const SECTION_ICONS = {
  combat: 'section.play', stats: 'section.abilities', spells: 'section.spells', inventory: 'section.inventory', features: 'section.build', bio: 'section.bio',
};

/** Timing icons for actions, bonus actions and reactions. */
export const TIMING_ICONS = { action: 'ui.attack', bonus_action: 'ui.bonus-action', reaction: 'ui.reaction', special: 'ui.condition', passive: 'ui.feat' };

/** Inventory categories (inventory filter keys) → icon. */
export const ITEM_ICONS = {
  all: 'ui.inventory', weapon: 'inventory.weapon', weapons: 'inventory.weapon', armor: 'inventory.armor', consumable: 'item.consumables',
  consumables: 'item.consumables', magic: 'item.magic', ammunition: 'item.ammunition', tool: 'item.tools', tools: 'item.tools',
  gear: 'item.gear', container: 'item.containers', containers: 'item.containers', potion: 'potion.healing', potions: 'potion.generic', scroll: 'item.spell-scroll',
  herbs: 'plant.herb', herbs_plants: 'plant.herb',
  wand: 'item.wand', ring: 'slot.ring', mount: 'item.mount', vehicle: 'item.vehicle', firearm: 'item.firearm',
};
