import {
  ABILITIES, ABILITY_BY_KEY, SKILLS, SKILL_BY_KEY, CLASSES, HIT_DICE, ALIGNMENTS,
  RESOURCE_PRESETS, RESET_LABELS, FEATURE_CATEGORIES,
  DAMAGE_TYPES, SPELL_EFFECT_TYPES, SPELL_SCHOOLS, ATTACK_ABILITIES, EQUIPMENT_PROFICIENCIES, WEAPONS,
  ACTIVATIONS, ACTIVATION_BY_KEY, CASTING_TIMES, CONDITIONS, CONDITION_BY_NAME,
  weaponToAttack, ordinal, castingGroup, skillLevel, skillValue, mod, profBonus, xpForNextLevel, levelForXp,
} from './dnd.js?v=34';
import {
  saver, insertRow, deleteRow, deleteCharacter, applyCharacterHp, subscribeCharacter, subscribeCharacterFluent, state, isAdmin, canManageCharacter, myCampaigns, campaignMembers, uploadPortrait, removePortraitFile,
  isCampaignDM, getCharacterConditions, applyCharacterEffect, updateCharacterEffect, removeCharacterCondition,
} from './store.js?v=34';
import { $, $$, esc, clamp, toast, confirmDialog, openModal, cacheSet, debounce, autoResize } from './utils.js?v=34';
import { openCoinCalculator, wallet as coinWallet } from './coins.js?v=34';
import { mountInventory } from './inventory-ui.js?v=34';
import { exportCharacter, downloadJson } from './transfer.js?v=34';
import { getDerivedStats, getProficiencies, setCharacterProficiency, getLookups, syncPartyKnowledge, revertPermanentEffect } from './inventory-api.js?v=34';
import { backgroundCardHTML, openBackgroundPicker, openBackgroundEquipment, openReplaceDuplicate, saveCharacteristics, rollCharacteristic,
  removeBackground } from './background-ui.js?v=34';
import { getCharacterBackground } from './background-api.js?v=34';
import { wildShapePanelHTML, openFormPicker, openTransformReview, openAdjust, openCombatHeal, confirmRevert, confirmLethal } from './wild-shape-ui.js?v=34';
import { proficiencyChipsHTML, proficiencyDetailsHTML, openProficiencySource, sourceText, derivedSources } from './proficiency-ui.js?v=34';
import {
  acNote, openAcBreakdown, equippedWeaponsHTML, trackWeaponDetails, toolsHTML, specificProficienciesHTML,
  openProficiencyManager, equipmentNotes,
} from './derived-ui.js?v=34';
import { openLevelUp } from './levelup.js?v=34';
import { mountGovernance } from './request-ui.js?v=34';
import { beginSheetReads, endSheetReads, isAbortError } from './read-control.js?v=34';
import { fluentEnabled, beginReadScope, endReadScope, seedReads, prefetchDomain, readNow, knownRevision, noteRevisions, awaitSeed } from './read-layer.js?v=34';
import { featsCardHTML, attachFeatHandlers, loadCharacterFeats } from './feat-ui.js?v=34';
import { exportFeats } from './feat-api.js?v=34';
import { getCharacterLineage, getLineageReference, getLineageCatalog } from './lineage-api.js?v=34';
import { lineageCardHTML, lineageStatsHTML, lineageSpellsHTML, openLineagePicker, removeLineage, suggestLineage } from './lineage-ui.js?v=34';
import { getSpellbook, getSpellReference, setSpellPrepared } from './spell-api.js?v=34';
import {
  emptyFilters, filtersHTML, readFilter, sourcesHTML, spellbookListHTML, openSpellDetail, openAddSpell, openSourceEditor, rememberSpellSections,
} from './spell-ui.js?v=34';
import {
  getClassSummary, getSpellSlots, getClassCatalog, expendStandardSlot, restoreStandardSlot, expendPactSlot, restorePactSlot,
  setSlotState, setCharacterClass, shortRest, longRest, getClassFeatures, getResources, exportClassFeatures, useTemporarySlot,
  restoreTemporarySlot, getStartingEquipmentState, getStartingEquipment, getStates, expendResource,
} from './class-api.js?v=34';
import { slotActionsHTML, openRecoverSlots, openFlexibleCasting, riderSlotButton, openSlotRider } from './slot-actions.js?v=34';
import { classCardHTML, openClassEditor, changeClassLevel, removeClass, slotTrackerHTML, slotChangeMessage, restDescription } from './class-ui.js?v=34';
import { openStartingEquipment } from './class-setup.js?v=34';
import {
  companionsHTML, openAddCompanion, changeCompanionHp, removeCompanionConfirm,
} from './creature-ui.js?v=34';
import { getTransformation, getCompanions, endTransformation, damageForm, healForm, useFormAbility, setFormEquipment } from './creature-api.js?v=34';
import { infusionsHTML, getInfusions, openInfuse, endInfusion, refreshInfusions } from './infusion-ui.js?v=34';
import { selectedOptions, optionCardHTML, reminderListHTML, infusionsPlayHTML, optionSpellsHTML, infusedItemMap, loadPlayTiming, sourceFeatures,
  sourceCardHTML, sourceReminderListHTML } from './active-features.js?v=34';
import {
  featuresPanelHTML, featureSummaryHTML, restoreDrafts, resourceListHTML, attachFeatureHandlers, hydrateSpellChoices, restResourceLines, restResultText, restSummaryHTML,
  riderDiceRange, statesHTML, glanceHTML,
} from './feature-ui.js?v=34';
import { icon, classIcon, SECTION_ICONS, TIMING_ICONS } from './icons.js?v=34';
import { sectionHTML, sectionHead } from './section.js?v=34';
import { distanceNumber, distanceUnit, onUnitsChange, unitsSwitchHTML, bindUnitsSwitch } from './units.js?v=34';

// -----------------------------------------------------------------------------
// Module state — one sheet is mounted at a time.
// -----------------------------------------------------------------------------

let B = null; // bundle: { character, inventory, notes, slots, trackers, features, attacks, spells }
let root = null;
let ctx = null; // { reload, onDeleted }
let unsubscribe = null;
let liveCharacterId = null;  // the character of the Realtime channel: kept when the same sheet is reloaded (no leave + join)
let liveFluent = false;      // which subscription the kept channel is (legacy 70 bindings or fluent 2)
let liveReady = false;       // fluent: Realtime confirmed it delivers changes on the kept channel ("Subscribed to PostgreSQL")
// Fluent read path (js/read-layer.js): this sheet was mounted from one get_character_view response; its later reads are
// coalesced, Realtime is one revision table, the inventory panel loads on its first open. Never mixed with the legacy path.
let sheetFluent = false;
let inventoryDeferred = false;
let serverChar = null;       // the character row as last stored on the server (bundle, Realtime): what a remote UPDATE changed
let inventory = null; // inventory-ui controller
let quests = null;    // js/quests.js tab controller (loaded on the Quests tab's first open)
let questsSeq = 0;
let lastInfusedSig = '[]';
let governance = null; // request-ui controller: lock banner, pending changes, approval requests
let featState = null;   // get_character_feats: every feat grant with its source, choices, effects, spells and resources
let featSeq = 0;
const editing = new Set(); // "table:id" of attack/spell cards open for editing
// Derived stats (AC, speed, equipped weapons, warnings) come from get_character_derived_stats; never stored.
let derived = null;
// Resolved proficiencies (get_character_proficiencies): every proficiency with all its sources; profPending holds a manual
// chip change until the server answers (shown at once, replaced by the authoritative result).
let profState = null;
let profPending = {};
let derivedSeq = 0;
let derivedDirty = false;  // a local edit of a field that affects derived stats is waiting to be saved
let unsubSaver = null;
let unsubUnits = null;   // js/units.js onUnitsChange
// Resolved lineage (get_character_lineage): traits, choices and their status; never stored on the character.
let lineage = null;
// Background (get_character_background): version, ability increases, grants, feat, equipment state; never stored here.
let background = null;
let backgroundSeq = 0;
let lineageSeq = 0;
let lineageRef = null;
let lineageSuggestion = null;   // a reliable catalog match for an old free-text race (exact name), else null
// Resolved spellbook (get_character_spellbook): sources with their own Save DC / attack bonus, spells with every grant.
let spellbook = null;
let spellbookSeq = 0;
let spellRef = null;
const spellFilters = emptyFilters();
// Classes and spell slots (get_character_class_summary / get_character_spell_slots): levels, PB, slots; never stored.
let classSummary = null;
let slotState = null;
let classCatalog = null;
let classSeq = 0;
// Slot mutations (Use / Restore): one request per slot line at a time; the RPC result is authoritative. A read that overlaps a
// mutation (Realtime refresh, class reload) may hold the state from before it, so it never overwrites the slots (slotEpoch).
let slotBusy = new Set();
let slotEpoch = 0;
let slotMutSeq = 0;
let slotMutApplied = 0;
let slotsSeq = 0;
// Class feature engine (get_character_class_features / get_character_resources): features, choices, resources; never stored.
let classFeatures = null;
let classResources = null;
// Resource-only refresh (loadResources): a class read that overlaps one re-reads the resources afterwards (resEpoch)
let resSeq = 0;
let resEpoch = 0;
let startEqState = null;
let classStates = null;       // get_character_states: Rage-style states (Start / End)
let transformState = null;    // get_character_transformation: Wild Shape forms and the current form
// Wild Shape mutations: one request per control at a time; a read that overlaps a change never overwrites it (tfEpoch)
let tfBusy = new Set();
let tfEpoch = 0;
let tfSeq = 0;
let companions = null;        // character_companions with their catalog creature
let playTiming = null;        // catalog_play_timing (lineage traits and feats in Play), read once per page session
let infusionState = null;     // get_character_infusions: known infusions and infused items      // {class_version_id, applied, has_options} of the primary class (starting equipment review)
const hasClasses = () => (classSummary?.classes?.length || 0) > 0;
const DERIVED_FIELDS = new Set(['strength', 'dexterity', 'constitution', 'intelligence', 'wisdom', 'charisma', 'level', 'speed', 'ac_override']);
// characters columns the derived-stats SQL never reads (checked against _derived_stats_core/_full, _feat_layer, _wild_shape_layer
// and their helpers, 2026-10-29): a remote UPDATE of only these (HP, coins, death saves …) does not re-read the derived stats.
// The Wild Shape layer reads name, hp_current and hp_temp of the character, so those count while a form is active.
const NON_DERIVED_FIELDS = new Set(['race', 'class_name', 'subclass', 'background', 'alignment', 'experience', 'hit_die', 'hit_dice_current',
  'death_successes', 'death_failures', 'inspiration', 'cp', 'sp', 'ep', 'gp', 'pp', 'portrait_url', 'pending_choices', 'updated_at']);
const FORM_FIELDS = new Set(['name', 'hp_current', 'hp_temp']);
const PROF_GROUP_BY_FLAG = { simple: 'simple-weapons', martial: 'martial-weapons', firearms: 'firearms', light: 'light-armor',
  medium: 'medium-armor', heavy: 'heavy-armor', shields: 'shields' };

// Six sections, ordered by how often they are used at the table (docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md). The keys are the
// historical ones (stable deep links, stored tab, tests); the labels are what the player sees. `short` is the bottom-bar label.
const TABS = [
  { key: 'combat', label: 'Play', short: 'Play', hint: 'Attacks, actions, resources and active effects' },
  { key: 'stats', label: 'Abilities', short: 'Abilities', hint: 'Ability scores, saving throws, skills and proficiencies' },
  { key: 'spells', label: 'Spells', short: 'Spells', hint: 'Spell slots and the spells you can cast' },
  { key: 'inventory', label: 'Inventory', short: 'Items', hint: 'Equipment, items and coins' },
  { key: 'features', label: 'Build', short: 'Build', hint: 'Classes, lineage, background, feats and level-ups' },
  { key: 'quests', label: 'Quests', short: 'Quests', hint: 'Party and personal quests from your DM' },
  { key: 'bio', label: 'Bio', short: 'Bio', hint: 'Identity, portrait, notes and backup' },
];
// sections that were merged into others (older stored tab, links in older builds)
const TAB_ALIAS = { attacks: 'combat', resources: 'combat', notes: 'bio' };

const LIST_KEY = {
  inventory_items: 'inventory',
  notes: 'notes',
  spell_slots: 'slots',
  feature_trackers: 'trackers',
  features: 'features',
  attacks: 'attacks',
  spells: 'spells',
};

const C = () => B.character;
const rowsOf = (table) => (table === 'characters' ? [B.character] : B[LIST_KEY[table]]);
const findRow = (table, id) => rowsOf(table).find((r) => r.id === id);
const note = (kind) => B.notes.find((n) => n.kind === kind);

const getTab = () => {
  let t = 'combat';
  try { t = localStorage.getItem('tavern-ledger:tab') || 'combat'; } catch { /* ignore */ }
  return TAB_ALIAS[t] || t;
};
const setTab = (t) => { try { localStorage.setItem('tavern-ledger:tab', t); } catch { /* ignore */ } };
/** The section a sheet opens on (the character view loads that domain together with the shell). */
export const activeTabKey = () => { const t = TAB_ALIAS[getTab()] || getTab(); return TABS.some((x) => x.key === t) ? t : 'combat'; };

// the legacy path keeps an offline copy of the stored rows; the fluent path never persists character data in localStorage
// (nor does a sheet that fell back to the legacy reads while the fluent path is on)
const cacheLater = debounce(() => { if (B && !sheetFluent && !fluentEnabled()) cacheSet(`bundle:${C().id}`, B); }, 1000);

// -----------------------------------------------------------------------------
// Derived values
// -----------------------------------------------------------------------------

// Signed modifiers on the sheet: "+3", "+0", and a true minus sign for negatives ("−1").
const fmt = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const pb = () => derived?.proficiency_bonus?.value ?? profBonus(C().level);   // the server value is authoritative
// Effective score = stored base + the server's lineage/item adjustment (instant while an edited base is still saving).
const abilityScore = (key) => {
  const a = derived?.abilities?.[key];
  return C()[ABILITY_BY_KEY[key].col] + (a ? a.score - a.base : 0);
};
const abilityMod = (key) => mod(abilityScore(key));
const profEntry = (kind, id) => profState?.[kind]?.find((e) => e.id === id) || null;
// level granted by sources other than the manual mark (class, feature, lineage, background), from the resolver
const grantedLevel = (kind, id, kinds = ['class', 'feature', 'background', 'item']) => {
  const ds = derivedSources(profEntry(kind, id)).filter((x) => kinds.includes(x.kind));
  return ds.some((x) => x.expertise) ? 2 : ds.length ? 1 : 0;
};
const lineageSkill = (key) => !!derived?.skills?.[key]?.lineage_proficient;
const saveManual = (key) => !!C().save_proficiencies?.[key];
const classSave = (key) => !!derived?.saving_throws?.[key]?.class_proficient || grantedLevel('saves', key) > 0;
const saveProf = (key) => saveManual(key) || classSave(key);
const skillProf = (key) => skillLevel(C().skill_proficiencies?.[key]); // 0 none, 1 proficient, 2 expertise (stored on the character)
const classSkill = (key) => Math.max(derived?.skills?.[key]?.class_expertise ? 2 : derived?.skills?.[key]?.class_proficient ? 1 : 0, grantedLevel('skills', key));
const skillTotal = (key) => Math.max(skillProf(key), lineageSkill(key) ? 1 : 0, classSkill(key));
const itemSaveBonus = (key) => Number(derived?.saving_throws?.[key]?.item_bonus) || 0;
// a class feature that adds an ability modifier to your saves (an aura): the server sends the best value per save
const classSaveBonus = (key) => Number(derived?.saving_throws?.[key]?.class_bonus) || 0;
// in Wild Shape the server's form totals decide (the higher of your proficiency and the form's printed bonus)
const saveBonus = (key) => (derived?.saving_throws?.[key]?.form_total != null ? Number(derived.saving_throws[key].form_total)
  : abilityMod(key) + (saveProf(key) ? pb() : 0) + itemSaveBonus(key) + classSaveBonus(key));
// half proficiency (Jack of All Trades, Remarkable Athlete …): the server says which skills qualify; only without proficiency
const skillHalf = (key) => (skillTotal(key) ? 0 : Number(derived?.skills?.[key]?.half_proficiency?.value) || 0);
// a numeric skill bonus from items (20261114000500: skill_bonus, e.g. +3 Religion while attuned)
const itemSkillBonus = (key) => Number(derived?.skills?.[key]?.item_bonus) || 0;
const skillBonus = (key) => (derived?.skills?.[key]?.form_total != null ? Number(derived.skills[key].form_total)
  : abilityMod(SKILL_BY_KEY[key].ability) + skillTotal(key) * pb() + skillHalf(key) + itemSkillBonus(key));
const initiative = () => abilityMod('dex') + (C().initiative_bonus || 0) + (Number(derived?.initiative?.bonus) || 0);
const castingMod = () => (C().spellcasting_ability ? abilityMod(C().spellcasting_ability) : null);
const spellAttackBonus = () => (castingMod() == null ? null : pb() + castingMod());
const spellSaveDC = () => (castingMod() == null ? null : 8 + pb() + castingMod());

function attackAbilityMod(a) {
  switch (a.ability) {
    case 'str':
    case 'dex': return abilityMod(a.ability);
    case 'finesse': return Math.max(abilityMod('str'), abilityMod('dex'));
    case 'spell': return castingMod() ?? 0;
    default: return 0;
  }
}
const attackToHit = (a) => attackAbilityMod(a) + (a.proficient ? pb() : 0) + (Number(a.magic_bonus) || 0);

function attackDamage(a) {
  const bonus = (a.add_modifier ? attackAbilityMod(a) : 0) + (Number(a.magic_bonus) || 0);
  const dice = String(a.damage_dice || '').trim();
  if (!dice) return String(Math.max(0, bonus));
  if (/^\d+$/.test(dice)) return String(Math.max(0, Number(dice) + bonus));
  if (!bonus) return dice;
  return `${dice} ${bonus > 0 ? '+' : '−'} ${Math.abs(bonus)}`;
}

/** "Paladin 6 (Devotion) · Human" — classes first (multiclass: "Level 5 · Wizard 3 / Warlock 2 · …"). */
function subtitle() {
  const c = C();
  const multi = (classSummary?.classes?.length || 0) > 1;
  const cls = hasClasses()
    ? classSummary.classes.map((k) => `${k.class_name} ${k.level}${k.subclass_name ? ` (${k.subclass_name})` : ''}`).join(' / ')
    : [c.class_name && `${c.class_name} ${c.level}`, c.subclass && `(${c.subclass})`].filter(Boolean).join(' ');
  const lin = derived?.lineage ? [derived.lineage.name, derived.lineage.subversion_name].filter(Boolean).join(' · ') : c.race;
  return [multi || !cls ? `Level ${c.level}` : '', cls, lin].filter(Boolean).join(' · ');
}

function deriveValue(key) {
  const [kind, arg] = key.split(':');
  const c = C();
  switch (kind) {
    case 'name': return c.name || 'Unnamed';
    case 'subtitle': return subtitle();
    case 'mod': return fmt(abilityMod(arg));
    case 'save': return fmt(saveBonus(arg));
    case 'skill': return fmt(skillBonus(arg));
    case 'passive': return String(10 + skillBonus(arg));
    case 'pb': return fmt(pb());
    case 'init': return fmt(initiative());
    case 'level': return String(c.level);
    case 'speed': return distanceNumber(derived?.speed?.value ?? c.speed);   // the viewer's units (js/units.js)
    case 'dist-unit': return distanceUnit();
    case 'spelldc': return c.spellcasting_ability ? String(8 + pb() + abilityMod(c.spellcasting_ability)) : '—';
    case 'spellatk': return c.spellcasting_ability ? fmt(pb() + abilityMod(c.spellcasting_ability)) : '—';
    case 'xpnext': {
      const next = xpForNextLevel(c.level);
      if (next == null) return 'Max level';
      const ready = levelForXp(c.experience) > c.level;
      return ready ? `Ready to level up! (${next.toLocaleString()} XP)` : `Next level at ${next.toLocaleString()} XP`;
    }
    default: return '';
  }
}

function refreshDerived() {
  $$('[data-derive]', root).forEach((el) => {
    const v = deriveValue(el.dataset.derive);
    if (el.textContent !== v) el.textContent = v;
  });
}

function refreshToggles() {
  const c = C();
  $$('[data-action="toggle-save"]', root).forEach((el) => {
    const on = saveProf(el.dataset.k);
    el.classList.toggle('on', on);
    el.classList.toggle('from-class', classSave(el.dataset.k) && !saveManual(el.dataset.k));
    el.setAttribute('aria-pressed', on);
    const e = profEntry('saves', el.dataset.k);
    el.title = e ? `${sourceText(e)}${e.derived ? ' · granted, not removable here' : ''}` : classSave(el.dataset.k) && !saveManual(el.dataset.k) ? 'Proficient (from your class)' : on ? 'Proficient' : 'Not proficient';
  });
  $$('[data-action="cycle-skill"]', root).forEach((el) => {
    const k = el.dataset.k;
    const lvl = skillProf(k);
    const total = skillTotal(k);
    const fromClass = classSkill(k) > lvl && classSkill(k) >= (lineageSkill(k) ? 1 : 0);
    const fromLineage = !fromClass && lineageSkill(k) && lvl === 0;
    el.dataset.level = total;
    el.classList.toggle('from-lineage', fromLineage);
    el.classList.toggle('from-class', fromClass);
    const e = profEntry('skills', k);
    el.title = e ? `${sourceText(e)}${e.derived ? ' · tap to set your own mark (the grant stays)' : ''}`
      : fromClass ? `${['', 'Proficient', 'Expertise'][total]} (from your class)` : fromLineage ? 'Proficient (from your lineage)'
      : ['Not proficient', 'Proficient', 'Expertise'][lvl];
  });
  $$('[data-action="toggle-inspiration"]', root).forEach((el) => {
    el.classList.toggle('on', !!c.inspiration);
    el.setAttribute('aria-pressed', !!c.inspiration);
  });
  $$('[data-action="death"]', root).forEach((el) => {
    const count = el.dataset.kind === 'success' ? c.death_successes : c.death_failures;
    el.classList.toggle('on', Number(el.dataset.i) < count);
    el.setAttribute('aria-pressed', String(Number(el.dataset.i) < count));
  });
  putHTML($('#prof-chips', root), profChipsHTML());
}

/** Re-render the read-only "view" part of attack & spell cards whose content changed. */
function refreshViews() {
  $$('[data-view]', root).forEach((el) => {
    const [table, id] = el.dataset.view.split(':');
    const row = findRow(table, id);
    if (!row) return;
    const html = table === 'attacks' ? attackViewHTML(row) : table === 'features' ? featureViewHTML(row) : spellViewHTML(row);
    if (el.__html !== html) {
      el.innerHTML = html;
      el.__html = html;
    }
  });
}

/** Maximum HP in play: the stored base (the editable field) + feat bonuses resolved by the server (hit_points.feat_bonus). */
const featHpBonus = () => Number(derived?.hit_points?.feat_bonus) || 0;
const hpMax = (c = C()) => Math.max(1, c.hp_max + featHpBonus());

function refreshHp() {
  const c = C();
  const max = hpMax(c);
  const hpNote = $('[data-derived-hp]', root);
  if (hpNote) {
    const bonus = featHpBonus();
    const from = (derived?.hit_points?.feat_sources || []).map((x) => x.source_name.replace(/^Feat: /, '')).join(', ');
    hpNote.hidden = !bonus;
    hpNote.textContent = bonus ? `Maximum ${max}: base ${c.hp_max} + ${bonus} from ${from || 'feats'}.` : '';
  }
  const pct = clamp((c.hp_current / max) * 100, 0, 100);
  const tempPct = clamp((c.hp_temp / max) * 100, 0, 100 - pct);
  const card = $('#hp-card', root);
  if (!card) return;
  $('.hp-fill', card).style.width = `${pct}%`;
  $('.hp-temp-fill', card).style.left = `${pct}%`;
  $('.hp-temp-fill', card).style.width = `${tempPct}%`;
  card.dataset.state = hpState(c.hp_current, max);
  const ws = transformState?.active?.sheet;
  const stWord = HP_STATE_TEXT[ws ? hpState(ws.hp.current, ws.hp.max) : card.dataset.state];
  const stEl = $('[data-hp-state-text]', card);
  if (stEl) { stEl.hidden = !stWord; stEl.textContent = stWord; stEl.dataset.state = card.dataset.state; }
  const tEl = $('[data-hp-temp-badge]', card);
  if (tEl) { tEl.hidden = !(c.hp_temp > 0); tEl.textContent = c.hp_temp > 0 ? `+${c.hp_temp} temp` : ''; }
  $$('[data-derived="hp-max"]', card).forEach((el) => {
    if (el.textContent !== String(max)) el.textContent = String(max);
    el.setAttribute('aria-label', `Maximum hit points ${max}`);
  });
  refreshTopbarVitals();
}

// -----------------------------------------------------------------------------
// Binding helpers
// -----------------------------------------------------------------------------

const bind = (table, row, field, type = 'text') =>
  `data-t="${table}" data-id="${row.id}" data-f="${field}" data-type="${type}"`;
const cbind = (field, type) => bind('characters', B.character, field, type);

const numInput = (table, row, field, cls = '', extra = '') =>
  `<input type="number" inputmode="numeric" class="${cls}" ${bind(table, row, field, 'int')} value="${esc(row[field])}" ${extra}>`;
const textInput = (table, row, field, cls = '', extra = '') =>
  `<input type="text" class="${cls}" ${bind(table, row, field)} value="${esc(row[field])}" ${extra}>`;
const textArea = (table, row, field, cls = '', extra = '') =>
  `<textarea class="autosize ${cls}" ${bind(table, row, field)} ${extra}>${esc(row[field])}</textarea>`;

function parseValue(el) {
  switch (el.dataset.type) {
    case 'int': {
      if (el.value.trim() === '' || el.value === '-') return undefined;
      const n = parseInt(el.value, 10);
      return Number.isFinite(n) ? n : undefined;
    }
    case 'num': {
      if (el.value.trim() === '') return undefined;
      const n = parseFloat(el.value);
      return Number.isFinite(n) ? n : undefined;
    }
    case 'bool': return el.checked;
    case 'nullable': return el.value || null;
    default: return el.value;
  }
}

function clampField(table, field, v, row) {
  if (table === 'characters') {
    if (field === 'level') return clamp(v, 1, 20);
    if (ABILITIES.some((a) => a.col === field)) return clamp(v, 1, 30);
    if (field === 'hp_max') return Math.max(1, v);
    // current HP never exceeds the authoritative maximum (base + feats); before the derived stats load only the base is known,
    // so the bound waits for them rather than cutting a feat bonus off
    if (field === 'hp_current') return clamp(v, 0, derived ? hpMax(row) : 9999);
    if (field === 'hit_dice_current') return clamp(v, 0, row.level || 20);   // one pool of hit dice: at most one per level
    if (['hp_temp', 'experience', 'cp', 'sp', 'ep', 'gp', 'pp'].includes(field)) return Math.max(0, v);
  }
  if (table === 'feature_trackers') {
    if (field === 'max') return clamp(v, 0, 999);
    if (field === 'current') return clamp(v, 0, row.max);
  }
  if (table === 'attacks' && field === 'magic_bonus') return clamp(v, -10, 10);
  if (table === 'spells' && field === 'level') return clamp(v, 0, 9);
  return v;
}

function syncInputs(table, id) {
  const row = findRow(table, id);
  if (!row) return;
  $$(`[data-t="${table}"][data-id="${id}"]`, root).forEach((el) => {
    if (el === document.activeElement) return;
    const v = row[el.dataset.f];
    if (el.type === 'checkbox') el.checked = !!v;
    else if (String(el.value) !== String(v ?? '')) {
      el.value = v ?? '';
      if (el.tagName === 'TEXTAREA') autoResize(el);
    }
  });
}

/** Apply a patch locally, queue it for saving and refresh the UI. */
function setRow(table, row, patch) {
  Object.assign(row, patch);
  if (table === 'characters' && Object.keys(patch).some((k) => DERIVED_FIELDS.has(k))) derivedDirty = true;
  saver.queue(table, row.id, patch);
  syncInputs(table, row.id);
  afterChange(table);
}

function afterChange(table) {
  refreshDerived();
  refreshToggles();
  refreshHp();
  refreshViews();
  if (table === 'spells' || table === 'features') refreshCombat();
  if (table === 'characters') { refreshCharacterBits(); inventory?.render(); renderAbilitySources(); }
  if (table === 'feature_trackers' || table === 'spell_slots') refreshPips();
  cacheLater();
}

function commitField(el) {
  const { t: table, id, f: field } = el.dataset;
  const row = findRow(table, id);
  if (!row) return;
  let v = parseValue(el);
  if (v === undefined) return;
  v = clampField(table, field, v, row);
  if (row[field] === v) return;
  row[field] = v;
  if (table === 'characters' && DERIVED_FIELDS.has(field)) derivedDirty = true;
  // Keep tracker current within a lowered max.
  if (table === 'feature_trackers' && field === 'max' && row.current > v) {
    row.current = v;
    saver.queue(table, id, { [field]: v, current: v });
    syncInputs(table, id);
  } else {
    saver.queue(table, id, { [field]: v });
  }
  afterChange(table);
  if (table === 'feature_trackers' && field === 'name') renderStrip();
  if (table === 'characters' && ['cp', 'sp', 'ep', 'gp', 'pp'].includes(field)) inventory?.renderSummary?.();   // the Coins summary card
}

// -----------------------------------------------------------------------------
// Derived stats (server-calculated; re-read after equipment, attunement, proficiency or relevant character changes)
// -----------------------------------------------------------------------------

// Request order of the derived stats and the spellbook (both read the same server state): a spellbook read that started after a
// derived read is already as fresh, so the derived render does not need to re-read it (one spellbook read on open, not three).
let reqClock = 0;
let spellbookStartedAt = 0;

async function loadDerived() {
  if (!B) return;
  const my = ++derivedSeq;
  const startedAt = ++reqClock;
  const id = C().id;
  try {
    const [d, p] = await Promise.all([getDerivedStats(id), getProficiencies(id).catch((err) => { console.warn('[proficiencies]', err?.message || err); return null; })]);
    if (!B || my !== derivedSeq || C().id !== id) return;   // an older response, or another sheet is open now
    derived = d;
    profState = p;
    profPending = {};
    renderDerived(startedAt);
  } catch (err) {
    if (my === derivedSeq) console.warn('[derived]', err?.message || err);
  }
}
const scheduleDerived = debounce(loadDerived, 300);

async function loadFeats() {
  const my = ++featSeq;
  try {
    const r = await loadCharacterFeats(C().id);
    if (my !== featSeq || !root) return;
    featState = r;
    rerender('#feats-card', featsCardHTML(featState, { editable: !ctx?.readOnly, removal: featRemovalPolicy() }));
    renderSheetChips();
    rerenderPlayFeatures();   // feat actions, reminders and counters in Play
  } catch (err) { console.warn('Feats unavailable:', err.message); }
}

/** Feats change derived values (HP, scores, proficiencies, spells, resources): reload the dependent views too. */
function featsChanged() {
  loadFeats();
  loadDerived();
  loadSpellbook();
  loadClasses();
}
const scheduleFeatsChanged = debounce(featsChanged, 300);

async function loadLineage() {
  if (!B) return;
  const my = ++lineageSeq;
  const id = C().id;
  try {
    const [res, ref] = await Promise.all([getCharacterLineage(id), lineageRef || getLineageReference().catch(() => null)]);
    if (!B || my !== lineageSeq || C().id !== id) return;
    lineage = res;
    lineageRef = ref;
    lineageSuggestion = !res.selected && C().race ? suggestLineage(C().race, await getLineageCatalog().catch(() => [])) : null;
    if (!B || my !== lineageSeq) return;
    renderLineage();
    renderSheetChips();
    rerenderPlayFeatures();   // lineage actions, reminders and counters in Play
  } catch (err) {
    if (my === lineageSeq) console.warn('[lineage]', err?.message || err);
  }
}
const scheduleLineage = debounce(loadLineage, 300);

async function loadBackground() {
  if (!B) return;
  const my = ++backgroundSeq;
  const id = C().id;
  try {
    const res = await getCharacterBackground(id);
    if (!B || my !== backgroundSeq || C().id !== id) return;
    background = res;
    renderBackground();
    renderSheetChips();
  } catch (err) {
    if (my === backgroundSeq) console.warn('[background]', err?.message || err);
  }
}
const scheduleBackground = debounce(loadBackground, 300);

function renderBackground() {
  if (!root) return;
  putHTML($('#background-card-body', root), backgroundCardHTML(background, { editable: !ctx?.readOnly, legacyText: C().background }));
}

/** After a background change: the card, ability scores, proficiencies and (for a new background) the equipment review. */
async function backgroundChanged(res, { changed = false } = {}) {
  backgroundSeq += 1;
  background = res;
  renderBackground();
  loadDerived();
  loadFeats();        // a 2024 background grants its Origin feat
  if (changed && res?.selected && (res.equipment || []).length && !res.equipment_applied_here
      && await confirmDialog('Review the starting equipment of this background now? Nothing is added without your confirmation.',
        { title: 'Starting equipment', okLabel: 'Review equipment' })) {
    openBackgroundEquipment({ characterId: C().id, bg: background, onApplied: () => { inventory?.refresh?.(); loadBackground(); } });
  }
}

// The spellbook is the most expensive read of a sheet (production: up to ~0.9 s of database time) and only the Spells section
// shows it: while that section is hidden a load only marks it stale, and opening the section (or exporting) loads it.
let spellbookStale = false;
const spellsVisible = () => !!root && $('.panel[data-panel="spells"]', root)?.hidden === false;

async function loadSpellbook({ force = false } = {}) {
  if (!B) return;
  if (!force && !spellsVisible()) { spellbookStale = true; return; }
  spellbookStale = false;
  const my = ++spellbookSeq;
  spellbookStartedAt = ++reqClock;
  const id = C().id;
  try {
    const [book, ref] = await Promise.all([getSpellbook(id), spellRef || getSpellReference().catch(() => null)]);
    if (!B || my !== spellbookSeq || C().id !== id) return;
    spellbook = book;
    spellRef = ref;
    renderSpellbook();
  } catch (err) {
    if (my === spellbookSeq) console.warn('[spellbook]', err?.message || err);
  }
}
const scheduleSpellbook = debounce(loadSpellbook, 300);

async function loadClasses() {
  if (!B) return;
  const my = ++classSeq;
  const id = C().id;
  const tfAt = tfEpoch;
  const epoch = slotEpoch;
  const resAt = resEpoch;
  try {
    const [summary, slots, cat, feats, res, sts] = await Promise.all([getClassSummary(id), getSpellSlots(id),
      classCatalog || getClassCatalog().catch(() => null), getClassFeatures(id), getResources(id), getStates(id).catch(() => null)]);
    const stale = () => !B || my !== classSeq || C().id !== id;   // superseded: do not start the next group of reads
    if (stale()) return;
    const [tf, comps, infs] = await Promise.all([getTransformation(id).catch(() => null), getCompanions(id).catch(() => null),
      getInfusions(id).catch(() => null)]);
    if (stale()) return;
    // a failed read is shown on the class card (with Retry), not silently dropped
    const eq = ctx?.readOnly ? null : await getStartingEquipmentState(id, summary).catch((e) => {
      console.warn('[starting equipment]', e?.message || e);
      const primary = (summary?.classes || []).find((k) => k.is_primary);
      return primary ? { class_version_id: primary.class_version_id, class_name: primary.class_name, error: true } : null;
    });
    if (stale()) return;
    startEqState = eq;
    classStates = sts;
    if (tfAt === tfEpoch && !tfBusy.size) transformState = tf;   // a Wild Shape change overlapped this read: keep the newer state
    companions = comps;
    infusionState = infs;
    classSummary = summary;
    if (slotsFresh(epoch)) slotState = slots;
    else scheduleSlots();     // a slot change overlapped this read: keep the newer slots, re-read them in a moment
    classCatalog = cat;
    classFeatures = feats;
    classResources = res;
    overlayResources();
    renderClasses();
    if (resAt !== resEpoch) scheduleResources();   // a resource change overlapped this read: its counters may be older
  } catch (err) {
    if (my === classSeq) console.warn('[classes]', err?.message || err);
  }
}
const scheduleClasses = debounce(loadClasses, 250);

/**
 * The class-features and Wild Shape reads carry copies of the resource rows (same server rows, same keys as
 * get_character_resources). The resource read is the authority for the counters: its rows replace those copies, so a
 * resource change needs only the small resource read, not the whole class page (docs/PERFORMANCE_RELEASE_2026-11.md).
 */
function overlayResources() {
  const rows = classResources?.resources;
  if (!Array.isArray(rows)) return;
  const fresh = new Map(rows.map((r) => [r.key, r]));
  const swap = (list) => (Array.isArray(list) ? list.map((r) => fresh.get(r?.key) || r) : list);
  if (classFeatures) {
    classFeatures.resources = swap(classFeatures.resources);
    for (const cls of classFeatures.classes || []) cls.resources = swap(cls.resources);
  }
  if (transformState) transformState.resources = swap(transformState.resources);
}

/**
 * Re-read only the resources and the Rage-style states (a use, a restore, or a resource event from another session). The
 * class page, its features and the Wild Shape options did not change, so they are not fetched again.
 */
async function loadResources() {
  if (!B) return;
  if (!classFeatures || !classResources) { await loadClasses(); return; }   // nothing to patch yet: the full read
  resEpoch += 1;
  const my = ++resSeq;
  const clsAt = classSeq;   // a full class read started after this one carries newer resource rows: this answer is dropped
  const id = C().id;
  try {
    const [res, sts] = await Promise.all([getResources(id), getStates(id).catch(() => null)]);
    if (!B || my !== resSeq || clsAt !== classSeq || C().id !== id) return;
    classResources = res;
    if (sts) classStates = sts;
    overlayResources();
    renderClasses();
  } catch (err) {
    if (my === resSeq) console.warn('[resources]', err?.message || err);
  }
}
const scheduleResources = debounce(loadResources, 250);

/** Re-read only the Wild Shape state (Realtime on character_transformations); a read overlapping a change is dropped. */
async function loadTransform() {
  if (!B) return;
  const my = ++tfSeq;
  const id = C().id;
  const epoch = tfEpoch;
  try {
    const st = await getTransformation(id);
    if (!B || my !== tfSeq || C().id !== id) return;
    if (epoch !== tfEpoch || tfBusy.size) { scheduleTransform(); return; }
    const was = !!transformState?.active;
    transformState = st;
    renderClasses();
    if (was !== !!st.active) loadDerived();
  } catch (err) {
    if (my === tfSeq) console.warn('[wild shape]', err?.message || err);
  }
}
const scheduleTransform = debounce(loadTransform, 250);

/** A confirmed Wild Shape state from the server: render it, refresh the derived stats and announce the change. */
async function tfApplied(r, { quiet = false } = {}) {
  if (!B || !r) return;
  tfEpoch += 1;
  transformState = r.character_id === C().id ? r : transformState;
  renderClasses();
  loadDerived();
  scheduleClasses();                 // resources (uses) and slots
  const res = r.result;
  // the excess of a form that dropped to 0 changed the normal HP on the server: show it now (no wait for Realtime), so a later
  // save of the character row can never write the old value back
  if (res?.normal_hp_after != null && r.character_id === C().id) {
    const c = C();
    const patch = { hp_current: res.normal_hp_after, hp_temp: Math.max(0, (c.hp_temp || 0) - (res.normal_temp_absorbed || 0)) };
    serverChar = { ...serverChar, ...patch };
    Object.assign(c, patch);
    syncInputs('characters', c.id);
    afterChange('characters');
  }
  let msg = '';
  if (res?.expired && res.applied === false) msg = 'The Wild Shape duration was over: you are back in your normal form. Nothing was changed.';
  else if (res?.ended && res.reason === 'zero_hp') {
    msg = `The form takes ${res.amount} damage, drops to 0 HP and Wild Shape ends.${res.carryover ? ` The excess ${res.carryover} damage carries over to your normal form (${res.normal_hp_before} → ${res.normal_hp_after}).` : ' No damage carries over.'}`;
  } else if (res?.ended && res.reason === 'expired' && res.applied === true) {   // damage results only (heal / ability on an expired form fall through)
    msg = `The form takes ${res.amount} damage (${res.form_hp_after} HP left). Its duration was over, so Wild Shape ends now; your normal HP is unchanged.`;
  } else if (res?.expired) msg = 'The Wild Shape duration was over: you are back in your normal form.';
  else if (!quiet && r.active) msg = `You are a ${r.active.name}.`;
  if (msg) announceWs(msg, res?.ended ? 'bad' : 'good');
}

function announceWs(msg, kind = 'good') {
  const st = root && $('#ws-status', root);
  if (st) { st.textContent = msg; st.dataset.kind = kind; }
  toast(msg, kind, 6000);
}

/** One Wild Shape change: duplicate clicks ignored, late answers for another character ignored, focus kept. */
async function tfMutation(key, call, message) {
  if (!B || tfBusy.has(key)) return null;
  const busy = tfBusy;
  const id = C().id;
  busy.add(key);
  tfEpoch += 1;
  try {
    const r = await call(id);
    if (!B || busy !== tfBusy || C().id !== id) return null;
    await tfApplied(r, { quiet: true });
    const msg = typeof message === 'function' ? message(r) : message;
    if (msg && !r.result?.ended && !r.result?.expired) announceWs(msg);
    return r;
  } catch (err) {
    if (B && busy === tfBusy && C().id === id) { toast(err.message, 'bad'); scheduleTransform(); }
    return null;
  } finally {
    busy.delete(key);
    if (busy === tfBusy) tfEpoch += 1;
  }
}

/** Damage or heal the form (sign -1 / +1); lethal damage asks first when the setting says so. */
async function formHp(sign, amount, key) {
  const amt = Math.floor(Number(amount));
  if (!amt || amt < 1) { toast('Enter an amount first'); $('[data-tf-amount]', root)?.focus(); return; }
  const sheet = transformState?.active?.sheet;
  if (!sheet) return;
  if (sign < 0 && transformState.settings?.confirm_lethal !== false && !(await confirmLethal(sheet, amt))) return;
  const r = await tfMutation(key, (id) => (sign < 0 ? damageForm(id, amt) : healForm(id, amt)),
    (x) => (sign < 0 ? `Form takes ${amt} damage: ${x.result.form_hp_after} / ${sheet.hp.max}.` : `Form regains ${x.result.healed} HP: ${x.result.form_hp_after} / ${sheet.hp.max}.`));
  if (r) { const inp = $('[data-tf-amount]', root); if (inp) inp.value = ''; }
}

/** A dialog changed slots (recovery, conversion, smite): older reads must not bring the previous slots back. */
function slotsChangedElsewhere() { slotEpoch += 1; return loadClasses(); }

/** A slot read started at `epoch` may be applied: no slot change was sent or answered since, and none is in flight. */
const slotsFresh = (epoch) => epoch === slotEpoch && slotBusy.size === 0;

/** Re-read only the slots (Realtime slot events); the class page itself did not change. */
async function loadSlots() {
  if (!B) return;
  const my = ++slotsSeq;
  const id = C().id;
  const epoch = slotEpoch;
  try {
    const slots = await getSpellSlots(id);
    if (!B || my !== slotsSeq || C().id !== id) return;
    if (!slotsFresh(epoch)) { scheduleSlots(); return; }
    slotState = slots;
    renderClasses();
  } catch (err) {
    if (my === slotsSeq) console.warn('[slots]', err?.message || err);
  }
}
const scheduleSlots = debounce(loadSlots, 250);

/**
 * One slot Use / Restore. `key` is the slot line ("standard:1", "pact", "temporary:<id>"): while its request runs, further
 * clicks on that line are ignored and its buttons show as busy. The RPC result is the new authoritative state; an answer for
 * another character (switched meanwhile) or older than an answer already shown is ignored.
 */
async function slotMutation(key, verb, call) {
  if (!B || slotBusy.has(key)) return;
  const busy = slotBusy;            // this sheet's set (a remount makes a new one)
  const id = C().id;
  const seq = ++slotMutSeq;
  const status = () => $('#slot-status', root);
  busy.add(key);
  slotEpoch += 1;
  renderClasses();
  try {
    const res = await call(id);
    if (!B || busy !== slotBusy || C().id !== id) return;
    if (seq > slotMutApplied) {
      slotMutApplied = seq;
      slotState = res;
    }
    const [pool, k] = key.split(/:(.*)/s);
    const msg = slotChangeMessage(slotState, pool, k, verb);
    const st = status();
    if (st) { st.textContent = msg; st.dataset.kind = 'good'; }
  } catch (err) {
    if (!B || busy !== slotBusy || C().id !== id) return;
    const st = status();
    if (st) { st.textContent = friendlySlotError(err); st.dataset.kind = 'bad'; }
    toast(friendlySlotError(err), 'bad');
    scheduleSlots();               // show the authoritative state again
  } finally {
    busy.delete(key);
    if (busy === slotBusy) {
      slotEpoch += 1;
      if (B && C().id === id) renderClasses();
    }
  }
}

function friendlySlotError(err) {
  const m = err?.message || '';
  if (/No .* slot left/i.test(m)) return `${m}. Nothing was spent.`;
  if (/No expended .* to restore/i.test(m)) return `${m}: it is already full.`;
  if (/fetch|network/i.test(m)) return 'Could not reach the server. The slots were not changed.';
  return m || 'The slot could not be changed.';
}

/** After a class change: everything level-dependent is re-read from the server. */
async function classesChanged() {
  await loadClasses();
  inventory?.refresh?.();   // starting equipment may have been added
  loadDerived();
  loadLineage();
  loadSpellbook();
  loadFeats();              // an Ability Score Improvement may name a feat
}

/**
 * Replace a container's HTML only when it changed. Keeps keyboard focus on the element with the same data-focus-key (or its
 * data-focus-alt when that one is now disabled, e.g. Restore at the maximum) and keeps details[data-open-key] open.
 */
function putHTML(el, html) {
  if (!el || el.__html === html) return;
  const a = document.activeElement;
  const had = a && el.contains(a) ? a : null;
  const key = had?.dataset.focusKey || null;
  const alt = had?.dataset.focusAlt || null;
  const open = new Set([...el.querySelectorAll('details[data-open-key]')].filter((d) => d.open).map((d) => d.dataset.openKey));
  el.innerHTML = html;
  el.__html = html;
  for (const d of el.querySelectorAll('details[data-open-key]')) if (open.has(d.dataset.openKey)) d.open = true;
  if (!had) return;
  const q = (k) => (k ? $(`[data-focus-key="${CSS.escape(k)}"]`, el) : null);
  let target = q(key);
  if (!target || target.disabled) target = q(alt) && !q(alt).disabled ? q(alt) : target;
  (target && !target.disabled ? target : el.closest('[tabindex], section, .card'))?.focus?.({ preventScroll: true });
}

/** The weapon and armor chips from the resolver (falls back to the manual flags while it loads). */
function profChipsHTML() {
  const groups = EQUIPMENT_PROFICIENCIES.map((p) => ({ id: PROF_GROUP_BY_FLAG[p.key], label: p.label }));
  const flagOf = (gid) => Object.keys(PROF_GROUP_BY_FLAG).find((k) => PROF_GROUP_BY_FLAG[k] === gid);
  const state = profState || { groups: groups.map((g) => ({ id: g.id, manual: !!C().equipment_proficiencies?.[flagOf(g.id)], sources: [] })) };
  return proficiencyChipsHTML(state, groups, { flagOf, pendingManual: profPending });
}

/** Add or remove the manual mark of a group or item; the resolver result replaces the optimistic chip. */
// Writes run one after another: two quick clicks (add, then remove) sent in parallel could commit in the wrong order.
let profQueue = Promise.resolve();
function setManualProficiency({ group = null, item = null, enabled, flag = null }) {
  if (flag) { profPending = { ...profPending, [flag]: enabled }; refreshToggles(); }
  const id = C().id;
  const run = async () => {
    try {
      await setCharacterProficiency(id, { group, item, enabled });
    } catch (err) {
      if (flag && profPending[flag] === enabled) { const { [flag]: _, ...rest } = profPending; profPending = rest; refreshToggles(); }
      toast(err.message, 'bad');
    }
    if (B && C().id === id) await loadDerived();
  };
  profQueue = profQueue.then(run, run);
  return profQueue;
}

function gotoSource(where) {
  showTab('features');
  const el = $(where === 'lineage' ? '#lineage-card' : where === 'background' ? '#background-card' : '#class-card', root);
  el?.scrollIntoView({ block: 'start', behavior: 'smooth' });
  el?.querySelector('button, select, summary')?.focus({ preventScroll: true });
}

function levelFieldHTML() {
  const c = C();
  return hasClasses()
    ? `<input type="number" value="${c.level}" readonly aria-describedby="level-from-classes" data-level-ro>
       <small class="muted" id="level-from-classes">Set by your classes</small>`
    : numInput('characters', c, 'level', '', 'min="1" max="20"');
}

function renderClasses() {
  if (!root) return;
  const put = (sel, html) => putHTML($(sel, root), html);
  const editable = !ctx?.readOnly;
  put('#class-card-body', classCardHTML(classSummary, classCatalog, { editable, startEq: startEqState }));
  put('#level-field', levelFieldHTML());
  put('#slot-tracker', slotTrackerHTML(slotState, { editable, pending: slotBusy }));
  put('#slot-actions', slotActionsHTML(classResources, slotState, { editable }));
  put('#class-features', featuresPanelHTML(classFeatures, { editable, derived, states: classStates }));
  put('#combat-states', playGlanceHTML());
  $$('[data-play-ready]', root).forEach((el) => { el.hidden = !playGlanceHTML(); });
  renderFormHp();
  put('#class-transform', wildShapePanelHTML(transformState, { editable, place: 'class' }));
  put('#combat-transform', wildShapePanelHTML(transformState, { editable, place: 'combat' }));
  put('#companions-body', companionsHTML(companions, { editable }));
  put('#infusions-slot', infusionsHTML(infusionState, { editable }));
  restoreDrafts($('#class-features', root));
  put('#class-resources', resourceListHTML(classResources, { editable }));
  put('#class-feature-summary', featureSummaryHTML(classFeatures));
  put('#combat-groups', combatGroupsHTML());
  put('#play-infusions-slot', infusionsPlayHTML(infusionState));
  put('#option-spells', optionSpellsHTML(selectedOptions(classFeatures, classResources).spell));
  const infSig = JSON.stringify([...infusedItemMap(infusionState)]);
  if (infSig !== lastInfusedSig) { lastInfusedSig = infSig; inventory?.render?.(); renderWeapons(); }   // infused-item badges follow the infusion read (only on change)
  else renderWeapons();   // weapon action counters (R-D2) follow the resource read; re-renders only when the markup changed
  put('#sheet-avatar', avatarHTML());
  hydrateSpellChoices(root);
  renderStrip();
  renderSheetChips();
  $$('[data-legacy-slots]', root).forEach((el) => { el.hidden = !!slotState && !slotState.legacy_manual_active; });
  renderSpellbook();
  refreshDerived();
}

/** While transformed, the vitals show the form's HP first; the normal HP stays below it, protected. */
function renderFormHp() {
  const card = $('#hp-card', root);
  if (!card) return;
  const ws = transformState?.active?.sheet;
  card.classList.toggle('is-form', !!ws);
  const box = $('[data-ws-hp]', card);
  if (box) {
    box.hidden = !ws;
    putHTML(box, ws ? `<span class="hp-form-label">${icon('actions/wild-shape', { size: 18 })}Wild Shape · ${esc(ws.creature.name)}</span>
      <span class="hp-form-num" aria-label="Form hit points ${ws.hp.current} of ${ws.hp.max}"><strong>${ws.hp.current}</strong><span class="hp-sep">/</span>${ws.hp.max}</span>` : '');
  }
  const note = $('[data-ws-hpnote]', card);
  if (note) {
    note.hidden = !ws;
    note.textContent = ws ? 'Damage and Heal apply to the form. Your normal hit points are protected until you revert.' : '';
  }
  refreshHp();   // HP state word and top-bar readout follow the form
}

function renderSpellbook() {
  if (!root) return;
  const put = (sel, html) => putHTML($(sel, root), html);
  const editable = !ctx?.readOnly;
  put('#spellcasting-sources', sourcesHTML(spellbook, { editable, classes: classSummary?.classes }));
  const filters = $('#spellbook-filters', root);
  if (filters && spellRef && !filters.childElementCount) filters.innerHTML = filtersHTML(spellFilters, spellRef, { book: true });
  put('#spellbook-list', spellbookListHTML(spellbook, spellFilters, { editable }));
}

/** The Lineage card on the Build tab (re-rendered in place; keeps keyboard focus). */
function lineageSectionHTML() {
  const c = C();
  // The old free-text race is compatibility data: shown (and editable) only in a folded legacy detail, never as an active field
  return `
    ${sectionHead({ id: 'lineage-card-title', icon: 'build.lineage', title: 'Lineage', desc: 'Your people, their traits and choices.' })}
    <div id="lineage-card-body">${lineageCardHTML(lineage, c, { editable: !ctx?.readOnly, ref: lineageRef, suggestion: lineageSuggestion })}</div>
    ${c.race ? `<details class="quiet-details tl-detail legacy-race" data-legacy-race>
      <summary>Legacy race text (kept, grants no traits)</summary>
      <label class="field"><span>Race as written on the old sheet</span>${textInput('characters', c, 'race')}</label>
      <p class="muted small">Only used for display while no lineage is chosen. Choosing a lineage never deletes it.</p>
    </details>` : ''}`;
}

function renderLineage() {
  const el = root && $('#lineage-card', root);
  if (!el) return;
  const html = lineageSectionHTML();
  if (el.__html === html) return;
  const a = document.activeElement;
  const key = a && el.contains(a) ? a.dataset.focusKey : null;
  el.innerHTML = html;
  el.__html = html;
  if (key) $(`[data-focus-key="${CSS.escape(key)}"]`, el)?.focus();
}

async function lineageChanged(res) {
  lineage = res;
  renderLineage();
  loadFeats();           // Variant Human / Custom Lineage feat choice
  await loadDerived();   // refreshes the subtitle, abilities, speed, skills … through renderDerived
}

// ---- ability score sources (docs/ABILITY_SCORE_SOURCE_MODEL.md) -------------------------------------------------------------
// The card's input is the editable BASE score. Each source row shows only its own contribution ("+1 Fighter: ASI"), never a
// resulting total; the effective score comes from the server (derived.abilities[k].score) and is shown only while the server
// computed it from the base that is on screen now. While an edited base is saving or being re-read it says "updating".
const signedN = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const shortSource = (name) => String(name || 'Effect').replace(/Ability Score Improvement/g, 'ASI').replace(/^Feat: (.+)$/, '$1 (feat)');

/** The contributions of one ability, in the server's order of application: lineage, background, override, bonuses. */
export function abilitySourceRows(x, { backgroundName = '' } = {}) {
  if (!x) return [];
  const rows = [];
  const capped = (bonus, applied) => (applied < bonus ? ` (${applied ? `${signedN(applied)} applied` : 'none applied'}: max 20)` : '');
  if (!x.lineage_included && x.lineage_bonus) {
    const names = (x.lineage_sources || []).map((l) => l.source_name).filter(Boolean);
    rows.push({ n: x.lineage_bonus, kind: 'lineage', name: `Lineage${names.length ? `: ${names.join(', ')}` : ''}`, note: capped(x.lineage_bonus, x.lineage_applied || 0) });
  }
  if (x.background_bonus) {
    rows.push({ n: x.background_bonus, kind: 'background', name: `Background${backgroundName ? `: ${backgroundName}` : ''}`, note: capped(x.background_bonus, x.background_applied || 0) });
  }
  for (const e of x.sources || []) {
    if (e.effect_type === 'ability_override') rows.push({ set: Number(e.value), kind: 'override', name: e.source_name || 'Effect' });
    else rows.push({ n: Number(e.value) || 0, kind: /^Feat: /.test(e.source_name || '') ? 'feat' : 'effect', name: e.source_name || 'Effect' });
  }
  // permanent increases from used items (20261114000500), each capped at its maximum (default 20)
  for (const e of x.permanent_sources || []) {
    const v = Number(e.value) || 0;
    const applied = Number(e.applied) || 0;
    rows.push({ n: v, kind: 'permanent', name: `${e.source_name || 'Item'} (permanent)`, id: e.id, canRevert: !!e.can_revert,
      note: applied < v ? ` (${applied ? `${signedN(applied)} applied` : 'none applied'}: max ${e.max_score || 20})` : '' });
  }
  return rows;
}

function abilitySourcesHTML(a, x) {
  const rows = abilitySourceRows(x, { backgroundName: derived?.background?.name || '' });
  if (!rows.length) return '';
  const li = rows.map((r) => {
    const amount = r.set != null ? `Sets to ${r.set}` : signedN(r.n);
    const sr = r.set != null ? `${a.name} set to ${r.set} by ${r.name}` : `${signedN(r.n)} ${a.name} from ${r.name}`;
    const revert = r.canRevert ? ` <button type="button" class="btn-link small" data-action="revert-permanent" data-effect="${esc(r.id)}" aria-label="Revert ${esc(sr)}">Revert</button>` : '';
    return `<li data-ab-source="${esc(r.kind)}" title="${esc(sr + (r.note || ''))}"><span aria-hidden="true"><span class="ab-src-n">${esc(amount)}</span> ${esc(shortSource(r.name))}${esc(r.note || '')}</span><span class="sr-only">${esc(sr + (r.note || ''))}</span>${revert}</li>`;
  });
  const additive = rows.filter((r) => r.set == null);
  const total = additive.length > 1 ? additive.reduce((t, r) => t + r.n, 0) : null;
  return `<ul class="ab-srcs" aria-label="${esc(a.name)} bonuses from sources">${li.join('')}${total != null
    ? `<li class="ab-src-total" data-ab-source="total"><span aria-hidden="true">Bonuses from sources: ${esc(signedN(total))}</span><span class="sr-only">Bonuses to ${esc(a.name)} from sources: ${esc(signedN(total))} in total</span></li>` : ''}</ul>`;
}

/** Source rows + effective score of every ability card; cheap and idempotent (also runs on every local edit). */
function renderAbilitySources() {
  if (!root || !B) return;
  for (const a of ABILITIES) {
    const x = derived?.abilities?.[a.key];
    const card = $(`#ability-cards [data-ability="${a.key}"]`, root);
    if (!card) continue;
    const fresh = !!x && Number(C()[a.col]) === Number(x.base);       // the server's numbers belong to the base on screen
    const inForm = x?.form_score != null;
    const eff = !x || inForm ? '' : !fresh ? 'updating…' : x.score !== x.base ? String(x.score) : '';
    const effEl = $(`[data-ab-eff="${a.key}"]`, card);
    if (effEl) {
      const label = !eff ? '' : fresh ? `${a.name} score ${x.score} (base ${x.base} plus the sources below)` : `${a.name} score updating`;
      if (effEl.dataset.v !== eff) {
        effEl.dataset.v = eff;
        effEl.innerHTML = eff ? `<span aria-hidden="true">${fresh ? `Score <strong>${esc(eff)}</strong>` : 'Score updating…'}</span><span class="sr-only">${esc(label)}</span>` : '';
      }
    }
    card.toggleAttribute('data-eff', !!eff);
    card.toggleAttribute('data-stale', !!x && !fresh && !inForm);
    const srcEl = $(`[data-ab-srcs="${a.key}"]`, card);
    const html = inForm ? '' : abilitySourcesHTML(a, x);
    if (srcEl && srcEl.__html !== html) { srcEl.__html = html; srcEl.innerHTML = html; }
  }
}

// "where a bonus comes from" (20261114000500): item / permanent sources of a save, skill or initiative, and the item effects that
// are not counted now (not equipped / not attuned). Names are the server's: an unidentified item appears under its disguise.
const INACTIVE_WHY = { not_equipped: 'not equipped', not_attuned: 'not attuned', wearing_armor: 'wearing armor', using_shield: 'using a shield' };
const ITEM_SOURCE = new Set(['item_effect', 'permanent', 'modifier']);
/** Names of the items that change the speed now ("Lucky Boots"), for the speed note. */
function itemSpeedNames(sp) {
  return [...new Set((sp?.breakdown || []).filter((x) => ITEM_SOURCE.has(x.source_type)).map((x) => x.source_name))].join(', ');
}
function bonusSourceParts(x) {
  return (x?.item_sources || []).map((s) => `${signedN(Number(s.value) || 0)} from ${s.source_name}`);
}
function setSourceTitle(el, parts, x) {
  const off = (x?.inactive_effects || []).map((e) => `${e.source_name} (${INACTIVE_WHY[e.inactive_reason] || e.inactive_reason})`);
  const text = [parts.length ? `Includes ${parts.join('; ')}` : '', off.length ? `Not counted: ${off.join(', ')}` : ''].filter(Boolean).join('. ');
  if (text) el.title = text; else el.removeAttribute('title');
}

/** Update only the derived bits in place; a re-rendered block keeps keyboard focus (stable data-focus-key). */
function renderDerived(startedAt = 0) {
  if (!root || !derived) return;
  const set = (key, text) => $$(`[data-derived="${key}"]`, root).forEach((el) => { if (el.textContent !== text) el.textContent = text; });
  refreshHp();                                               // the feat bonus to maximum HP may have changed
  set('ac', String(derived.armor_class.value));
  set('ac-note', acNote(derived));
  set('ac-note-short', acNote(derived, { short: true }));   // phones: the shield-shaped tile has room for ~2 short lines
  const sp = derived.speed;
  const modes = Object.entries(sp.movement || {}).filter(([k, m]) => k !== 'walk' && m.active).map(([k, m]) => `${k} ${m.value}`);
  // feat effects use the class-feature row shape; their source name is "Feat: <name>"
  const fromFeat = (sp.breakdown || []).filter((x) => x.source_type === 'class_feature' && /^Feat: /.test(x.source_name || ''));
  const fromClass = (sp.breakdown || []).some((x) => x.source_type === 'class_feature' && !/^Feat: /.test(x.source_name || ''));
  const speedFrom = sp.base_source === 'lineage' ? 'lineage'
    : fromFeat.length && !fromClass ? fromFeat.map((x) => x.source_name.replace(/^Feat: /, '')).join(', ')
      : fromClass && fromFeat.length ? 'class features and feats' : fromClass ? 'class features'
        : itemSpeedNames(sp) || 'equipment';
  set('speed-note', derived.wild_shape ? `Form: walk ${sp.value} ft${modes.length ? ` · ${modes.join(' · ')}` : ''}`
    : [sp.value !== sp.base ? `Base ${sp.base} ft, now ${sp.value} ft (${speedFrom})` : '', ...modes].filter(Boolean).join(' · '));
  const inForm = ABILITIES.some((a) => derived.abilities?.[a.key]?.form_score != null);
  for (const a of ABILITIES) {
    const x = derived.abilities?.[a.key];
    set(`abform:${a.key}`, x?.form_score != null ? String(x.form_score) : '');
    set(`absrc:${a.key}`, !inForm ? '' : x?.form_score != null ? 'From form' : 'Retained from character');
    $$(`#ability-cards [data-ability="${a.key}"]`, root).forEach((el) => { el.dataset.src = !inForm ? '' : x?.form_score != null ? 'form' : 'retained'; });
    set(`abnote:${a.key}`, x?.form_score != null ? `${x.form_name} form · character base score ${x.base}` : '');
  }
  renderAbilitySources();
  const keep = (sel, html) => {
    const el = $(sel, root);
    if (!el || el.__html === html) return;
    const a = document.activeElement;
    const key = a && el.contains(a) ? a.dataset.focusKey : null;
    el.innerHTML = html;
    el.__html = html;
    if (key) $(`[data-focus-key="${CSS.escape(key)}"]`, el)?.focus();
  };
  renderWeapons();
  keep('#feature-attacks', featureAttacksHTML());
  keep('#combat-groups', combatGroupsHTML());   // attack riders decide which option cards are not repeated
  keep('#class-features', featuresPanelHTML(classFeatures, { editable: !ctx?.readOnly, derived, states: classStates }));
  keep('#combat-states', playGlanceHTML());
  $$('[data-play-ready]', root).forEach((el) => { el.hidden = !playGlanceHTML(); });
  restoreDrafts($('#class-features', root));
  hydrateSpellChoices(root);
  keep('#prof-chips', profChipsHTML());
  keep('#specific-profs', proficiencyDetailsHTML(profState, { editable: !ctx?.readOnly }));
  keep('#tool-profs', toolsHTML(derived));
  keep('#lineage-stats', lineageStatsHTML(derived));
  keep('#senses-list', sensesHTML());
  keep('#lineage-spells', lineageSpellsHTML(derived, { spells: false }));
  $$('[data-lineage-spells-card]', root).forEach((el) => { el.hidden = !derived.lineage_actions?.length; });
  $$('[data-derive^="save:"]', root).forEach((el) => {
    const st = derived.saving_throws?.[el.dataset.derive.slice(5)];
    const parts = [st?.class_bonus ? `+${st.class_bonus} from ${(st.class_bonus_sources || []).join(', ')}` : '', ...bonusSourceParts(st)].filter(Boolean);
    setSourceTitle(el, parts, st);
  });
  $$('[data-derive^="skill:"]', root).forEach((el) => {
    const k = el.dataset.derive.slice(6);
    setSourceTitle(el, bonusSourceParts(derived.skills?.[k]), derived.skills?.[k]);
  });
  $$('[data-derive="init"]', root).forEach((el) => setSourceTitle(el, bonusSourceParts(derived.initiative), derived.initiative));
  // speed and ability scores: the item effects that are not counted now (the counted ones are in the note / the source list)
  const speedParts = (derived.speed?.breakdown || []).filter((x) => ITEM_SOURCE.has(x.source_type))
    .map((x) => `${signedN(Number(x.value) || 0)} ft from ${x.source_name}`);
  $$('[data-derive="speed"]', root).forEach((el) => setSourceTitle(el, speedParts, derived.speed));
  for (const a of ABILITIES) {
    $$(`#ability-cards [data-ability="${a.key}"]`, root).forEach((el) => setSourceTitle(el, [], derived.abilities?.[a.key]));
  }
  $$('[data-dis]', root).forEach((el) => {
    const [kind, k] = el.dataset.dis.split(':');
    el.hidden = !(kind === 'save' ? derived.saving_throws?.[k]?.disadvantage : derived.skills?.[k]?.disadvantage);
  });
  if (!startedAt || spellbookStartedAt < startedAt) scheduleSpellbook();    // Save DC / attack bonus depend on scores, level and lineage
  refreshToggles();       // skill dots show lineage proficiencies
  renderStrip();
  refreshDerived();       // saves include item bonuses; "move up to your speed" uses the derived speed
  inventory?.render();    // proficiency notes on equipped items
}

/** Open an equipped item from the AC breakdown: Inventory tab, then the item's detail. */
function gotoInventoryItem(inventoryItemId) {
  showTab('inventory');
  setTimeout(() => $(`[data-focus-key="inventory-item:${CSS.escape(inventoryItemId)}:details"]`, root)?.click(), 50);
}

// -----------------------------------------------------------------------------
// Rendering
// -----------------------------------------------------------------------------

function trackerPips(t) {
  if (t.max <= 12) {
    const pips = Array.from({ length: t.max }, (_, i) =>
      `<button type="button" class="pip ${i < t.current ? 'on' : ''}" data-action="tracker-pip" data-id="${t.id}" data-i="${i}" aria-label="${esc(t.name)} ${i + 1}"></button>`).join('');
    return `<div class="pips">${pips || '<span class="muted small">max 0</span>'}</div>`;
  }
  return `<div class="counter">
    <button type="button" class="step" data-action="tracker-step" data-id="${t.id}" data-d="-1" aria-label="Spend">−</button>
    <span class="counter-val">${t.current}<small>/${t.max}</small></span>
    <button type="button" class="step" data-action="tracker-step" data-id="${t.id}" data-d="1" aria-label="Restore">+</button>
  </div>`;
}

function slotBoxes(s) {
  const boxes = Array.from({ length: s.total }, (_, i) =>
    `<button type="button" class="slot-box ${i < s.used ? 'used' : ''}" data-action="slot-pip" data-id="${s.id}" data-i="${i}" aria-label="Level ${s.level} slot ${i + 1}${i < s.used ? ' (used)' : ''}"></button>`).join('');
  return `<div class="slot-boxes">${boxes}</div>`;
}

function refreshPips() {
  $$('[data-pips]', root).forEach((el) => {
    const [kind, id] = el.dataset.pips.split(':');
    if (kind === 'tracker') {
      const t = findRow('feature_trackers', id);
      if (t) el.innerHTML = trackerPips(t);
    } else {
      const s = findRow('spell_slots', id);
      if (s) el.innerHTML = slotBoxes(s);
    }
  });
  $$('[data-slot-total]', root).forEach((el) => {
    const s = findRow('spell_slots', el.dataset.slotTotal);
    if (s) el.textContent = s.total;
  });
  renderStrip();
}

// Quick resources in the vitals: a restrained, deterministic summary. Class resources with few uses (in class order, at most 4),
// then the player's own trackers, then one spell-slot line and one Pact Magic line (authoritative slot state). Everything else
// is managed in Play ("+ N more" links there).
const QUICK_CLASS_RES = 4;
const QUICK_MAX = 6;
const ORD = (n) => `${n}${n === 1 ? 'st' : n === 2 ? 'nd' : n === 3 ? 'rd' : 'th'}`;

function stripHTML() {
  const pips = (cur, max, label) => `<div class="pips" aria-label="${esc(label)}: ${cur} of ${max}">${Array.from({ length: max }, (_, i) =>
    `<span class="slot-dot ${i < cur ? 'is-full' : ''}"></span>`).join('')}</div>`;
  const classRes = (classResources?.resources || []).filter((r) => r.kind === 'feature' && r.active && r.max != null && r.max <= 12)
    .map((r) => `
    <div class="res-chip" data-quick="class" title="${esc(r.class_name)}: ${esc(r.feature_name)}">
      <div class="res-name">${esc(r.name)}</div>
      ${pips(r.remaining, r.max, r.name)}
    </div>`);
  const trackers = B.trackers.map((t) => `
    <div class="res-chip" data-quick="tracker" ${t.formula ? `title="Max: ${esc(t.formula)}"` : ''}>
      <div class="res-name">${esc(t.name)}</div>
      <div data-pips="tracker:${t.id}">${trackerPips(t)}</div>
    </div>`);
  const slots = [];
  const std = (slotState?.standard || []).filter((x) => x.max > 0);
  if (std.length) {
    slots.push(`<div class="res-chip slot-chip" data-quick="slots">
      <div class="res-name">Spell slots</div>
      <div class="res-slots">${std.map((x) => `<span class="res-slot" aria-label="${ORD(x.slot_level)} level: ${x.remaining} of ${x.max}"><span class="res-slot-lvl" aria-hidden="true">${ORD(x.slot_level)}</span><span class="res-num" aria-hidden="true">${x.remaining}/${x.max}</span></span>`).join('')}</div>
    </div>`);
  }
  const pact = slotState?.pact_magic;
  if (pact?.max) {
    slots.push(`<div class="res-chip slot-chip" data-quick="pact">
      <div class="res-name">Pact Magic · ${ORD(pact.slot_level)}</div>
      ${pips(pact.remaining, pact.max, 'Pact Magic slots')}
    </div>`);
  }
  // legacy hand-tracked slots only when the character has no class slot table (or still uses the manual tracker)
  if (!slotState || slotState.legacy_manual_active) {
    B.slots.filter((x) => x.total > 0).forEach((x) => slots.push(`
    <div class="res-chip slot-chip" data-quick="manual-slots">
      <div class="res-name">Lvl ${x.level} slots</div>
      <div data-pips="slot:${x.id}">${slotBoxes(x)}</div>
    </div>`));
  }
  const all = [...classRes.slice(0, QUICK_CLASS_RES), ...trackers, ...slots];
  const shown = all.slice(0, QUICK_MAX);
  const more = all.length - shown.length + Math.max(0, classRes.length - QUICK_CLASS_RES);
  return all.length
    ? `${shown.join('')}${more > 0 ? `<button type="button" class="res-more" data-action="tab" data-tab="combat">+ ${more} more in Play</button>` : ''}`
    : `<button type="button" class="res-empty" data-action="tab" data-tab="resources">+ Add resources (Ki, Rage, Bardic Inspiration…)</button>`;
}

function renderStrip() {
  const el = $('#resource-strip', root);
  if (el) el.innerHTML = stripHTML();
}

function initials(name) {
  return String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('') || '?';
}

function avatarHTML() {
  const c = C();
  return c.portrait_url
    ? `<img src="${esc(c.portrait_url)}" alt="" loading="lazy" onerror="this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${esc(initials(c.name)).replace(/'/g, '')}'}))">`
    : classIcon(classSummary?.classes?.find((k) => k.is_primary)?.class_name || c.class_name, { size: 48, cls: 'avatar-emblem' });
}

const activeConditions = () => (Array.isArray(C().conditions) ? C().conditions : []);
const conditionText = (x) => (typeof x === 'string' ? x : x?.name || String(x ?? ''));

// The rows of character_conditions the CALLER may see (get_character_conditions, 20261112000200). In memory only: never in B,
// so neither the bundle cache nor a shared browser's offline copy ever holds the DM's view. null = not loaded (or an older
// server without the RPC): the chips then show characters.conditions, the server's mirror of the visible rows.
let condRows = null;
let condSeq = 0;
const amConditionDm = () => isAdmin() || isCampaignDM(C().campaign_id);
const conditionLabel = (k) => (k.kind === 'exhaustion' ? `Exhaustion ${k.level}` : k.name);
function conditionIcon(k) {
  if (k.kind === 'condition') return k.icon || 'condition.generic-effect';
  if (k.kind === 'tag' && k.tag_type === 'curse') return 'condition.cursed';
  if (k.kind === 'tag' && k.damage_type_id) return `spell.damage.${k.damage_type_id}`;
  return 'condition.generic-effect';
}

function conditionsHTML() {
  const add = '<button type="button" class="condition-add" data-action="add-condition">+ Condition</button>';
  if (!condRows) {
    return activeConditions().map((name, i) =>
      `<button type="button" class="condition-chip" data-action="show-condition" data-i="${i}">${esc(conditionText(name))}</button>`).join('') + add;
  }
  return condRows.map((k) => {
    const cls = ['condition-chip', k.kind === 'tag' ? 'is-tag' : '', k.hidden ? 'is-hidden' : ''].filter(Boolean).join(' ');
    return `<button type="button" class="${cls}" data-action="show-condition" data-cid="${esc(k.id)}" data-kind="${esc(k.kind || 'condition')}"${k.hidden ? ' data-hidden="1"' : ''}>`
      + `${icon(conditionIcon(k), { size: 16 })}${k.hidden ? `${icon('ui.dm-secret', { size: 14 })}<span class="sr-only">(hidden from the player) </span>` : ''}`
      + `${esc(conditionLabel(k))}${k.duration_text ? `<span class="condition-dur">${esc(k.duration_text)}</span>` : ''}</button>`;
  }).join('') + add;
}

async function loadConditions() {
  const my = ++condSeq;
  const id = C().id;
  try {
    const rows = await getCharacterConditions(id);
    if (my !== condSeq || !B || C().id !== id) return;
    // a server before 20261112000200 (its rows have no kind, and the sheet list is not their mirror): keep the old list
    const old = rows.length ? !('kind' in rows[0]) : activeConditions().some((x) => conditionText(x).trim());
    condRows = old ? null : rows;
  } catch (err) {
    if (my !== condSeq || isAbortError(err)) return;
    console.warn('[conditions]', err?.message || err);   // an older server: the stored list stays the source of the chips
    condRows = null;
  }
  refreshCharacterBits();
}
const scheduleConditions = debounce(loadConditions, 250);

/** Character-level bits that are not plain inputs: avatar and conditions. */
// ---- Pending choices ---------------------------------------------------------

const pendingChoices = () => (Array.isArray(C().pending_choices) ? C().pending_choices : []);

function choicesListHTML() {
  const list = pendingChoices();
  if (!list.length) return '<p class="empty">No reminders. Add one for a choice you want to make later.</p>';
  return list.map((p) => `
    <div class="choice-row">
      <div class="choice-info">
        <span class="choice-type">${esc(p.type)}</span>
        ${p.description ? `<p class="choice-desc">${esc(p.description)}</p>` : ''}
        ${Array.isArray(p.options) && p.options.length ? `<div class="choice-options">${p.options.map((o) => `<span class="choice-option">${esc(o)}</span>`).join('')}</div>` : ''}
      </div>
      <button type="button" class="btn btn-sm btn-good" data-action="resolve-choice" data-id="${esc(p.id)}" title="Remove from the list once applied to the sheet">✓ Done</button>
    </div>`).join('');
}

/** Character-level bits that are not plain inputs: avatar, conditions, pending choices. */
function refreshCharacterBits() {
  for (const [sel, html] of [
    ['#sheet-avatar', avatarHTML()], ['#conditions-row', conditionsHTML()], ['#portrait-preview', avatarHTML()],
    ['#choices-list', choicesListHTML()],
  ]) {
    const el = $(sel, root);
    if (el && el.__html !== html) { el.innerHTML = html; el.__html = html; }
  }
  renderSheetChips();
}

/** Governance state of this character (request-ui onState): lock, decisions, open requests. Null until loaded / ungoverned. */
let govState = null;

/** How removing a directly assigned feat behaves now: 'allow' | 'request' | 'dm_only' | 'locked' (labels only). */
function featRemovalPolicy() {
  const g = govState?.gov;
  if (!g || g.is_dm) return 'allow';
  if (LOCKED_MODES.has(g.lock_mode)) return 'locked';
  const d = g.decisions?.['choice.feat'];
  if (d === 'dm_only' || d === 'disabled') return 'dm_only';
  return d === 'approval_required' ? 'request' : 'allow';
}

const LOCKED_MODES = new Set(['progression_locked', 'build_locked', 'fully_locked', 'archived']);
const LOCK_CHIP = { progression_locked: 'Progression locked', build_locked: 'Build locked', fully_locked: 'Locked by the DM', archived: 'Archived' };

/** How Level Up behaves now: { mode: 'normal' | 'request' | 'blocked', reason }. The server still decides; this only labels. */
function levelUpMode() {
  const g = govState?.gov;
  if (!g || g.is_dm) return { mode: 'normal' };
  if (LOCKED_MODES.has(g.lock_mode)) {
    // say which lock applies (the banner names the DM's reason); runtime play stays available under every lock but archive
    const LOCK_REASON = { progression_locked: 'Your DM has paused progression for this character.',
      build_locked: 'Your DM has locked the build: levels and other permanent changes wait until it is unlocked.',
      fully_locked: 'Your DM has locked this character.', archived: 'This character is archived.' };
    return { mode: 'blocked', reason: LOCK_REASON[g.lock_mode] || LOCK_REASON.progression_locked };
  }
  const d = g.decisions?.['build.class_level'];
  if (d === 'dm_only' || d === 'disabled') return { mode: 'blocked', reason: 'Only your DM changes levels in this campaign.' };
  if (d === 'approval_required') return { mode: 'request' };
  return { mode: 'normal' };
}

function levelUpButtonHTML() {
  const m = levelUpMode();
  if (m.mode === 'blocked') {
    return `<button type="button" class="btn" disabled aria-describedby="level-up-reason" data-level-up-blocked>${icon('ui/locked', { size: 18 })}Level up</button>
      <span class="field-note" id="level-up-reason">${esc(m.reason)}</span>`;
  }
  return `<button type="button" class="btn btn-gold" data-action="level-up" data-focus-key="level-up">${icon('actions/level-up', { size: 18 })}${
    m.mode === 'request' ? 'Request level up' : 'Level up'}</button>${m.mode === 'request'
    ? '<span class="field-note">Your DM approves level-ups in this campaign: you choose everything, then send it for approval.</span>' : ''}`;
}

/** Open class-feature choices and subclasses still to pick (from get_character_class_features). */
function openBuildChoices() {
  const st = classFeatures;
  if (!st?.classes?.length) return 0;
  const subs = st.classes.filter((k) => !k.subclass?.selected && k.subclass?.status === 'available').length;
  return (st.incomplete_choices || []).filter((x) => x.kind !== 'subclass').length + subs;
}

/** Small state chips under the name: campaign, owner, lock, requests, Wild Shape, open choices. Text always carries the meaning. */
function sheetChipsHTML() {
  const c = C();
  const chips = [];
  const camp = state.campaigns.find((k) => k.id === c.campaign_id);
  if (camp) chips.push(`<span class="chip chip-quiet">${icon('dm/campaign', { size: 16 })}${esc(camp.name)}</span>`);
  const owner = canManageCharacter(c) ? state.profiles.find((p) => p.id === c.owner_id) : null;
  if (owner && owner.id !== state.profile.id) chips.push(`<span class="chip chip-quiet owner-tag">Player: ${esc(owner.display_name || owner.email)}</span>`);
  const g = govState?.gov;
  if (g && LOCKED_MODES.has(g.lock_mode)) chips.push(`<span class="chip chip-locked" data-chip="lock">${icon('ui/locked', { size: 16 })}${esc(LOCK_CHIP[g.lock_mode])}</span>`);
  const reqs = govState?.requests || [];
  const waiting = reqs.filter((r) => r.status === 'submitted').length;
  const returned = reqs.filter((r) => r.status === 'returned_for_changes').length;
  if (waiting || returned) {
    chips.push(`<button type="button" class="chip chip-pending" data-action="open-requests" data-chip="requests">${icon('ui/pending', { size: 16 })}${
      returned ? `${returned} returned to you` : `${waiting} waiting for your DM`}</button>`);
  } else if (g?.governed && !g.is_dm) chips.push(`<button type="button" class="chip chip-quiet" data-action="open-requests" data-chip="requests">${icon('dm/approved', { size: 16 })}Requests</button>`);
  const ws = transformState?.active?.sheet;
  if (ws) {
    chips.push(`<button type="button" class="chip chip-nature" data-action="tf-open-combat" data-chip="wild-shape">${icon('actions/wild-shape', { size: 16 })}Wild Shape: ${esc(ws.creature.name)}</button>`);
  }
  const n = pendingChoices().length + openBuildChoices();
  if (n) chips.push(`<button type="button" class="chip chip-warn choices-badge" id="choices-badge" data-action="goto-choices">${icon('ui/incomplete', { size: 16 })}${n} choice${n === 1 ? '' : 's'} to make</button>`);
  return chips.join('');
}

function renderSheetChips() {
  if (!root) return;
  putHTML($('#sheet-chips', root), sheetChipsHTML());
  putHTML($('#build-next-wrap', root), buildNextSectionHTML());
}

function headerHTML() {
  return `
  <header class="sheet-header">
    <button type="button" class="avatar" id="sheet-avatar" data-action="tab" data-tab="bio" aria-label="Portrait (change it on the Bio tab)">${avatarHTML()}</button>
    <div class="sheet-id">
      <h1 class="char-name" data-derive="name"></h1>
      <p class="char-sub" data-derive="subtitle"></p>
      <div class="sheet-chips" id="sheet-chips">${sheetChipsHTML()}</div>
    </div>
    <div class="sheet-actions" role="group" aria-label="Rests">
      <button type="button" class="btn btn-quiet" data-action="short-rest" title="Restore short-rest resources">${icon('actions/short-rest', { size: 18 })}Short rest</button>
      <button type="button" class="btn btn-quiet" data-action="long-rest" title="Restore HP, slots and resources">${icon('actions/long-rest', { size: 18 })}Long rest</button>
    </div>
  </header>`;
}

function deathSavesHTML() {
  const row = (kind, label) => `
    <div class="death-row">
      <span class="death-label">${label}</span>
      ${[0, 1, 2].map((i) => `<button type="button" class="death-pip ${kind}" data-action="death" data-kind="${kind}" data-i="${i}" aria-label="${label} ${i + 1}"></button>`).join('')}
    </div>`;
  return `<div class="death-saves">${row('success', 'Successes')}${row('failure', 'Failures')}</div>`;
}

/** The vitals panel shown above every section (original character-sheet design): HP card with Damage / Heal, the AC shield,
 *  Initiative, Speed and Proficiency cards, conditions and quick resources. Collapsed, the same components shrink: HP value and
 *  bar, AC shield and the three cards stay; controls, temp field and resources fold away (temp HP and the HP state stay as
 *  badges). The maximum is the authoritative one (base + feat bonus from the server); the base is edited on Build. */
function combatHTML() {
  const c = C();
  const compact = getCompact();
  return `
  <div class="vitals-body" id="vitals-body">
  <div class="combat-grid">
    <div class="hp-card" id="hp-card">
      <div class="hp-top">
        <span class="stat-label">${icon('actions/heal', { size: 16 })}Hit points</span>
        <label class="temp-hp">${icon('ui/temp-hp', { size: 16 })}Temp ${numInput('characters', c, 'hp_temp', 'temp-input', 'min="0" aria-label="Temporary hit points"')}</label>
      </div>
      <div class="hp-form" data-ws-hp hidden></div>
      <div class="hp-row">
        <span class="hp-normal-label">Normal form</span>
        ${numInput('characters', c, 'hp_current', 'hp-current', 'aria-label="Current hit points"')}
        <span class="hp-sep" aria-hidden="true">/</span>
        <span class="hp-max" data-derived="hp-max" aria-label="Maximum hit points ${hpMax(c)}">${hpMax(c)}</span>
        <span class="hp-badges"><span class="hp-temp-badge" data-hp-temp-badge hidden></span><span class="hp-state-text" data-hp-state-text hidden></span></span>
      </div>
      <div class="hp-bar" aria-hidden="true"><div class="hp-fill"></div><div class="hp-temp-fill"></div></div>
      <p class="hp-feat-note small muted" data-derived-hp hidden></p>
      <p class="hp-ws-note small" data-ws-hpnote role="status" aria-live="polite" hidden></p>
      <div class="hp-controls">
        <button type="button" class="btn btn-bad" data-action="hp-damage">Damage</button>
        <input type="number" inputmode="numeric" min="0" id="hp-amount" placeholder="0" aria-label="Amount of damage or healing">
        <button type="button" class="btn btn-good" data-action="hp-heal">Heal</button>
      </div>
      <div class="down-only">${deathSavesHTML()}</div>
    </div>
    <div class="tiles">
      <div class="tile tile-ac"><span class="stat-label" id="ac-label">${icon('equipment-slots/shield', { size: 16 })}<span class="lbl-long">Armor Class</span><span class="lbl-short">AC</span></span>
        <button type="button" class="big-num ac-button" data-action="ac-breakdown" data-focus-key="ac-breakdown" aria-describedby="ac-label ac-note">
          <span data-derived="ac">—</span><span class="sr-only"> (show how it is calculated)</span></button>
        <span class="tile-note" id="ac-note"><span class="lbl-long" data-derived="ac-note"></span><span class="lbl-short" data-derived="ac-note-short"></span></span></div>
      <div class="tile tile-init"><span class="stat-label">${icon('actions/initiative', { size: 16 })}Initiative</span><span class="big-num" data-derive="init"></span></div>
      <div class="tile tile-speed"><span class="stat-label" id="speed-label">${icon('actions/speed', { size: 16 })}Speed</span>
        <span class="big-num" aria-describedby="speed-label speed-note"><span data-derive="speed"></span><span class="unit"> <span data-derive="dist-unit">ft</span></span></span>
        <span class="tile-note" id="speed-note" data-derived="speed-note"></span></div>
      <div class="tile tile-pb"><span class="stat-label">${icon('actions/proficiency', { size: 16 })}<span class="lbl-long">Proficiency</span><span class="lbl-short">Prof.</span></span><span class="big-num" data-derive="pb"></span></div>
    </div>
  </div>
  <div class="vitals-foot">
    <div class="conditions-row" id="conditions-row" role="group" aria-label="Conditions">${conditionsHTML()}</div>
    <div class="resource-strip" id="resource-strip" role="group" aria-label="Quick resources">${stripHTML()}</div>
  </div>
  </div>
  <button type="button" class="compact-toggle" data-action="toggle-compact" aria-controls="vitals-body" aria-expanded="${!compact}"
    aria-label="${compact ? 'Expand vitals' : 'Collapse vitals'}"><span class="ct-text" aria-hidden="true">${compact ? 'More' : 'Less'}</span></button>`;
}

/** HP state in words as well as colour: Bloodied, Critical, Down. */
const HP_STATE_TEXT = { healthy: '', bloodied: 'Bloodied', critical: 'Critical', down: 'Down' };
function hpState(cur, max) {
  const pct = (cur / max) * 100;
  return cur <= 0 ? 'down' : pct <= 25 ? 'critical' : pct <= 50 ? 'bloodied' : 'healthy';
}

// Collapsed or expanded vitals: the player's explicit choice wins; without one, phones start collapsed and wider screens expanded.
const getCompact = () => {
  let v = null;
  try { v = localStorage.getItem('tavern-ledger:compact'); } catch { /* ignore */ }
  return v === '1' || v === '0' ? v === '1' : window.matchMedia('(max-width: 700px)').matches;
};
const setCompact = (on) => { try { localStorage.setItem('tavern-ledger:compact', on ? '1' : '0'); } catch { /* ignore */ } };

const ABBR = { str: 'STR', dex: 'DEX', con: 'CON', int: 'INT', wis: 'WIS', cha: 'CHA' };

/** Senses and movement: derived speed and movement modes, senses, passive scores. Re-rendered with the derived stats. */
function sensesHTML() {
  const sp = derived?.speed;
  const MOVE = { walk: 'Walking', climb: 'Climbing', swim: 'Swimming', fly: 'Flying', burrow: 'Burrowing' };
  const rows = [];
  const kv = (label, value, ic = '') => rows.push(`<div class="kv">${ic ? icon(ic, { size: 18 }) : ''}<span>${label}</span><strong>${value}</strong></div>`);
  kv('Walking speed', `<span data-derive="speed">${esc(deriveValue('speed'))}</span> <span data-derive="dist-unit">${esc(deriveValue('dist-unit'))}</span>`, 'movement.walk');
  Object.entries(sp?.movement || {}).filter(([k]) => k !== 'walk').forEach(([k, m]) =>
    kv(`${MOVE[k] || esc(k)} speed`, `${esc(m.value)} ft${m.active ? '' : ' <span class="muted small">(not in this armor)</span>'}`, `movement.${k}`));
  const senses = Object.entries(derived?.senses || {});
  senses.forEach(([k, x]) => kv(esc(k[0].toUpperCase() + k.slice(1)), `${esc(x.value)} ft`, 'ui.senses'));
  if (!senses.length) rows.push('<div class="kv"><span>Special senses</span><strong class="muted small">none</strong></div>');
  kv('Passive Perception', `<span data-derive="passive:perception">${deriveValue('passive:perception')}</span>`);
  kv('Passive Insight', `<span data-derive="passive:insight">${deriveValue('passive:insight')}</span>`);
  kv('Passive Investigation', `<span data-derive="passive:investigation">${deriveValue('passive:investigation')}</span>`);
  return `<div class="kv-list senses-list">${rows.join('')}</div>`;
}

function statsHTML() {
  const c = C();
  // The original character-sheet layout (v6): six ability cards in STR DEX CON INT WIS CHA order. Each card holds the ability
  // (gold name, modifier, score) on the left and, right of a divider, its saving throw and the skills it governs. Constitution
  // has only its saving throw. Values come from the authoritative derived data; marks granted by a source cannot be removed here.
  const cards = ABILITIES.map((a) => `
    <div class="ab-block" data-ability="${a.key}" role="group" aria-label="${a.name}">
      <div class="ab-left">
        <span class="ability-name">${a.name}</span>
        <span class="ability-mod" data-derive="mod:${a.key}"></span>
        <span class="ab-base-cap" aria-hidden="true">Base</span>
        ${numInput('characters', c, a.col, 'ability-score', `min="1" max="30" aria-label="${a.name} base score" title="Base score: what you rolled or bought. Bonuses from sources are added on top."`)}
        <span class="ab-eff" data-ab-eff="${a.key}"></span>
        <span class="ab-score-pill ab-form-score" data-derived="abform:${a.key}" aria-label="${a.name} score in this form"></span>
        <small class="ab-src" data-derived="absrc:${a.key}"></small>
        <small class="ab-note" data-derived="abnote:${a.key}"></small>
        <div class="ab-srcs-wrap" data-ab-srcs="${a.key}"></div>
      </div>
      <ul class="prof-list ab-list" aria-label="${a.name} saving throw and skills">
        <li class="save-row">
          <button type="button" class="prof-dot save-dot" data-action="toggle-save" data-k="${a.key}" aria-label="${a.name} saving throw proficiency"></button>
          <span class="bonus" data-derive="save:${a.key}"></span>
          <span class="li-name save-label">Saving Throw</span>
          <span class="dis-badge" data-dis="save:${a.key}" hidden>disadvantage</span>
        </li>
        ${SKILLS.filter((sk) => sk.ability === a.key).map((sk) => `
        <li class="skill-row" data-skill="${sk.key}">
          <button type="button" class="prof-dot" data-action="cycle-skill" data-k="${sk.key}" aria-label="${sk.name} proficiency (${a.name})"></button>
          <span class="bonus" data-derive="skill:${sk.key}"></span>
          <span class="li-name">${sk.name}</span>
          <span class="dis-badge" data-dis="skill:${sk.key}" hidden>disadvantage</span>
        </li>`).join('')}
      </ul>
    </div>`).join('');

  return `
  ${sectionHTML({ id: 'abilities-scores', cls: 'ab-section', icon: 'section.ability-scores', title: 'Ability scores and skills',
    body: `<div class="sum-row" role="group" aria-label="Proficiency bonus, passive scores and Inspiration">
        <div class="sum-tile"><span class="stat-label" id="sum-pb">Proficiency</span><strong data-derive="pb"></strong></div>
        <div class="sum-tile"><span class="stat-label" id="sum-pp">Passive Perception</span><strong data-derive="passive:perception"></strong></div>
        <div class="sum-tile"><span class="stat-label" id="sum-pi">Passive Insight</span><strong data-derive="passive:insight"></strong></div>
        <div class="sum-tile sum-insp"><span class="stat-label" id="sum-insp">Inspiration</span>
          <button type="button" class="toggle" data-action="toggle-inspiration" aria-labelledby="sum-insp"></button></div>
      </div>
      <p class="legend ab-legend" id="ab-legend">
        <span><i class="prof-dot"></i> not proficient</span>
        <span><i class="prof-dot on"></i> proficient (+ proficiency bonus)</span>
        <span><i class="prof-dot" data-level="2"></i> expertise (double)</span>
        <span><i class="prof-dot save-dot on"></i> saving-throw proficiency</span>
        <span class="muted">Tap a mark to change it. Marks granted by your class, lineage, background or a feat are applied for you; tapping one shows where it comes from.</span>
      </p>
      <div class="ab-grid" id="ability-cards">${cards}</div>` })}

  <div class="tl-section-row ab-lower">
    <div class="ab-lower-col">
      ${sectionHTML({ id: 'abilities-hitdice', icon: 'section.hit-dice', title: 'Hit Dice',
        body: `<div class="hd-row">
            ${numInput('characters', c, 'hit_dice_current', 'small-num', 'min="0" aria-label="Hit dice remaining"')}
            <span class="muted">of <span data-derive="level"></span></span>
            <select ${cbind('hit_die')} aria-label="Hit die">
              ${HIT_DICE.map((d) => `<option ${c.hit_die === d ? 'selected' : ''}>${d}</option>`).join('')}
            </select>
          </div>
          <h3 class="fantasy-sub-title" id="death-saves-title">Death Saves</h3>
          ${deathSavesHTML()}` })}
      ${sectionHTML({ id: 'abilities-senses', icon: 'section.senses', title: 'Senses and movement',
        body: `<div id="senses-list">${sensesHTML()}</div>
          <h3 class="tl-sub-title">Size, languages, resistances and other traits</h3>
          <div id="lineage-stats">${lineageStatsHTML(derived)}</div>
          <details class="quiet-details tl-detail">
            <summary>Adjust by hand</summary>
            <div class="kv-list">
              <div class="kv"><span>Base walking speed <small class="muted">(before lineage, armor and features)</small></span>${numInput('characters', c, 'speed', 'small-num', 'min="0" aria-label="Base walking speed in feet"')}<small class="us-unit-note muted">in feet (US units)</small></div>
              <div class="kv"><span>Initiative misc. bonus</span>${numInput('characters', c, 'initiative_bonus', 'small-num', 'aria-label="Initiative bonus"')}</div>
            </div>
          </details>` })}
    </div>
    ${sectionHTML({ id: 'abilities-profs', icon: 'section.proficiencies', title: 'Proficiencies',
      desc: 'Armor, weapons, tools and languages you are trained in.',
      body: `<h3 class="tl-sub-title">Armor and weapons</h3>
        <div class="chip-grid" role="group" aria-label="Weapon and armor proficiencies" id="prof-chips">${profChipsHTML()}</div>
        <div id="specific-profs" class="mt">${proficiencyDetailsHTML(profState, { editable: !ctx?.readOnly })}</div>
        <button type="button" class="btn btn-sm mt" data-action="manage-profs" data-focus-key="manage-profs">Add a specific weapon, armor or tool…</button>
        <h3 class="tl-sub-title">Tools and languages</h3>
        <div id="tool-profs">${toolsHTML(derived)}</div>
        <label class="field mt"><span>Tools, languages and other (your notes)</span>
          ${textArea('characters', c, 'proficiencies', 'notes-area', 'placeholder="Tools: Thieves\' tools&#10;Languages: Common, Elvish"')}
        </label>
        <details class="quiet-details tl-detail"><summary>Where do these come from?</summary><p class="muted small prof-legend"><span class="src-badge src-class">Class</span> <span class="src-badge src-lineage">Lineage</span>
          <span class="src-badge src-background">Background</span> grants are automatic; tap one to see why. Tap an inactive one to mark it by hand
          (<span class="src-badge src-manual">Manual</span>).</p></details>` })}
  </div>`;
}

// ---- Shared bits for attack & spell cards ---------------------------------

const damageTypeOptions = (types, selected, allowEmpty = false) =>
  (allowEmpty ? `<option value="" ${!selected ? 'selected' : ''}>—</option>` : '') +
  types.map((t) => `<option value="${t}" ${selected === t ? 'selected' : ''}>${t[0].toUpperCase() + t.slice(1)}</option>`).join('');

const checkField = (table, row, field, label) => `
  <label class="check-field">
    <input type="checkbox" ${bind(table, row, field, 'bool')} ${row[field] ? 'checked' : ''}>
    <span>${label}</span>
  </label>`;

function entryHTML(table, row, viewHTML, editHTML) {
  const key = `${table}:${row.id}`;
  return `
  <article class="entry ${editing.has(key) ? 'editing' : ''}" data-entry="${key}">
    <div class="entry-view" data-view="${key}">${viewHTML}</div>
    <div class="entry-edit">
      ${editHTML}
      <div class="entry-edit-actions">
        <button type="button" class="btn btn-sm btn-bad" data-action="delete-entry" data-key="${key}">Delete</button>
        <button type="button" class="btn btn-sm btn-gold" data-action="toggle-edit" data-key="${key}">Done</button>
      </div>
    </div>
  </article>`;
}

const editButton = (key) =>
  `<button type="button" class="icon-btn edit-btn" data-action="toggle-edit" data-key="${key}" aria-label="Edit">Edit</button>`;

// ---- Attacks -------------------------------------------------------------

function attackViewHTML(a) {
  const meta = [a.attack_kind === 'ranged' ? 'Ranged' : 'Melee', a.range, a.properties].filter(Boolean).map(esc).join(' · ');
  return `
    <div class="entry-head">
      <h3 class="entry-name">${esc(a.name || 'Unnamed attack')}</h3>
      ${editButton(`attacks:${a.id}`)}
    </div>
    <div class="roll-row">
      <div class="roll roll-hit"><span class="roll-label">To hit</span><span class="roll-val">${fmt(attackToHit(a))}</span></div>
      <div class="roll roll-dmg dt-${esc(a.damage_type)}">
        <span class="roll-label">Damage</span>
        <span class="roll-val">${esc(attackDamage(a))}</span>
        <span class="roll-type">${esc(a.damage_type)}</span>
      </div>
    </div>
    ${meta ? `<div class="entry-meta">${meta}</div>` : ''}
    ${a.notes ? `<p class="entry-notes">${esc(a.notes)}</p>` : ''}`;
}

function attackEditHTML(a) {
  const t = 'attacks';
  return `
    <div class="form-grid">
      <label class="field span-2"><span>Name</span>${textInput(t, a, 'name')}</label>
      <label class="field"><span>Melee or ranged</span>
        <select ${bind(t, a, 'attack_kind')}>
          <option value="melee" ${a.attack_kind === 'melee' ? 'selected' : ''}>Melee</option>
          <option value="ranged" ${a.attack_kind === 'ranged' ? 'selected' : ''}>Ranged</option>
        </select></label>
      <label class="field"><span>Range / reach</span>${textInput(t, a, 'range', '', 'placeholder="5 ft or 80/320 ft"')}</label>
      <label class="field"><span>Uses ability</span>
        <select ${bind(t, a, 'ability')}>
          ${ATTACK_ABILITIES.map((x) => `<option value="${x.key}" ${a.ability === x.key ? 'selected' : ''}>${x.label}</option>`).join('')}
        </select></label>
      <label class="field"><span>Magic bonus</span>${numInput(t, a, 'magic_bonus', '', 'placeholder="0"')}</label>
      <label class="field"><span>Damage dice</span>${textInput(t, a, 'damage_dice', '', 'placeholder="1d8"')}</label>
      <label class="field"><span>Damage type</span>
        <select ${bind(t, a, 'damage_type')}>${damageTypeOptions(DAMAGE_TYPES, a.damage_type)}</select></label>
      <div class="span-2 check-row">
        ${checkField(t, a, 'proficient', 'Proficient (adds proficiency to hit)')}
        ${checkField(t, a, 'add_modifier', 'Add ability modifier to damage')}
      </div>
      <label class="field span-2"><span>Properties</span>${textInput(t, a, 'properties', '', 'placeholder="Finesse, light, versatile (1d10)…"')}</label>
      <label class="field span-2"><span>Notes</span>${textArea(t, a, 'notes', '', 'rows="2" placeholder="Extra effects, e.g. +1d6 fire on a hit"')}</label>
    </div>`;
}

const attackHTML = (a) => entryHTML('attacks', a, attackViewHTML(a), attackEditHTML(a));

function attacksListHTML() {
  return B.attacks.length
    ? B.attacks.map(attackHTML).join('')
    : '';   // weapons equipped in the Inventory are listed above; hand-made attacks are optional
}

// ---- Play tab: everything grouped by how you use it ----------------------

const GROUP_HINTS = {
  action: 'One per turn. Anyone can also Attack, Cast a Spell, Dash, Disengage, Dodge, Help, Hide, Ready or Use an Object.',
  bonus_action: 'One per turn, only when a feature or spell gives you one.',
  reaction: 'One per round, also on other creatures’ turns. Anyone can make an opportunity attack when an enemy leaves their reach.',
  special: 'Uses no action: these trigger on something else, for example when you hit with an attack.',
};
const GROUP_TITLES = { action: 'Actions', bonus_action: 'Bonus actions', reaction: 'Reactions', special: 'Free and special' };

/** Active class features with a structured timing (get_character_class_features → activation). Passive ones stay in Build. */
function classActions(key) {
  const out = [];
  for (const cls of classFeatures?.classes || []) {
    for (const f of cls.features || []) {
      if (f.status === 'active' && f.activation === key) out.push({ f, cls });
    }
  }
  return out;
}

function classActionHTML({ f, cls }) {
  const res = (classFeatures?.resources || []).filter((r) => r.unlock_id === f.unlock_id && r.character_class_id === cls.id && r.active);
  const uses = res.map((r) => (r.max == null ? '' : `<span class="chip chip-quiet" data-action-uses="${esc(r.key)}">${esc(r.name)}: ${r.remaining} / ${r.max} left</span>`)).join('');
  return `<article class="entry action-card" data-class-action="${esc(f.unlock_id)}">
    <div class="entry-head"><div class="entry-title"><h3 class="entry-name">${esc(f.name)}</h3>
      <div class="entry-sub">${esc(cls.class_name)}${f.origin === 'subclass' && cls.subclass?.selected ? ` · ${esc(cls.subclass.selected.name)}` : ''}</div></div></div>
    ${f.summary ? `<p class="entry-notes">${esc(f.summary)}</p>` : ''}
    ${uses ? `<div class="chip-row">${uses}</div>` : ''}
  </article>`;
}

function groupItems(key) {
  const feats = B.features.filter((f) => (f.activation || 'passive') === key);
  const spells = key === 'passive'
    ? []
    : B.spells.filter((s) => castingGroup(s.casting_time) === key).sort((a, b) => a.level - b.level);
  return { feats, spells };
}

/** Changes whenever an item moves between groups, so we know when to re-render. */
const combatSignature = () => ACTIVATIONS.map((a) => {
  const g = groupItems(a.key);
  return `${a.key}:${g.feats.map((f) => f.id).join('.')}/${g.spells.map((s) => s.id).join('.')}`;
}).join('|');
let lastCombatSignature = '';

function featureViewHTML(f) {
  const source = FEATURE_CATEGORIES.find((c) => c.key === f.category)?.label.replace(/ Features| Abilities/, '') || '';
  return `
    <div class="entry-head">
      <div class="entry-title">
        <h3 class="entry-name">${esc(f.name || 'Unnamed feature')}</h3>
        ${source ? `<div class="entry-sub">${esc(source)}</div>` : ''}
      </div>
      <button type="button" class="icon-btn edit-btn" data-action="goto-feature" data-id="${f.id}" aria-label="Edit on the Build tab">Edit</button>
    </div>
    ${f.description ? `<p class="entry-notes">${esc(f.description)}</p>` : ''}`;
}

const featureCard = (f) =>
  `<article class="entry combat-feature"><div class="entry-view" data-view="features:${f.id}">${featureViewHTML(f)}</div></article>`;
const spellCard = (s) =>
  `<article class="entry combat-spell"><div class="entry-view" data-view="spells:${s.id}">${spellViewHTML(s)}</div></article>`;

/** Lineage traits and feats for Play, from the lineage, feat and resource reads the sheet already has (no extra request). */
function activeSourceFeatures() {
  if (!playTiming) return { action: [], bonus_action: [], reaction: [], special: [], passive: [], resource: [] };
  return sourceFeatures({ lineage, feats: featState, resources: classResources, timing: playTiming });
}

/** Play after a lineage, feat or timing read: only the timing groups and Ready to use (targeted, no sheet reload). */
function rerenderPlayFeatures() {
  if (!root || !B) return;
  rerender('#combat-groups', combatGroupsHTML());
  rerender('#combat-states', playGlanceHTML());
  $$('[data-play-ready]', root).forEach((el) => { el.hidden = !playGlanceHTML(); });
}

function combatGroupsHTML() {
  lastCombatSignature = combatSignature();
  const empty = [];
  const opts = selectedOptions(classFeatures, classResources);   // Invocations, Metamagic, maneuvers, ... with a catalog timing
  // an option already shown as an attack rider (Eldritch Smite under Attacks) is not repeated as a card
  const riders = new Set((derived?.attack_riders || []).map((r) => String(r.name || '').toLowerCase()));
  for (const k of Object.keys(opts)) opts[k] = opts[k].filter((x) => !riders.has(x.name.toLowerCase()));
  const src = activeSourceFeatures();   // lineage traits and feats with a stated timing (catalog_play_timing)
  const groups = ['action', 'bonus_action', 'reaction', 'special'].map((key) => {
    const { feats, spells } = groupItems(key);
    const items = [...classActions(key).map(classActionHTML), ...(opts[key] || []).map(optionCardHTML), ...(src[key] || []).map(sourceCardHTML),
      ...feats.map(featureCard), ...spells.map(spellCard)].join('');
    if (!items) { if (key !== 'special') empty.push(GROUP_TITLES[key].toLowerCase()); return key === 'action' ? actionBasicsHTML() : ''; }
    return `
      <section class="combat-group group-${key}" aria-labelledby="cg-${key}">
        <h2 class="section-title" id="cg-${key}">${icon(TIMING_ICONS[key], { size: 22 })}${GROUP_TITLES[key]}</h2>
        <p class="group-hint">${GROUP_HINTS[key]}</p>
        <div class="entry-list">${items}</div>
      </section>`;
  }).join('');
  const passive = groupItems('passive').feats;
  const reminders = opts.passive || [];
  const srcReminders = src.passive || [];
  return `${groups}
    ${empty.length > 1 || (empty.length === 1 && empty[0] !== 'actions') ? `<p class="calm-note">No special ${empty.filter((x) => x !== 'actions').join(' or ')} from your features yet.
      Features and spells that use them appear here automatically.</p>` : ''}
    <details class="combat-group passive-group" ${passive.length || reminders.length || srcReminders.length ? '' : 'hidden'} ${reminders.length || srcReminders.length ? 'open' : ''}>
      <summary><span class="section-title">Passive and reminders</span> <span class="count">${passive.length + reminders.length + srcReminders.length}</span>
        <span class="hint">always on, nothing to activate</span></summary>
      ${reminderListHTML(reminders)}
      ${sourceReminderListHTML(srcReminders)}
      <div class="entry-list">${passive.map(featureCard).join('')}</div>
    </details>`;
}

/** The Actions group when no feature adds one: the basic actions anyone can take, as a calm reminder. */
function actionBasicsHTML() {
  return `<section class="combat-group group-action" aria-labelledby="cg-action">
    <h2 class="section-title" id="cg-action">${icon(TIMING_ICONS.action, { size: 22 })}Actions</h2>
    <p class="group-hint">${GROUP_HINTS.action}</p></section>`;
}

function refreshCombat() {
  if (combatSignature() !== lastCombatSignature) rerender('#combat-groups', combatGroupsHTML());
}

// Attacks granted by class features, attacks per Attack action and the critical range (all from the derived stats).
function featureAttacksHTML() {
  const list = derived?.feature_attacks || [];
  const apa = derived?.attacks_per_action?.value || 1;
  const crit = derived?.critical_range?.value || 20;
  const riders = derived?.attack_riders || [];
  if (!list.length && apa === 1 && crit === 20 && !riders.length) return '';
  return `<h3 class="sub-title">From your class features</h3>
    ${apa > 1 || crit < 20 ? `<p class="small" data-attack-rules>${apa > 1 ? `Attack action: <strong>${apa} attacks</strong>. ` : ''}${crit < 20
      ? `Critical hit on <strong>${crit}–20</strong>.` : ''}</p>` : ''}
    <div class="entry-list">${list.map((a) => `<article class="entry card feature-attack" data-feature-attack="${esc(a.name)}">
      <div class="entry-head"><strong>${esc(a.name)}</strong> <span class="muted small">${esc(a.source_name)}</span></div>
      <p>To hit <strong>${fmt(a.attack_bonus)}</strong> · Damage <strong>${esc(a.damage)}</strong> ${esc(a.damage_type || '')}${a.range ? ` · ${esc(a.range)}` : ''}</p>
      ${a.notes ? `<p class="muted small">${esc(a.notes)}</p>` : ''}</article>`).join('')}</div>
    ${riders.length ? `<div class="entry-list" data-attack-riders>${riders.map((r) => `<article class="entry card feature-rider" data-attack-rider="${esc(r.name)}">
      <div class="entry-head"><strong>${esc(r.name)} ${esc(r.dice || riderDiceRange(r))}</strong> <span class="muted small">${esc(r.source_name)}</span></div>
      <p class="small">Extra damage${r.damage_type ? ` (${esc(r.damage_type)})` : ''}${r.once_per_turn ? ', once per turn' : ''}${r.uses_slot
        ? `: spend a ${r.slot_pool === 'pact' ? 'Pact Magic' : 'spell'} slot; the dice depend on its level` : ': add it yourself when the conditions are met'}.</p>
      ${riderSlotButton(r, { editable: !ctx?.readOnly })}
      ${r.condition ? `<p class="muted small">${esc(r.condition)}</p>` : ''}</article>`).join('')}</div>` : ''}`;
}

/** Play's "Ready to use": active states, feature DCs and quick resource buttons (classResources has the uses). */
// Ready to use: the class feature resources plus the lineage counters (Hungry Jaws, Breath Weapon, ...: get_character_resources)
const playGlanceHTML = () => {
  const lineage = (classResources?.resources || []).filter((r) => r.source_type === 'lineage' || (r.source_type === 'feat' && !r.spell_version_id));
  const state = classFeatures || (lineage.length ? { resources: [] } : null);
  return glanceHTML(state && lineage.length ? { ...state, resources: [...(state.resources || []), ...lineage] } : state, derived, !ctx?.readOnly,
    classStates, { attackFacts: false });
};

// ---- weapon cards (js/weapon-card.js): the numbers from the derived read, the item facts from the masked inventory data ----------
/**
 * What the viewer knows about an equipped weapon's inventory row: the Inventory panel's masked view when it is loaded (decoy and
 * revealed facts for an unidentified copy), otherwise only the name on the stored row (the decoy for a disguised copy) and
 * nothing else. Never reads anything.
 */
function weaponInfo(inventoryItemId) {
  const full = inventory?.weaponInfo?.(inventoryItemId);
  if (full) return full;
  const r = (B?.inventory || []).find((x) => x.id === inventoryItemId);
  return r ? { known: null, name: r.custom_name || r.name, attunement: false, attuned: !!r.is_attuned } : null;
}
// weapon action counters (R-D2): the live rows of get_character_resources (already loaded), matched by key 'r:<id>'
const weaponResource = (key) => (classResources?.resources || []).find((r) => r.key === key) || null;
const weaponOpts = () => ({ info: weaponInfo, infused: infusedItemMap(infusionState), resource: weaponResource, editable: !ctx?.readOnly });
/** Re-render the weapon cards only when their markup changed (keeps the focus on an open "How this is calculated"). */
function renderWeapons() {
  const el = root && $('#equipped-weapons', root);
  if (!el) return;
  const html = equippedWeaponsHTML(derived, weaponOpts());
  if (el.__html === html) return;
  const a = document.activeElement;
  const key = a && el.contains(a) ? a.dataset.focusKey : null;
  el.innerHTML = html;
  el.__html = html;
  if (key) $(`[data-focus-key="${CSS.escape(key)}"]`, el)?.focus();
}

function combatTabHTML() {
  const group = (cat, kind, label) => `
    <optgroup label="${label}">
      ${WEAPONS.map((w, i) => (w.cat === cat && w.kind === kind ? `<option value="${i}">${w.name} (${w.dice} ${w.type})</option>` : '')).join('')}
    </optgroup>`;
  return `
  <section class="play-section play-ready" aria-labelledby="play-ready" ${playGlanceHTML() ? '' : 'hidden'} data-play-ready>
    <h2 class="play-title" id="play-ready">${icon('actions/resources', { size: 24 })}Ready to use <span class="hint">uses come back on a rest</span></h2>
    <div id="combat-states">${playGlanceHTML()}</div>
  </section>
  <div id="combat-transform">${wildShapePanelHTML(transformState, { editable: !ctx?.readOnly, place: 'combat' })}</div>

  <section class="play-section" aria-labelledby="play-attacks">
    <h2 class="play-title" id="play-attacks">${icon('ui/attack', { size: 24 })}Attacks</h2>
    <div id="equipped-weapons" class="entry-list">${equippedWeaponsHTML(derived, weaponOpts())}</div>
    <div id="feature-attacks">${featureAttacksHTML()}</div>
    <div id="attacks-list" class="entry-list">${attacksListHTML()}</div>
    <details class="quiet-details add-weapon">
      <summary>Add a weapon or attack by hand</summary>
      <div class="add-tracker mt">
        <select id="weapon-preset" aria-label="Weapon">
          <option value="custom">Custom attack…</option>
          <option value="unarmed">Unarmed strike (1 bludgeoning)</option>
          ${group('simple', 'melee', 'Simple melee')}
          ${group('simple', 'ranged', 'Simple ranged')}
          ${group('martial', 'melee', 'Martial melee')}
          ${group('martial', 'ranged', 'Martial ranged')}
        </select>
        <button type="button" class="btn" data-action="add-attack">Add</button>
      </div>
      <p class="muted small">Weapons you equip in your Inventory appear above automatically. “To hit” and “Damage” of a hand-made attack follow
        your ability scores and proficiency.</p>
    </details>
  </section>

  <div id="combat-groups">${combatGroupsHTML()}</div>
  <div id="play-infusions-slot">${infusionsPlayHTML(infusionState)}</div>

  <section class="play-section" aria-labelledby="play-trackers">
    <div id="trackers-list" class="tracker-list">${trackersListHTML()}</div>
    <details class="quiet-details add-resource">
      <summary>Track a resource by hand</summary>
      <div class="add-tracker mt">
        <select id="tracker-preset" aria-label="Resource type">
          ${RESOURCE_PRESETS.map((p, i) => `<option value="${i}">${p.name}</option>`).join('')}
          <option value="custom">Custom…</option>
        </select>
        <input type="text" id="tracker-custom" placeholder="Custom name" aria-label="Custom resource name" hidden>
        <button type="button" class="btn" data-action="add-tracker">Add</button>
      </div>
      <p class="muted small" id="play-trackers">Class resources are tracked for you. Hand-tracked resources also show in the bar at the top and come back on rests.</p>
    </details>
  </section>

  <section class="play-section" id="companions-card" aria-labelledby="play-companions">
    <h2 class="play-title" id="play-companions">${icon('ui/companion', { size: 24 })}Companions <span class="hint">familiars, steeds and other creatures with you</span></h2>
    <div id="companions-body">${companionsHTML(companions, { editable: !ctx?.readOnly })}</div>
  </section>

  <details class="quiet-details turn-guide">
    <summary>New to combat? How your turn works</summary>
    <ul>
      <li><strong>Move</strong> up to your speed (<span data-derive="speed"></span> <span data-derive="dist-unit">ft</span>). You can split it before and after your action.</li>
      <li><strong>Action</strong>: one per turn, e.g. attack with a weapon or cast a spell.</li>
      <li><strong>Bonus action</strong>: only when a feature or spell says you can use one.</li>
      <li><strong>Reaction</strong>: one per round, even on other creatures’ turns.</li>
      <li><strong>Attacking:</strong> roll a d20 and add <em>To hit</em>. If the total equals or beats the target’s AC, you hit: roll the <em>Damage</em>.</li>
      <li><strong>Saving throw spells:</strong> the target rolls a d20 + their save. If they roll below your <em>DC</em>, the spell’s full effect lands.</li>
      <li><strong>Natural 20</strong> on an attack is a critical hit: roll the damage dice twice.</li>
    </ul>
  </details>

  <section class="tl-section" aria-labelledby="combat-notes-title">
    ${sectionHead({ id: 'combat-notes-title', icon: 'section.notes', title: 'Combat notes', variant: 'interface' })}
    ${textArea('notes', note('attacks'), 'content', 'notes-area', 'placeholder="Tactics, reminders, anything else…" aria-label="Combat notes"')}
  </section>`;
}

// ---- Spells --------------------------------------------------------------

function spellViewHTML(s) {
  const key = `spells:${s.id}`;
  const sub = s.level === 0
    ? `${s.school ? `${esc(s.school)} ` : ''}cantrip`
    : `${ordinal(s.level)}${s.school ? ` · ${esc(s.school)}` : ''}`;
  const from = s.source ? ` · <span class="spell-source">${esc(s.source)}</span>` : '';
  const facts = [
    ['Casting time', s.casting_time], ['Range', s.range], ['Duration', s.duration], ['Components', s.components],
  ].filter(([, v]) => v);

  const rolls = [];
  if (s.attack_type === 'attack') {
    const v = spellAttackBonus();
    rolls.push(`<div class="roll roll-hit"><span class="roll-label">Spell attack</span><span class="roll-val">${v == null ? '?' : fmt(v)}</span></div>`);
  } else if (s.attack_type === 'save') {
    const dc = spellSaveDC();
    const ab = ABILITY_BY_KEY[s.save_ability];
    rolls.push(`<div class="roll roll-save"><span class="roll-label">${ab ? ab.short : 'Target'} save</span><span class="roll-val">DC ${dc == null ? '?' : dc}</span></div>`);
  }
  if (s.damage) {
    const heal = s.damage_type === 'healing';
    rolls.push(`<div class="roll ${heal ? 'roll-heal' : 'roll-dmg'} dt-${esc(s.damage_type)}">
      <span class="roll-label">${heal ? 'Healing' : 'Damage'}</span>
      <span class="roll-val">${esc(s.damage)}</span>
      ${!heal && s.damage_type ? `<span class="roll-type">${esc(s.damage_type)}</span>` : ''}
    </div>`);
  }

  return `
    <div class="entry-head">
      <div class="entry-title">
        <h3 class="entry-name">${esc(s.name || 'Unnamed spell')}</h3>
        <div class="entry-sub">${sub}${from}
          ${s.concentration ? '<span class="tag tag-c" title="Concentration">Concentration</span>' : ''}
          ${s.ritual ? '<span class="tag tag-r" title="Can be cast as a ritual">Ritual</span>' : ''}
        </div>
      </div>
      ${s.level > 0 ? `<button type="button" class="prep-btn ${s.prepared ? 'on' : ''}" data-action="toggle-prepared" data-id="${s.id}" aria-pressed="${!!s.prepared}" title="Prepared today">${s.prepared ? '★ Prepared' : '☆ Prepare'}</button>` : ''}
      ${editButton(key)}
    </div>
    ${facts.length ? `<dl class="facts">${facts.map(([k, v]) => `<div><dt>${k}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>` : ''}
    ${rolls.length ? `<div class="roll-row">${rolls.join('')}</div>` : ''}
    ${s.description ? `<details class="entry-desc"><summary>Description</summary><p>${esc(s.description)}</p></details>` : ''}`;
}

function spellEditHTML(s) {
  const t = 'spells';
  return `
    <div class="form-grid">
      <label class="field span-2"><span>Name</span>${textInput(t, s, 'name')}</label>
      <label class="field"><span>Level</span>
        <select ${bind(t, s, 'level', 'int')}>
          ${[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((l) => `<option value="${l}" ${s.level === l ? 'selected' : ''}>${ordinal(l)}</option>`).join('')}
        </select></label>
      <label class="field"><span>School</span>
        <select ${bind(t, s, 'school')}>
          <option value="" ${!s.school ? 'selected' : ''}>—</option>
          ${SPELL_SCHOOLS.map((x) => `<option ${s.school === x ? 'selected' : ''}>${x}</option>`).join('')}
        </select></label>
      <label class="field"><span>Casting time</span>${textInput(t, s, 'casting_time', '', 'list="casting-times" placeholder="1 action, 1 bonus action, 1 reaction…"')}</label>
      <label class="field"><span>Range</span>${textInput(t, s, 'range', '', 'placeholder="120 ft, Touch, Self…"')}</label>
      <label class="field"><span>Duration</span>${textInput(t, s, 'duration', '', 'placeholder="Instantaneous, 1 minute…"')}</label>
      <label class="field"><span>Components</span>${textInput(t, s, 'components', '', 'placeholder="V, S, M (a pinch of salt)"')}</label>
      <label class="field"><span>Source</span>${textInput(t, s, 'source', '', 'list="spell-sources" placeholder="Class, race, feat, patron, item…"')}</label>
      <div class="span-2 check-row">
        ${checkField(t, s, 'concentration', 'Concentration')}
        ${checkField(t, s, 'ritual', 'Ritual')}
      </div>
      <label class="field"><span>How it hits</span>
        <select ${bind(t, s, 'attack_type')}>
          <option value="none" ${s.attack_type === 'none' ? 'selected' : ''}>No roll needed</option>
          <option value="attack" ${s.attack_type === 'attack' ? 'selected' : ''}>Spell attack roll</option>
          <option value="save" ${s.attack_type === 'save' ? 'selected' : ''}>Target makes a saving throw</option>
        </select></label>
      <label class="field"><span>Saving throw</span>
        <select ${bind(t, s, 'save_ability')}>
          <option value="" ${!s.save_ability ? 'selected' : ''}>—</option>
          ${ABILITIES.map((a) => `<option value="${a.key}" ${s.save_ability === a.key ? 'selected' : ''}>${a.name}</option>`).join('')}
        </select></label>
      <label class="field"><span>Damage / healing dice</span>${textInput(t, s, 'damage', '', 'placeholder="1d10, 3d6, 1d8 + 3"')}</label>
      <label class="field"><span>Type</span>
        <select ${bind(t, s, 'damage_type')}>${damageTypeOptions(SPELL_EFFECT_TYPES, s.damage_type, true)}</select></label>
      <label class="field span-2"><span>Description</span>${textArea(t, s, 'description', '', 'rows="3" placeholder="What the spell does…"')}</label>
    </div>`;
}

const spellHTML = (s) => entryHTML('spells', s, spellViewHTML(s), spellEditHTML(s));

function spellsListHTML() {
  const maxSlot = Math.max(0, ...B.slots.filter((s) => s.total > 0).map((s) => s.level));
  const maxSpell = Math.max(0, ...B.spells.map((s) => s.level));
  const top = Math.max(1, maxSlot, maxSpell);
  const groups = [];
  for (let level = 0; level <= top; level++) {
    const list = B.spells.filter((s) => s.level === level);
    const slot = B.slots.find((s) => s.level === level);
    groups.push(`
      <section class="spell-group">
        <div class="section-head">
          <h4 class="tl-sub-title">${level === 0 ? 'Cantrips' : `Level ${level} spells`}
            ${level === 0 ? '<span class="hint">at will, no slot needed</span>' : ''}
          </h4>
          <div class="row gap">
            ${slot && slot.total > 0 ? `<div class="group-slots" data-pips="slot:${slot.id}">${slotBoxes(slot)}</div>` : ''}
            <button type="button" class="btn btn-sm" data-action="add-spell" data-level="${level}">+ Add</button>
          </div>
        </div>
        <div class="entry-list">${list.map(spellHTML).join('') || '<p class="empty">None yet.</p>'}</div>
      </section>`);
  }
  return groups.join('');
}

function spellsHTML() {
  const c = C();
  const slots = B.slots.map((s) => `
    <div class="slot-row">
      <span class="slot-level">${s.level}</span>
      <div class="slot-pips" data-pips="slot:${s.id}">${slotBoxes(s)}</div>
      <div class="slot-total">
        <button type="button" class="step" data-action="slot-total" data-id="${s.id}" data-d="-1" aria-label="Fewer level ${s.level} slots">−</button>
        <span data-slot-total="${s.id}">${s.total}</span>
        <button type="button" class="step" data-action="slot-total" data-id="${s.id}" data-d="1" aria-label="More level ${s.level} slots">+</button>
      </div>
    </div>`).join('');

  // the free-text list and the manual slot tracker are the old model: folded away unless they hold something
  const legacyUsed = (B.spells || []).length > 0 || !!c.spellcasting_ability || (slotState && slotState.legacy_manual_active && B.slots.some((x) => x.total > 0));
  return `
  <section class="tl-section" id="spellcasting-card" aria-labelledby="spellcasting-title">
    ${sectionHead({ id: 'spellcasting-title', icon: 'section.spells', title: 'Spellcasting', desc: 'Save DC and spell attack of each source.',
      action: '<button type="button" class="btn btn-sm btn-quiet" data-action="spell-source-add" data-focus-key="spell-source-add">Add a source</button>' })}
    <div id="spellcasting-sources">${sourcesHTML(spellbook)}</div>
  </section>
  <section class="tl-section" id="slot-tracker-card" aria-labelledby="slot-tracker-title">
    ${sectionHead({ id: 'slot-tracker-title', icon: 'section.spell-slots', title: 'Spell slots', desc: 'Tap Use when you cast a spell.' })}
    <div id="slot-tracker">${slotTrackerHTML(slotState, { editable: !ctx?.readOnly, pending: slotBusy })}</div>
    <p class="slot-status small" id="slot-status" role="status" aria-live="polite"></p>
    <div id="slot-actions">${slotActionsHTML(classResources, slotState, { editable: !ctx?.readOnly })}</div>
  </section>
  <section class="tl-section" id="spellbook-card" aria-labelledby="spellbook-title">
    ${sectionHead({ id: 'spellbook-title', icon: 'section.spellbook', title: 'Your spells',
      action: '<button type="button" class="btn btn-sm btn-gold" data-action="spell-add" data-focus-key="spell-add">+ Add spell</button>' })}
    <details class="sp-filter-box"><summary>Search and filters</summary><div id="spellbook-filters"></div></details>
    <div id="spellbook-list">${spellbookListHTML(spellbook, spellFilters)}</div>
    <div id="option-spells">${optionSpellsHTML(selectedOptions(classFeatures, classResources).spell)}</div>
  </section>
  <section class="tl-section" data-lineage-spells-card ${derived?.lineage_actions?.length ? '' : 'hidden'} aria-labelledby="lineage-abilities-title">
    ${sectionHead({ id: 'lineage-abilities-title', icon: 'build.lineage', title: 'Lineage abilities', desc: 'Lineage spells are in your spells.' })}
    <div id="lineage-spells">${lineageSpellsHTML(derived, { spells: false })}</div>
  </section>
  <details class="tl-section tl-section-fold spellcasting-card legacy-spells" data-legacy-spells ${legacyUsed ? 'open' : ''}>
    <summary>${sectionHead({ icon: 'ui.custom-content', title: 'Spells written by hand', desc: 'Your own list and manual slots.' })}</summary>
    <div class="spell-stats">
      <label class="field"><span>Ability for free-text spells and spell attacks</span>
        <select ${cbind('spellcasting_ability')}>
          <option value="">—</option>
          ${ABILITIES.map((a) => `<option value="${a.key}" ${c.spellcasting_ability === a.key ? 'selected' : ''}>${a.name}</option>`).join('')}
        </select>
      </label>
      <div class="mini-tile"><span class="stat-label">Spell save DC</span><span class="big-num" data-derive="spelldc"></span></div>
      <div class="mini-tile"><span class="stat-label">Spell attack</span><span class="big-num" data-derive="spellatk"></span></div>
    </div>
    <details class="slot-manager" data-legacy-slots ${slotState && !slotState.legacy_manual_active ? 'hidden' : ''}>
      <summary>Manual spell slots (for characters without classes)</summary>
      <p class="muted small">Use − / + to set how many slots you have. Tap a box to mark it used.</p>
      <div class="slot-list">${slots}</div>
      <button type="button" class="btn btn-sm mt" data-action="reset-slots">Restore all slots</button>
    </details>
    <h3 class="tl-sub-title">Other spells (free text)</h3>
    <div id="spells-list">${spellsListHTML()}</div>
  </details>
  <datalist id="casting-times">${CASTING_TIMES.map((x) => `<option value="${x}">`).join("")}</datalist>
  <datalist id="spell-sources">${[C().class_name, 'Race', 'Feat', 'Patron', 'Subclass', 'Item', 'Background'].filter(Boolean).map((x) => `<option value="${esc(x)}">`).join("")}</datalist>
  <section class="tl-section" aria-labelledby="spell-notes-title">
    ${sectionHead({ id: 'spell-notes-title', icon: 'section.notes', title: 'Spell notes', variant: 'interface' })}
    ${textArea('notes', note('spells'), 'content', 'notes-area', 'placeholder="Anything else about your magic…" aria-label="Spell notes"')}
  </section>`;
}

// Inventory: coins stay here (character columns); items, equipment and the catalog live in inventory-ui.js,
// which reads the inventory views and changes items only through RPCs.
function inventoryHTML() {
  const c = C();
  const coins = ['cp', 'sp', 'ep', 'gp', 'pp'].map((k) => `
    <label class="coin coin-${k}"><span>${k.toUpperCase()}</span>${numInput('characters', c, k, '', 'min="0"')}</label>`).join('');
  return `
  <div id="inventory-app" class="inventory-app">
    <div class="card inv-state"><div class="spinner"></div><p class="muted">Loading inventory…</p></div>
  </div>
  <section class="tl-section inv-coins" aria-labelledby="coins-title">
    ${sectionHead({ id: 'coins-title', icon: 'section.coins', title: 'Coins' })}
    <div class="coins">${coins}</div>
    <p class="coin-calc-open"><button type="button" class="btn btn-sm" data-action="coin-calc" aria-haspopup="dialog">Add or spend…</button>
      <span class="muted small">works out the change for you</span></p>
  </section>`;
}

/** Shape the inventory view rows like the legacy rows (export, cached bundle, list previews). */
const legacyInventoryRow = (r) => ({
  ...r, name: r.custom_name || r.name, weight: Number(r.unit_weight_lb ?? 0), description: r.description ?? '',
});

function featureHTML(f) {
  return `
  <div class="feature card" data-feature="${f.id}">
    <div class="feature-head">
      ${textInput('features', f, 'name', 'feature-name', 'aria-label="Feature name" placeholder="Feature name"')}
      <button type="button" class="icon-btn danger" data-action="delete-feature" data-id="${f.id}" aria-label="Delete feature">Delete</button>
    </div>
    <div class="feature-meta">
      <label class="field-inline"><span>Type (how you use it)</span>
        <select ${bind('features', f, 'activation')} class="activation-select act-${esc(f.activation || 'passive')}">
          ${ACTIVATIONS.map((a) => `<option value="${a.key}" ${(f.activation || 'passive') === a.key ? 'selected' : ''}>${a.label}</option>`).join('')}
        </select>
      </label>
      <label class="field-inline"><span>Source</span>
        <select ${bind('features', f, 'category')}>
          ${FEATURE_CATEGORIES.map((c) => `<option value="${c.key}" ${f.category === c.key ? 'selected' : ''}>${c.label}</option>`).join('')}
        </select>
      </label>
    </div>
    ${textArea('features', f, 'description', 'feature-desc', 'rows="2" placeholder="What does it do?"')}
  </div>`;
}

/** "Next steps" at the top of Build: open choices, Level Up (or why not), requests. */
function buildNextHTML() {
  const items = [];
  const open = openBuildChoices();
  if (open) items.push(`<li>${icon('ui/incomplete', { size: 20 })}<span><strong>${open} class choice${open === 1 ? '' : 's'}</strong> to make</span>
    <button type="button" class="btn btn-sm" data-action="build-goto" data-target="#class-features-card">Show</button></li>`);
  const feat = (featState?.feats || []).reduce((n, f) => n + ((f.choices || []).filter((c) => c.open || c.status === 'incomplete').length), 0);
  if (feat) items.push(`<li>${icon('ui/feat', { size: 20 })}<span><strong>${feat} feat choice${feat === 1 ? '' : 's'}</strong> open</span>
    <button type="button" class="btn btn-sm" data-action="build-goto" data-target="#feats-card">Show</button></li>`);
  if (lineage && !lineage.selected) items.push(`<li>${icon('ui/lineage', { size: 20 })}<span>No lineage chosen yet</span>
    <button type="button" class="btn btn-sm" data-action="build-goto" data-target="#lineage-card">Choose</button></li>`);
  if (background && !background.selected) items.push(`<li>${icon('ui/background', { size: 20 })}<span>No background chosen yet</span>
    <button type="button" class="btn btn-sm" data-action="build-goto" data-target="#background-card">Choose</button></li>`);
  const n = pendingChoices().length;
  if (n) items.push(`<li>${icon('ui/notes', { size: 20 })}<span>${n} reminder${n === 1 ? '' : 's'} to decide</span>
    <button type="button" class="btn btn-sm" data-action="build-goto" data-target="#choices-card">Show</button></li>`);
  return items.length ? `<ul class="next-list">${items.join('')}</ul>`
    : `<p class="calm-note">${icon('dm/approved', { size: 20 })}Everything is chosen. Your next decisions come with the next level.</p>`;
}

/** Next steps: a highlighted section only when something is open; otherwise one quiet row with the Level up button. */
function buildNextSectionHTML() {
  const open = buildNextHTML();
  const has = open.startsWith('<ul');
  return `<section class="tl-section build-next-card ${has ? 'tl-section-emph' : 'tl-section-quiet'}" aria-labelledby="build-next-title" data-has-steps="${has}">
    ${sectionHead({ id: 'build-next-title', icon: 'build.next', title: has ? 'Next steps' : 'Up to date',
      action: `<div class="level-up-slot" id="level-up-slot">${levelUpButtonHTML()}</div>` })}
    <div id="build-next">${open}</div>
  </section>`;
}

function featuresHTML() {
  return `
  <div id="build-next-wrap">${buildNextSectionHTML()}</div>
  <section class="tl-section" id="class-card" aria-labelledby="class-card-title">
    ${sectionHead({ id: 'class-card-title', icon: 'build.class', title: 'Classes' })}
    <div id="class-card-body">${classCardHTML(classSummary, classCatalog, { editable: !ctx?.readOnly })}</div>
    <div id="class-feature-summary">${featureSummaryHTML(classFeatures)}</div>
    <div class="kv-list build-hp">
      <div class="kv"><span>Maximum hit points <small class="muted">(base, before feats; Damage and Heal are in the vitals)</small></span>${
        numInput('characters', C(), 'hp_max', 'small-num hp-max-base', 'min="1" aria-label="Maximum hit points (base)"')}</div>
    </div>
  </section>
  <section class="tl-section" id="class-features-card" aria-labelledby="class-features-title">
    ${sectionHead({ id: 'class-features-title', icon: 'build.class-features', title: 'Class features', desc: 'What your classes and subclasses give you.' })}
    <div id="class-transform">${wildShapePanelHTML(transformState, { editable: !ctx?.readOnly, place: 'class' })}</div>
    <div id="class-features">${featuresPanelHTML(classFeatures, { editable: !ctx?.readOnly, derived, states: classStates })}</div>
    <details class="quiet-details tl-detail" id="class-resources-card">
      <summary>Resources: limits, dice and recovery</summary>
      <div id="class-resources">${resourceListHTML(classResources, { editable: !ctx?.readOnly })}</div>
    </details>
  </section>
  <div id="infusions-slot">${infusionsHTML(infusionState, { editable: !ctx?.readOnly })}</div>
  <div class="tl-section-row build-identity">
    <section class="tl-section identity-section" id="lineage-card" aria-labelledby="lineage-card-title">${lineageSectionHTML()}</section>
    <section class="tl-section identity-section" id="background-card" aria-labelledby="background-card-title">
      ${sectionHead({ id: 'background-card-title', icon: 'build.background', title: 'Background', desc: 'Ability increases, proficiencies, feat and equipment.' })}
      <div id="background-card-body">${backgroundCardHTML(background, { editable: !ctx?.readOnly, legacyText: C().background })}</div>
    </section>
  </div>
  <section class="tl-section feats-card" id="feats-card" aria-labelledby="feats-card-title">${featsCardHTML(featState, { editable: !ctx?.readOnly, removal: featRemovalPolicy() })}</section>
  <details class="tl-section tl-section-fold" id="choices-card" ${pendingChoices().length ? 'open' : ''}>
    <summary>${sectionHead({ icon: 'build.reminders', variant: 'interface', title: 'Reminders', count: pendingChoices().length || '', desc: 'Choices you want to make later.' })}</summary>
    <div id="choices-list" class="choice-list">${choicesListHTML()}</div>
    <details class="add-choice mt">
      <summary>Add a reminder</summary>
      <form id="add-choice-form" class="form-grid mt">
        <label class="field"><span>What to decide</span><input type="text" name="type" required placeholder="e.g. Fighting Style" list="choice-types"></label>
        <label class="field"><span>Options (comma separated)</span><input type="text" name="options" placeholder="Defense, Dueling, Protection"></label>
        <label class="field span-2"><span>Description</span><input type="text" name="description" placeholder="Choose a Paladin Fighting Style"></label>
        <div class="span-2"><button type="submit" class="btn btn-sm">Add reminder</button></div>
      </form>
      <datalist id="choice-types">${['Fighting Style', 'Druid Circle', 'Warlock Invocation', 'Language Choice', 'Skill Choice', 'Spell Choice', 'Tool Choice', 'Feat Choice', 'Subclass'].map((x) => `<option value="${x}">`).join('')}</datalist>
    </details>
  </details>
  <details class="tl-section tl-section-fold own-notes" ${B.features.length ? 'open' : ''}>
    <summary>${sectionHead({ icon: 'build.own-features', variant: 'interface', title: 'Your own features', count: B.features.length || '', desc: 'Anything the app does not track, written by you.' })}</summary>
    <div id="features-list">${featuresListHTML()}</div>
  </details>`;
}

function featuresListHTML() {
  const used = FEATURE_CATEGORIES.filter((cat) => B.features.some((f) => f.category === cat.key));
  const groups = used.map((cat) => {
    const list = B.features.filter((f) => f.category === cat.key);
    return `
    <section class="feature-group">
      <div class="section-head">
        <h4>${cat.label} <span class="count">${list.length}</span></h4>
        <button type="button" class="btn btn-sm btn-quiet" data-action="add-feature" data-cat="${cat.key}">Add</button>
      </div>
      ${list.map(featureHTML).join('')}
    </section>`;
  }).join('');
  return `${groups || '<p class="empty">Nothing written yet.</p>'}
    <div class="add-feature-row" role="group" aria-label="Add your own feature">
      <span class="muted small">Add:</span>
      ${FEATURE_CATEGORIES.map((cat) => `<button type="button" class="btn btn-sm btn-quiet" data-action="add-feature" data-cat="${cat.key}">${esc(cat.label.replace(/ Features| Abilities/, ''))}</button>`).join('')}
    </div>`;
}

function trackerRowHTML(t) {
  return `
  <div class="tracker card" data-tracker="${t.id}">
    ${textInput('feature_trackers', t, 'name', 'tracker-name', 'aria-label="Resource name"')}
    <label class="field-inline"><span>Current</span>${numInput('feature_trackers', t, 'current', 'small-num', 'min="0"')}</label>
    <label class="field-inline"><span>Max</span>${numInput('feature_trackers', t, 'max', 'small-num', 'min="0"')}</label>
    <label class="field-inline tracker-formula"><span>Max formula</span>${textInput('feature_trackers', t, 'formula', '', 'placeholder="e.g. monkLevel" aria-label="Formula for the maximum"')}</label>
    <label class="field-inline"><span>Resets</span>
      <select ${bind('feature_trackers', t, 'reset_on')}>
        ${Object.entries(RESET_LABELS).map(([k, l]) => `<option value="${k}" ${t.reset_on === k ? 'selected' : ''}>${l}</option>`).join('')}
      </select>
    </label>
    <button type="button" class="icon-btn danger" data-action="delete-tracker" data-id="${t.id}" aria-label="Delete resource">Delete</button>
  </div>`;
}

function trackersListHTML() {
  return B.trackers.map(trackerRowHTML).join('');
}

function notesHTML() {
  const block = (kind, title, placeholder) => `
    <div class="card notes-card">
      <h3 class="tl-sub-title">${title}</h3>
      ${textArea('notes', note(kind), 'content', 'notes-area tall', `placeholder="${placeholder}" aria-label="${title}"`)}
    </div>`;
  return `
  <section class="tl-section" id="notes-section" aria-labelledby="notes-title">
    ${sectionHead({ id: 'notes-title', icon: 'section.notes', variant: 'interface', title: 'Notes', desc: 'Notes save automatically as you type.' })}
    <div class="notes-grid">
      ${block('character', 'Character notes', 'Personality, ideals, bonds, flaws, backstory…')}
      ${block('session', 'Session notes', 'What happened this session, loot, leads, things to remember next time…')}
      ${block('campaign', 'Campaign notes', 'NPCs, places, factions, quests, the bigger picture…')}
    </div>
  </section>`;
}

function bioHTML() {
  const c = C();
  const manage = canManageCharacter(c);
  // Admin: anyone. Campaign DM: members of this character's campaign.
  const owners = isAdmin()
    ? state.profiles
    : state.profiles.filter((p) => p.id === c.owner_id || campaignMembers(c.campaign_id).some((m) => m.user_id === p.id));
  const ownerSelect = manage && owners.length ? `
    <label class="field"><span>Player (owner)</span>
      <select ${cbind('owner_id')}>
        ${owners.map((p) => `<option value="${p.id}" ${p.id === c.owner_id ? 'selected' : ''}>${esc(p.display_name || p.email)}</option>`).join('')}
      </select>
    </label>` : '';
  const camps = myCampaigns();
  const current = state.campaigns.find((k) => k.id === c.campaign_id);
  const campaignSelect = `
    <label class="field"><span>Campaign</span>
      <select ${cbind('campaign_id', 'nullable')}>
        ${[...camps, ...(current && !camps.includes(current) ? [current] : [])].map((k) =>
          `<option value="${k.id}" ${k.id === c.campaign_id ? 'selected' : ''}>${esc(k.name)}</option>`).join('')}
        <option value="" ${!c.campaign_id ? 'selected' : ''}>— No campaign —</option>
      </select>
    </label>`;
  // the free-text class / subclass / background fields predate the class and background catalogs: folded once those exist
  const legacy = `
      <label class="field"><span>Class (free text)</span>${textInput('characters', c, 'class_name', '', 'list="class-list"')}</label>
      <label class="field"><span>Subclass (free text)</span>${textInput('characters', c, 'subclass')}</label>
      <label class="field"><span>Background (free text)</span>${textInput('characters', c, 'background', '', 'aria-describedby="bg-free-hint"')}
        <small class="muted" id="bg-free-hint">Used only without a background from the catalog (Build tab)</small></label>`;
  return `
  <section class="tl-section bio-identity" aria-labelledby="bio-identity-title">
    ${sectionHead({ id: 'bio-identity-title', icon: 'identity.generic', title: 'Identity' })}
    <div class="portrait-editor">
      <div class="avatar avatar-lg" id="portrait-preview">${avatarHTML()}</div>
      <div class="stack grow">
        <label class="field"><span>Name</span>${textInput('characters', c, 'name')}</label>
        <div class="row gap">
          <label class="btn btn-sm file-btn">Upload portrait
            <input type="file" accept="image/*" id="portrait-file" hidden>
          </label>
          <button type="button" class="btn btn-sm btn-quiet" data-action="remove-portrait">Remove portrait</button>
        </div>
        <details class="quiet-details"><summary>Use an image link instead</summary>
          <label class="field mt"><span>Image URL</span>${textInput('characters', c, 'portrait_url', '', 'placeholder="https://…" inputmode="url"')}</label></details>
      </div>
    </div>
    <div class="form-grid mt">
      <label class="field"><span>Alignment</span>${textInput('characters', c, 'alignment', '', 'list="alignment-list"')}</label>
      <label class="field"><span>Experience</span>${numInput('characters', c, 'experience', '', 'min="0"')}<small class="muted" data-derive="xpnext"></small></label>
      <label class="field"><span>Level</span><span id="level-field" class="level-field">${levelFieldHTML()}</span></label>
      ${campaignSelect}
      ${ownerSelect}
    </div>
    ${hasClasses() ? `<details class="quiet-details mt" data-legacy-identity><summary>Free-text class and background</summary>
      <div class="form-grid mt">${legacy}</div></details>` : `<div class="form-grid mt">${legacy}</div>`}
    <datalist id="class-list">${CLASSES.map((x) => `<option value="${x}">`).join('')}</datalist>
    <datalist id="alignment-list">${ALIGNMENTS.map((x) => `<option value="${x}">`).join('')}</datalist>
  </section>
  ${notesHTML()}
  <section class="tl-section" aria-labelledby="bio-display-title" data-units-section>
    ${sectionHead({ id: 'bio-display-title', icon: 'ui.senses', title: 'Display', variant: 'interface' })}
    <p class="muted small">Measurements on your screen. Metric converts distances and weights for display only (5 ft = 1.5 m, 1 mile = 1.5 km,
      1 lb = 0.5 kg); what is saved, what the DM enters and the number fields stay in US units. Only for you, on this device.</p>
    ${unitsSwitchHTML()}
  </section>
  <section class="tl-section" aria-labelledby="bio-backup-title">
    ${sectionHead({ id: 'bio-backup-title', icon: 'item.book', title: 'Backup and sharing', variant: 'interface' })}
    <p class="muted small">Download this character as a file. You can import it again from the character list, for example to copy a character or move it to another campaign.</p>
    <button type="button" class="btn btn-sm" data-action="export-json">Download character file (JSON)</button>
  </section>
  <section class="tl-section danger-zone" aria-labelledby="bio-delete-title">
    ${sectionHead({ id: 'bio-delete-title', title: 'Delete character', variant: 'interface' })}
    <p class="muted small">Deleting a character removes its inventory, notes, features and resources permanently.</p>
    <button type="button" class="btn btn-bad" data-action="delete-character">Delete character…</button>
  </section>`;
}

function tabsHTML(active) {
  return TABS.map((t) => `<button type="button" role="tab" class="tab" id="tab-${t.key}" data-action="tab" data-tab="${t.key}"
      aria-controls="panel-${t.key}" aria-selected="${t.key === active}" tabindex="${t.key === active ? 0 : -1}" title="${esc(t.hint)}">
      ${icon(SECTION_ICONS[t.key], { size: 22, cls: 'tab-icon' })}<span class="tab-label">${t.label}</span><span class="tab-short">${t.short}</span></button>`).join('');
}

function render() {
  const active = TABS.some((t) => t.key === getTab()) ? getTab() : 'combat';
  root.innerHTML = `
  <div class="sheet">
    ${headerHTML()}
    <div class="gov-bar" id="gov-bar" hidden></div>
    <section class="combat-bar ${getCompact() ? 'compact' : ''}" aria-label="Vitals">${combatHTML()}</section>
    <nav class="tabs" role="tablist" aria-label="Character sections">${tabsHTML(active)}</nav>
    <div class="panels">
      <section class="panel" id="panel-combat" role="tabpanel" aria-labelledby="tab-combat" data-panel="combat">${combatTabHTML()}</section>
      <section class="panel" id="panel-stats" role="tabpanel" aria-labelledby="tab-stats" data-panel="stats">${statsHTML()}</section>
      <section class="panel" id="panel-spells" role="tabpanel" aria-labelledby="tab-spells" data-panel="spells">${spellsHTML()}</section>
      <section class="panel" id="panel-inventory" role="tabpanel" aria-labelledby="tab-inventory" data-panel="inventory">${inventoryHTML()}</section>
      <section class="panel" id="panel-features" role="tabpanel" aria-labelledby="tab-features" data-panel="features">${featuresHTML()}</section>
      <section class="panel" id="panel-quests" role="tabpanel" aria-labelledby="tab-quests" data-panel="quests"><div class="tl-section quest-tab" id="quests-app"></div></section>
      <section class="panel" id="panel-bio" role="tabpanel" aria-labelledby="tab-bio" data-panel="bio">${bioHTML()}</section>
    </div>
  </div>`;
  showTab(active, false);
  refreshDerived();
  refreshToggles();
  refreshHp();
}

function showTab(key, scroll = true) {
  key = TAB_ALIAS[key] || key;
  setTab(key);
  $$('.tab', root).forEach((t) => {
    const on = t.dataset.tab === key;
    t.setAttribute('aria-selected', on);
    t.tabIndex = on ? 0 : -1;
  });
  $$('.panel', root).forEach((p) => { p.hidden = p.dataset.panel !== key; });
  $$(`.panel[data-panel="${key}"] textarea.autosize`, root).forEach(autoResize);
  if (key === 'spells' && spellbookStale) loadSpellbook();
  if (key === 'inventory' && inventoryDeferred) mountInventoryPanel();
  if (key === 'quests') openQuests();
  if (scroll) {
    // land at the top of the section (below the vitals), never further down than where the player already is
    const panel = $(`.panel[data-panel="${key}"]`, root);
    const top = panel.getBoundingClientRect().top + window.scrollY - (parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--topbar-h')) || 56) - 8;
    if (window.scrollY > top) window.scrollTo({ top, behavior: reducedMotion() ? 'auto' : 'smooth' });
    $(`.tab[data-tab="${key}"]`, root)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
}

const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

/** Arrow keys move between section tabs (WAI-ARIA tabs pattern); Home / End jump to the first / last. */
function onTabKey(e) {
  const tab = e.target.closest?.('.tab');
  if (!tab || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
  const tabs = $$('.tab', root);
  const i = tabs.indexOf(tab);
  const next = e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : (i + (e.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
  e.preventDefault();
  tabs[next].focus();
  showTab(tabs[next].dataset.tab);
}

/** The compact HP / AC readout in the top bar, shown once the vitals bar has scrolled out of view. */
let vitalsObserver = null;
function topbarVitalsHTML() {
  const c = C();
  const ws = transformState?.active?.sheet;
  const hp = ws ? `${ws.hp.current}/${ws.hp.max}` : `${c.hp_current}/${hpMax(c)}`;
  return `<span class="tv-name">${esc(c.name || '')}</span>
    <span class="tv-stat">${icon('actions/heal', { size: 16 })}<span class="sr-only">${ws ? `${esc(ws.creature.name)} hit points` : 'Hit points'} </span>${hp}</span>
    <span class="tv-stat">${icon('equipment-slots/shield', { size: 16 })}<span class="sr-only">Armor Class </span>${derived?.armor_class?.value ?? '—'}</span>`;
}
function refreshTopbarVitals() {
  const el = document.getElementById('topbar-vitals');
  if (el && B) el.innerHTML = topbarVitalsHTML();
}
function watchVitals() {
  const el = document.getElementById('topbar-vitals');
  const bar = $('.combat-bar', root);
  if (!el || !bar || !('IntersectionObserver' in window)) return;
  vitalsObserver?.disconnect();
  vitalsObserver = new IntersectionObserver(([en]) => { el.hidden = en.isIntersecting || !B; if (!el.hidden) refreshTopbarVitals(); },
    { rootMargin: `-${(parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--topbar-h')) || 56)}px 0px 0px 0px` });
  vitalsObserver.observe(bar);
  el.onclick = () => window.scrollTo({ top: 0, behavior: reducedMotion() ? 'auto' : 'smooth' });
}

/** Re-render a container while keeping the focused field (if any) focused. */
function rerender(selector, html) {
  const el = $(selector, root);
  if (!el) return;
  const a = document.activeElement;
  const keep = a && el.contains(a) && a.dataset.f
    ? { t: a.dataset.t, id: a.dataset.id, f: a.dataset.f, s: a.selectionStart, e: a.selectionEnd }
    : null;
  el.innerHTML = html;
  $$('textarea.autosize', el).forEach(autoResize);
  if (keep) {
    const next = $(`[data-t="${keep.t}"][data-id="${keep.id}"][data-f="${keep.f}"]`, el);
    if (next) {
      next.focus();
      try { next.setSelectionRange(keep.s, keep.e); } catch { /* not a text field */ }
    }
  }
}

function rerenderList(table) {
  if (table === 'inventory_items') inventory?.scheduleRefresh();
  if (table === 'features') rerender('#features-list', featuresListHTML());
  if (table === 'feature_trackers') { rerender('#trackers-list', trackersListHTML()); renderStrip(); }
  if (table === 'attacks') rerender('#attacks-list', attacksListHTML());
  if (table === 'spells' || table === 'spell_slots') rerender('#spells-list', spellsListHTML());
  if (table === 'spells' || table === 'features') rerender('#combat-groups', combatGroupsHTML());
  if (table === 'spell_slots') refreshPips();
  afterChange(table);
}

// -----------------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------------

// Damage / Heal: one atomic server change (apply_character_hp), so a DM's change in the Combat Builder and the player's
// click can never overwrite each other; the sheet shows the server's values. A second click waits for the first.
let hpBusy = false;
async function applyHp(sign) {
  const input = $('#hp-amount', root);
  const amt = parseInt(input.value, 10);
  if (!amt || amt < 0) {
    input.focus();
    toast('Enter an amount first');
    return;
  }
  if (transformState?.active?.sheet) {         // in Wild Shape the form takes the damage / healing (normal HP is protected)
    input.value = '';
    formHp(sign, amt, 'hp');
    return;
  }
  if (hpBusy) return;
  hpBusy = true;
  const c = C();
  const buttons = $$('[data-action="hp-damage"], [data-action="hp-heal"]', root);
  buttons.forEach((b) => b.setAttribute('aria-busy', 'true'));
  try {
    await saver.flush();   // an HP value typed a moment ago is stored first, so the change starts from it
    const r = await applyCharacterHp(c.id, sign < 0 ? 'damage' : 'heal', amt);
    if (r?.form) {         // a Wild Shape form started elsewhere: the form took it (the server's result is announced)
      await tfApplied(r.wild_shape, { quiet: true });
      if (r.applied !== false && !r.wild_shape?.result?.ended) toast(sign < 0 ? `The form takes ${amt} damage.` : 'The form regains hit points.');
    } else if (r?.after) {
      const patch = { hp_current: r.after.hp, hp_temp: r.after.temp, death_successes: r.after.death_successes, death_failures: r.after.death_failures };
      serverChar = { ...serverChar, ...patch };
      Object.assign(c, patch);
      syncInputs('characters', c.id);
      afterChange('characters');
      if (sign < 0) toast(`Took ${amt} damage${r.absorbed ? ` (${r.absorbed} from temporary HP)` : ''}: ${c.hp_current} / ${hpMax(c)}.`);
      else toast(`Healed ${amt}: ${c.hp_current} / ${hpMax(c)}.`, 'good');
    }
    input.value = '';
  } catch (err) {
    toast(err.message || 'Hit points were not changed.', 'bad');
  } finally {
    hpBusy = false;
    buttons.forEach((b) => b.removeAttribute('aria-busy'));
  }
}

// Slots, Pact Magic, trackers, manual slots and resources are restored by the server in one transaction (short_rest_character /
// long_rest_character). HP, temp HP, death saves and hit dice keep the app's existing long-rest step, applied afterwards.
async function rest(kind) {
  const long = kind === 'long';
  const ok = await confirmDialog([restDescription(kind, slotState), ...restResourceLines(kind, classResources)].join('\n'),
    { title: long ? 'Long Rest' : 'Short Rest', okLabel: long ? 'Take long rest' : 'Take short rest' });
  if (!ok) return;
  await saver.flush();
  const res = long ? await longRest(C().id) : await shortRest(C().id);
  for (const name of res.restored.trackers || []) {          // mirror the server's tracker reset locally right away
    const t = B.trackers.find((x) => x.name === name);
    if (t) t.current = t.max;
  }
  const extra = [];
  if (long) {
    const c = C();
    const dice = Math.min(c.level, c.hit_dice_current + Math.max(1, Math.floor(c.level / 2))) - c.hit_dice_current;
    if (c.hp_current < hpMax(c)) extra.push(`Hit points: back to ${hpMax(c)}`);
    if (dice > 0) extra.push(`Hit dice: ${dice} regained`);
    setRow('characters', c, {
      hp_current: hpMax(c),
      hp_temp: 0,
      death_successes: 0,
      death_failures: 0,
      hit_dice_current: Math.min(c.level, c.hit_dice_current + Math.max(1, Math.floor(c.level / 2))),
    });
    for (const s of B.slots) s.used = 0;
  }
  rerenderList('feature_trackers');
  rerenderList('spell_slots');
  renderStrip();
  slotEpoch += 1;
  await loadClasses();
  const title = long ? 'Long Rest completed' : 'Short Rest completed';
  const st = root && $('#slot-status', root);
  if (st) { st.textContent = `${title}. ${restResultText(res)}`; st.dataset.kind = 'good'; }
  const m = openModal({ title, body: restSummaryHTML(res, { extra }),
    footer: '<button type="button" class="btn btn-gold" data-close data-rest-ok>OK</button>' });
  setTimeout(() => { if (m.isTop()) $('[data-rest-ok]', m.el)?.focus(); }, 60);
}

async function addTracker() {
  const sel = $('#tracker-preset', root);
  let name;
  let reset = 'long';
  if (sel.value === 'custom') {
    name = $('#tracker-custom', root).value.trim();
    if (!name) { $('#tracker-custom', root).focus(); toast('Give the resource a name'); return; }
  } else {
    ({ name, reset } = RESOURCE_PRESETS[Number(sel.value)]);
  }
  const row = await insertRow('feature_trackers', {
    character_id: C().id, name, current: 1, max: 1, reset_on: reset, sort_order: B.trackers.length,
  });
  if (!B.trackers.some((t) => t.id === row.id)) B.trackers.push(row);
  $('#tracker-custom', root).value = '';
  rerenderList('feature_trackers');
  const maxInput = $(`[data-t="feature_trackers"][data-id="${row.id}"][data-f="max"]`, root);
  maxInput?.focus();
  maxInput?.select();
  toast(`${name} added — set its maximum.`, 'good');
}

async function addFeature(category) {
  const row = await insertRow('features', {
    character_id: C().id, category, name: 'New feature', sort_order: B.features.length,
  });
  if (!B.features.some((f) => f.id === row.id)) B.features.push(row);
  rerenderList('features');
  const input = $(`[data-t="features"][data-id="${row.id}"][data-f="name"]`, root);
  input?.focus();
  input?.select();
}

// ---- Conditions ------------------------------------------------------------
// character_conditions (20261112000200) is the store: every change goes through an RPC and the server answers with the
// caller's view. characters.conditions is only written directly on an older server (setConditions, the old path).

function setConditions(list) {
  setRow('characters', C(), { conditions: list });
}

const TAG_TYPES = [['resistance', 'Resistant to'], ['immunity', 'Immune to'], ['vulnerability', 'Vulnerable to'],
  ['condition_immunity', 'Immune to a condition'], ['blessing', 'Blessed'], ['curse', 'Cursed'], ['other', 'Other (free text)']];
const DAMAGE_TAGS = new Set(['resistance', 'immunity', 'vulnerability']);
const SRD_KEYS = new Set(['blinded', 'charmed', 'deafened', 'frightened', 'grappled', 'incapacitated', 'invisible', 'paralyzed',
  'petrified', 'poisoned', 'prone', 'restrained', 'stunned', 'unconscious']);
const condBusy = new Set();
const capFirst = (x) => x[0].toUpperCase() + x.slice(1);

/** One condition RPC: the answer is the caller's whole list (the chips re-render from it). */
async function conditionChange(key, fn, done) {
  if (condBusy.has(key)) return false;
  condBusy.add(key);
  const id = C().id;
  try {
    const rows = await fn();
    if (B && C().id === id) { condSeq += 1; condRows = rows; refreshCharacterBits(); }   // newer than any read in flight
    if (done) toast(done, 'good');
    return true;
  } catch (err) {
    toast(err.message || 'The condition was not changed.', 'bad');
    return false;
  } finally { condBusy.delete(key); }
}

function conditionOptionsHTML(dm) {
  return `
    <div class="cond-options">
      <label class="field"><span>Note (optional)</span><input name="note" maxlength="500" placeholder="e.g. Potion of Fire Resistance"></label>
      <label class="field"><span>Duration (optional)</span><input name="duration_text" maxlength="80" placeholder="e.g. 1 hour, until dawn"></label>
      ${dm ? `<label class="cond-hidden-toggle"><input type="checkbox" name="hidden"> ${icon('ui.dm-secret', { size: 16 })}<span>Hidden from the player (DM only)</span></label>
      <label class="field"><span>DM note (never shown to the player)</span><textarea name="dm_note" rows="2" maxlength="2000"></textarea></label>` : ''}
    </div>`;
}

function openConditionPicker() {
  if (!condRows) { openLegacyConditionPicker(); return; }
  const dm = amConditionDm();
  const active = new Set(condRows.filter((k) => k.kind === 'condition').map((k) => k.condition_key));
  const presets = CONDITIONS.filter((c) => SRD_KEYS.has(c.name.toLowerCase()) && !active.has(c.name.toLowerCase()));
  const m = openModal({
    title: dm ? 'Add a condition or tag' : 'Add a condition',
    wide: true,
    body: `
      <form id="cond-form" class="cond-form">
        <p class="small muted">Conditions and tags are reminders: they never change AC, speed or other values on the sheet.</p>
        <h3 class="cond-h">Condition</h3>
        <div class="condition-grid">
          ${presets.map((c) => `<button type="button" class="condition-option" data-key="${esc(c.name.toLowerCase())}" title="${esc(c.text)}">${icon(`condition.${c.name.toLowerCase()}`, { size: 18 })} ${esc(c.name)}</button>`).join('')}
        </div>
        <h3 class="cond-h">Exhaustion</h3>
        <div class="cond-row">
          <label class="field"><span>Level</span><select name="level">${[1, 2, 3, 4, 5, 6].map((n) => `<option value="${n}">${n}</option>`).join('')}</select></label>
          <button type="button" class="btn" data-add-exhaustion>Set Exhaustion</button>
        </div>
        <h3 class="cond-h">Tag</h3>
        <div class="cond-row">
          <label class="field"><span>Type</span><select name="tag_type">${TAG_TYPES.map(([v, l]) => `<option value="${v}"${v === 'other' ? ' selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
          <label class="field" data-damage-field hidden><span>Damage type</span><select name="damage_type_id"><option value="">— any —</option>${DAMAGE_TYPES.map((d) => `<option value="${esc(d)}">${esc(capFirst(d))}</option>`).join('')}</select></label>
          <label class="field" data-ci-field hidden><span>Condition</span><select name="ci_key"><option value="">—</option>${[...SRD_KEYS].map((k) => `<option value="${k}">${esc(capFirst(k))}</option>`).join('')}</select></label>
          <label class="field cond-grow"><span>Name</span><input name="name" maxlength="80" placeholder="e.g. Hexed, Raging, Hasted"></label>
          <button type="submit" class="btn btn-gold" data-add-tag>Add tag</button>
        </div>
        <h3 class="cond-h">Details</h3>
        ${conditionOptionsHTML(dm)}
      </form>`,
  });
  const form = $('#cond-form', m.el);
  const syncTag = () => {
    const t = form.elements.tag_type.value;
    $('[data-damage-field]', form).hidden = !DAMAGE_TAGS.has(t);
    $('[data-ci-field]', form).hidden = t !== 'condition_immunity';
  };
  form.elements.tag_type.addEventListener('change', syncTag);
  const common = () => {
    const f = form.elements;
    const spec = { note: f.note.value.trim() || null, duration_text: f.duration_text.value.trim() || null };
    if (dm) { spec.hidden = !!f.hidden?.checked; if (f.dm_note?.value.trim()) spec.dm_note = f.dm_note.value.trim(); }
    return spec;
  };
  const send = async (spec, label) => {
    const what = spec.hidden ? `${label} added (hidden from the player).` : `${label} added.`;
    if (await conditionChange('add', () => applyCharacterEffect(C().id, spec), what)) m.close();
  };
  m.body.addEventListener('click', (e) => {
    const b = e.target.closest('.condition-option');
    if (b) { send({ ...common(), kind: 'condition', condition_key: b.dataset.key }, b.textContent.trim()); return; }
    if (e.target.closest('[data-add-exhaustion]')) {
      const level = Number(form.elements.level.value);
      send({ ...common(), kind: 'exhaustion', level }, `Exhaustion ${level}`);
    }
  });
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const f = form.elements;
    const t = f.tag_type.value;
    const name = f.name.value.trim();
    if (t === 'other' && !name) { toast('Name the tag, e.g. Hexed.', 'bad'); f.name.focus(); return; }
    const spec = { ...common(), kind: 'tag', tag_type: t, name: name || null };
    if (DAMAGE_TAGS.has(t) && f.damage_type_id.value) spec.damage_type_id = f.damage_type_id.value;
    if (t === 'condition_immunity' && f.ci_key.value) spec.condition_key = f.ci_key.value;
    send(spec, name || 'Tag');
  });
}

function showCondition(el) {
  if (!el.dataset.cid) { showLegacyCondition(Number(el.dataset.i)); return; }
  const k = condRows?.find((x) => x.id === el.dataset.cid);
  if (!k) return;
  const dm = amConditionDm();
  const editable = dm || k.can_edit;
  const ruleText = k.rule || k.player_text || k.summary
    || (k.kind === 'tag' ? '' : CONDITION_BY_NAME[String(k.name).toLowerCase()]?.text) || '';
  const m = openModal({
    title: conditionLabel(k),
    body: `
      <div class="cond-detail">
        ${k.hidden ? `<p class="dm-secret-text">${icon('ui.dm-secret', { size: 16 })} Hidden from the player. Only the DM sees it.</p>` : ''}
        ${ruleText ? `<p>${esc(ruleText)}</p>` : ''}
        ${k.rule_source ? `<p class="small muted">${esc(k.rule_source)} · a reminder only, nothing on the sheet changes.</p>` : ''}
        ${k.kind === 'tag' && !ruleText ? '<p class="small muted">A tag from your table. A reminder only: nothing on the sheet changes.</p>' : ''}
        ${k.dm_applied && !dm ? `<p class="small" data-dm-applied>${k.from_combat ? 'Carried over from an encounter.' : 'Applied by your DM.'} Only the DM can change or remove it.</p>` : ''}
        ${!editable ? `${k.note ? `<p><strong>Note:</strong> ${esc(k.note)}</p>` : ''}${k.duration_text ? `<p><strong>Duration:</strong> ${esc(k.duration_text)}</p>` : ''}` : `
        <form id="cond-edit" class="cond-options">
          ${k.kind === 'exhaustion' ? `<label class="field"><span>Exhaustion level</span><select name="level">${[1, 2, 3, 4, 5, 6].map((n) => `<option value="${n}"${n === k.level ? ' selected' : ''}>${n}</option>`).join('')}</select></label>` : ''}
          <label class="field"><span>Note</span><input name="note" maxlength="500" value="${esc(k.note || '')}"></label>
          <label class="field"><span>Duration</span><input name="duration_text" maxlength="80" value="${esc(k.duration_text || '')}"></label>
          ${dm ? `<label class="cond-hidden-toggle"><input type="checkbox" name="hidden"${k.hidden ? ' checked' : ''}> ${icon('ui.dm-secret', { size: 16 })}<span>Hidden from the player (DM only)</span></label>
          <label class="field"><span>DM note (never shown to the player)</span><textarea name="dm_note" rows="2" maxlength="2000">${esc(k.dm_note || '')}</textarea></label>` : ''}
        </form>`}
      </div>`,
    footer: `
      <button type="button" class="btn" data-close>${editable ? 'Cancel' : 'Close'}</button>
      ${k.can_remove ? '<button type="button" class="btn btn-bad" data-remove>Remove</button>' : ''}
      ${editable ? '<button type="button" class="btn btn-gold" data-save>Save</button>' : ''}`,
  });
  $('[data-remove]', m.el)?.addEventListener('click', async () => {
    if (await conditionChange(`rm:${k.id}`, () => removeCharacterCondition(k.id), `${conditionLabel(k)} removed.`)) m.close();
  });
  $('[data-save]', m.el)?.addEventListener('click', async () => {
    const f = $('#cond-edit', m.el).elements;
    const patch = {};
    if (f.level && Number(f.level.value) !== k.level) patch.level = Number(f.level.value);
    if (f.note.value.trim() !== (k.note || '')) patch.note = f.note.value.trim();
    if (f.duration_text.value.trim() !== (k.duration_text || '')) patch.duration_text = f.duration_text.value.trim();
    if (dm && f.hidden && f.hidden.checked !== !!k.hidden) patch.hidden = f.hidden.checked;
    if (dm && f.dm_note && f.dm_note.value.trim() !== (k.dm_note || '')) patch.dm_note = f.dm_note.value.trim();
    if (!Object.keys(patch).length) { m.close(); return; }
    if (await conditionChange(`up:${k.id}`, () => updateCharacterEffect(k.id, patch), 'Saved.')) m.close();
  });
}

/** End Concentration (Wild Shape panel): the player's own Concentrating rows, or the old list on an older server. */
function endConcentration() {
  if (!condRows) { setConditions(activeConditions().filter((x) => !/^concentrat/i.test(conditionText(x)))); return; }
  condRows.filter((k) => /^concentrat/i.test(k.name || '') && k.can_remove)
    .forEach((k) => conditionChange(`rm:${k.id}`, () => removeCharacterCondition(k.id)));
}

// ---- the old path (a server without 20261112000200): characters.conditions as a list of names --------------------------
function openLegacyConditionPicker() {
  const active = new Set(activeConditions().map((n) => n.toLowerCase()));
  const presets = CONDITIONS.filter((c) => !active.has(c.name.toLowerCase()));
  const m = openModal({
    title: 'Add a condition',
    body: `
      <div class="condition-grid">
        ${presets.map((c) => `<button type="button" class="condition-option" data-name="${esc(c.name)}" title="${esc(c.text)}">${esc(c.name)}</button>`).join('')}
      </div>
      <form class="add-tracker mt" id="custom-condition">
        <input type="text" name="custom" placeholder="Custom, e.g. Hexed, Raging, Hasted" aria-label="Custom condition" maxlength="40">
        <button type="submit" class="btn btn-gold">Add</button>
      </form>`,
  });
  const add = (name) => {
    const n = String(name || '').trim();
    if (!n) return;
    if (!activeConditions().some((x) => x.toLowerCase() === n.toLowerCase())) setConditions([...activeConditions(), n]);
    m.close();
  };
  m.body.addEventListener('click', (e) => {
    const b = e.target.closest('.condition-option');
    if (b) add(b.dataset.name);
  });
  $('#custom-condition', m.el).addEventListener('submit', (e) => {
    e.preventDefault();
    add(e.target.elements.custom.value);
  });
}

function showLegacyCondition(i) {
  const name = activeConditions()[i];
  if (name == null) return;
  const info = CONDITION_BY_NAME[name.toLowerCase()];
  const m = openModal({
    title: name,
    body: `<p>${info ? esc(info.text) : 'A custom condition. Your DM will tell you what it does.'}</p>`,
    footer: `
      <button type="button" class="btn" data-close>Keep</button>
      <button type="button" class="btn btn-bad" data-remove>Remove condition</button>`,
  });
  $('[data-remove]', m.el).addEventListener('click', () => {
    setConditions(activeConditions().filter((_, j) => j !== i));
    m.close();
  });
}

function openEditor(table, id) {
  const key = `${table}:${id}`;
  editing.add(key);
  const card = $(`[data-entry="${key}"]`, root);
  // Editing a spell from the Combat tab jumps to its card on the Spells tab.
  const panel = card?.closest('.panel');
  if (panel?.hidden) showTab(panel.dataset.panel, false);
  card?.classList.add('editing');
  card?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  const input = $(`[data-t="${table}"][data-id="${id}"][data-f="name"]`, root);
  input?.focus({ preventScroll: true });
  input?.select();
}

async function addAttack() {
  const v = $('#weapon-preset', root).value;
  let fields;
  if (v === 'custom') {
    fields = { name: 'New attack' };
  } else if (v === 'unarmed') {
    fields = { name: 'Unarmed strike', ability: 'str', proficient: true, damage_dice: '1', damage_type: 'bludgeoning', range: '5 ft' };
  } else {
    fields = weaponToAttack(WEAPONS[Number(v)], C().equipment_proficiencies || {});
  }
  const row = await insertRow('attacks', { character_id: C().id, sort_order: B.attacks.length, ...fields });
  if (!B.attacks.some((a) => a.id === row.id)) B.attacks.push(row);
  rerenderList('attacks');
  if (v === 'custom') openEditor('attacks', row.id);
  else {
    $(`[data-entry="attacks:${row.id}"]`, root)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    toast(`${row.name} added.`, 'good');
  }
}

async function addSpell(level) {
  const row = await insertRow('spells', {
    character_id: C().id, level, name: level === 0 ? 'New cantrip' : 'New spell', sort_order: B.spells.length,
  });
  if (!B.spells.some((s) => s.id === row.id)) B.spells.push(row);
  rerenderList('spells');
  openEditor('spells', row.id);
}

async function removeRow(table, id, label) {
  const row = findRow(table, id);
  if (!row) return;
  const ok = await confirmDialog(`Delete “${row.name || label}”?`, { okLabel: 'Delete', danger: true });
  if (!ok) return;
  await deleteRow(table, id);
  const list = rowsOf(table);
  const i = list.findIndex((r) => r.id === id);
  if (i >= 0) list.splice(i, 1);
  rerenderList(table);
}

const actions = {
  tab: (el) => showTab(el.dataset.tab),
  'toggle-compact': (el) => {
    const bar = $('.combat-bar', root);
    const on = bar.classList.toggle('compact');
    setCompact(on);
    el.setAttribute('aria-expanded', String(!on));
    el.setAttribute('aria-label', on ? 'Expand vitals' : 'Collapse vitals');
    $('.ct-text', el).textContent = on ? 'More' : 'Less';
  },
  'open-requests': () => governance?.openRequests?.(),
  // the DM undoes a permanent effect of a used item (character_permanent_effects keeps the row with reverted_at)
  'revert-permanent': async (el) => {
    if (!(await confirmDialog('Revert this permanent effect? The bonus is removed from the character; the record of the use stays.', { okLabel: 'Revert', danger: true }))) return;
    try {
      await revertPermanentEffect(el.dataset.effect);
      toast('Permanent effect reverted.', 'good');
      scheduleDerived();
      scheduleSpellbook();
    } catch (err) { toast(err.message, 'bad'); }
  },
  'build-goto': (el) => {
    showTab('features', false);
    const target = $(el.dataset.target, root);
    if (target?.tagName === 'DETAILS') target.open = true;
    target?.scrollIntoView({ block: 'start', behavior: reducedMotion() ? 'auto' : 'smooth' });
    target?.querySelector('[data-cf-goto], button:not([disabled]), summary, select')?.focus({ preventScroll: true });
  },
  'hp-damage': () => applyHp(-1),
  'hp-heal': () => applyHp(1),
  'tracker-pip': (el) => {
    const t = findRow('feature_trackers', el.dataset.id);
    const i = Number(el.dataset.i);
    setRow('feature_trackers', t, { current: i < t.current ? i : i + 1 });
  },
  'tracker-step': (el) => {
    const t = findRow('feature_trackers', el.dataset.id);
    setRow('feature_trackers', t, { current: clamp(t.current + Number(el.dataset.d), 0, t.max) });
  },
  'slot-pip': (el) => {
    const s = findRow('spell_slots', el.dataset.id);
    const i = Number(el.dataset.i);
    setRow('spell_slots', s, { used: i < s.used ? i : i + 1 });
  },
  'slot-total': (el) => {
    const s = findRow('spell_slots', el.dataset.id);
    const total = clamp(s.total + Number(el.dataset.d), 0, 9);
    setRow('spell_slots', s, { total, used: Math.min(s.used, total) });
    rerender('#spells-list', spellsListHTML());
  },
  'reset-slots': () => { for (const s of B.slots) if (s.used) setRow('spell_slots', s, { used: 0 }); },
  'toggle-save': (el) => {
    const k = el.dataset.k;
    setRow('characters', C(), { save_proficiencies: { ...C().save_proficiencies, [k]: !saveManual(k) } });
  },
  'cycle-skill': (el) => {
    const k = el.dataset.k;
    setRow('characters', C(), { skill_proficiencies: { ...C().skill_proficiencies, [k]: skillValue((skillProf(k) + 1) % 3) } });
  },
  'goto-feature': (el) => {
    showTab('features', false);
    const card = $(`[data-feature="${el.dataset.id}"]`, root);
    card?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    card?.classList.add('flash');
    setTimeout(() => card?.classList.remove('flash'), 1400);
    $(`[data-t="features"][data-id="${el.dataset.id}"][data-f="description"]`, root)?.focus({ preventScroll: true });
  },
  'goto-choices': () => {
    showTab('features', false);
    $('.build-next-card', root)?.scrollIntoView({ block: 'start', behavior: reducedMotion() ? 'auto' : 'smooth' });
    $('#build-next button', root)?.focus({ preventScroll: true });
  },
  'resolve-choice': (el) => {
    const choice = pendingChoices().find((p) => p.id === el.dataset.id);
    setRow('characters', C(), { pending_choices: pendingChoices().filter((p) => p.id !== el.dataset.id) });
    if (choice) toast(`“${choice.type}” marked as done. Remember to add it to the sheet.`, 'good', 4000);
  },
  'add-condition': () => openConditionPicker(),
  'show-condition': (el) => showCondition(el),
  'remove-portrait': async () => {
    const url = C().portrait_url;
    if (!url) return;
    setRow('characters', C(), { portrait_url: '' });
    await removePortraitFile(url);
  },
  'export-json': async () => {
    const slug = (C().name || 'character').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    // always the full class read: the export takes manual resource counters from the class summary, which the small
    // resource refresh (loadResources) does not re-read
    await loadClasses();
    if (!spellbook || spellbookStale) await loadSpellbook({ force: true });   // loaded only with the Spells section
    const classFeatureState = classSummary?.classes?.length ? await exportClassFeatures(C().id).catch(() => null) : null;
    const feats = await exportFeats(C().id).catch(() => null);
    downloadJson(exportCharacter(B, { lineage, spellbook, classSummary, slotState, classFeatureState, companions, background, wildShape: transformState, feats }), `${slug || 'character'}.json`);
  },
  'toggle-inspiration': () => setRow('characters', C(), { inspiration: !C().inspiration }),
  death: (el) => {
    const field = el.dataset.kind === 'success' ? 'death_successes' : 'death_failures';
    const i = Number(el.dataset.i);
    setRow('characters', C(), { [field]: i < C()[field] ? i : i + 1 });
  },
  'short-rest': () => rest('short'),
  'long-rest': () => rest('long'),
  'add-feature': (el) => addFeature(el.dataset.cat),
  'delete-feature': (el) => removeRow('features', el.dataset.id, 'feature'),
  'add-tracker': addTracker,
  'delete-tracker': (el) => removeRow('feature_trackers', el.dataset.id, 'resource'),
  'add-attack': addAttack,
  'add-spell': (el) => addSpell(Number(el.dataset.level)),
  'toggle-edit': (el) => {
    const key = el.dataset.key;
    const card = $(`[data-entry="${key}"]`, root);
    // Buttons outside the card itself (Combat tab quick-reference) always open the editor.
    if (editing.has(key) && el.closest('[data-entry]')) {
      editing.delete(key);
      card?.classList.remove('editing');
    } else {
      const [table, id] = key.split(':');
      openEditor(table, id);
    }
  },
  'delete-entry': (el) => {
    const [table, id] = el.dataset.key.split(':');
    editing.delete(el.dataset.key);
    return removeRow(table, id, table === 'spells' ? 'spell' : 'attack');
  },
  'toggle-prepared': (el) => {
    const s = findRow('spells', el.dataset.id);
    setRow('spells', s, { prepared: !s.prepared });
  },
  // a granted chip explains its source (never deletes the grant); a manual or inactive chip toggles the manual mark
  'toggle-equip': async (el) => {
    const k = el.dataset.k;
    const group = PROF_GROUP_BY_FLAG[k];
    const e = profEntry('groups', group);
    const name = EQUIPMENT_PROFICIENCIES.find((p) => p.key === k)?.label || group;
    if (e && derivedSources(e).length) {
      openProficiencySource(e, name, { onGoto: gotoSource, onManual: (enabled) => setManualProficiency({ group, enabled, flag: k }) });
      return;
    }
    const manual = k in profPending ? profPending[k] : (e ? e.manual : !!C().equipment_proficiencies?.[k]);
    await setManualProficiency({ group, enabled: !manual, flag: k });
  },
  'prof-remove': (el) => setManualProficiency({ item: el.dataset.item, enabled: false }),
  'bg-choose': () => openBackgroundPicker({ characterId: C().id, current: background, onSaved: backgroundChanged }),
  'bg-equipment': () => background?.selected && openBackgroundEquipment({ characterId: C().id, bg: background,
    onApplied: () => { inventory?.refresh?.(); loadBackground(); } }),
  'bg-remove': () => background?.selected && removeBackground({ characterId: C().id, bg: background, onSaved: backgroundChanged }),
  'bg-replace': () => background?.selected && openReplaceDuplicate({ characterId: C().id, bg: background, onSaved: backgroundChanged }),
  'bg-roll': (el) => background?.selected && rollCharacteristic(el.closest('form'), background, el.dataset.key, el.dataset.die),
  'ac-breakdown': () => {
    if (!derived) { toast('Still calculating…'); return; }
    openAcBreakdown(derived, {
      onOverride: (v) => { derivedDirty = true; setRow('characters', C(), { ac_override: v }); },
      onGotoItem: gotoInventoryItem,
    });
  },
  'manage-profs': () => openProficiencyManager(C().id, () => derived, loadDerived),
  'lineage-choose': (el) => {
    if (!lineage) { toast('Still loading…'); return; }
    openLineagePicker({ characterId: C().id, current: lineage, level: C().level, onSaved: lineageChanged, open: el?.dataset.lineageOpen || null,
      campaignId: C().campaign_id || null });
  },
  'lineage-remove': () => removeLineage(C().id, lineageChanged),
  'spell-source-add': () => openSourceEditor({ characterId: C().id, onSaved: loadSpellbook }),
  'spell-source-edit': (el) => openSourceEditor({ characterId: C().id, source: spellbook?.sources.find((x) => x.id === el.dataset.source),
    classInfo: classSummary?.classes?.find((k) => k.spellcasting?.source_id === el.dataset.source), onSaved: async () => { await loadSpellbook(); loadClasses(); } }),
  'spell-add': () => {
    if (!spellbook) { toast('Still loading…'); return; }
    openAddSpell({
      characterId: C().id, book: spellbook, classes: classSummary?.classes || [], onSaved: async () => { await loadSpellbook(); loadClasses(); },
      onNewSource: (done) => openSourceEditor({ characterId: C().id, onSaved: async () => { await loadSpellbook(); await done(spellbook); } }),
    });
  },
  'spell-detail': (el) => {
    const sp = spellbook?.spells.find((x) => x.id === el.dataset.spell);
    if (sp) openSpellDetail(sp, { editable: !ctx?.readOnly, onChanged: async () => { await loadSpellbook(); loadClasses(); } });
  },
  // a free cast of a spell granted by an item (its own counter, recharged by the rests)
  'item-spell-use': async (el) => {
    await expendResource(C().id, el.dataset.key, 1);
    toast('Free cast used.', 'good');
    await loadSpellbook();
    scheduleResources();
  },
  'spell-prepare': async (el) => {
    try { await setSpellPrepared(el.dataset.cs, el.checked); await loadSpellbook(); loadClasses(); } catch (err) { el.checked = !el.checked; throw err; }
  },

  'level-up': async () => {
    await saver.flush();
    openLevelUp(B, { classes: classSummary?.classes || [], onApplied: () => ctx.reload() });
  },
  'class-add': () => openClassEditor({ characterId: C().id, summary: classSummary, onSaved: classesChanged }),
  'class-edit': (el) => openClassEditor({ characterId: C().id, summary: classSummary, row: el.dataset.row, onSaved: classesChanged }),
  'class-remove': (el) => removeClass({ summary: classSummary, row: el.dataset.row, onSaved: classesChanged }),
  'tf-pick': () => transformState && openFormPicker({ characterId: C().id, tf: transformState, editable: !ctx?.readOnly,
    onTransform: (id, st) => openTransformReview({ characterId: C().id, tf: st || transformState, creatureId: id, onDone: tfApplied }),
    onChanged: (st) => { if (st) tfApplied(st, { quiet: true }); else scheduleTransform(); } }),
  'tf-quick': (el) => transformState && openTransformReview({ characterId: C().id, tf: transformState, creatureId: el.dataset.creature, onDone: tfApplied }),
  'tf-damage': (el) => formHp(-1, Number($('[data-tf-amount]', el.closest('[data-transform]'))?.value), 'tf-damage'),
  'tf-heal': (el) => formHp(1, Number($('[data-tf-amount]', el.closest('[data-transform]'))?.value), 'tf-heal'),
  'tf-adjust': () => transformState?.active && openAdjust({ characterId: C().id, sheet: transformState.active.sheet, onDone: tfApplied }),
  'tf-end': async () => {
    if (!transformState?.active || !(await confirmRevert(transformState))) return;
    await tfMutation('revert', (id) => endTransformation(id), () => 'You return to your normal form.');
  },
  'tf-combat-heal': () => transformState?.active && openCombatHeal({ characterId: C().id, sheet: transformState.active.sheet, slots: slotState,
    onDone: async (r) => { await tfApplied(r, { quiet: true }); slotsChangedElsewhere(); } }),
  'tf-ability': (el) => tfMutation(`ability:${el.dataset.ability}`, (id) => useFormAbility(id, el.dataset.ability, el.dataset.op),
    (r) => `${el.dataset.ability}: ${r.result.available ? 'available' : 'used'}${r.result.roll ? ` (rolled ${r.result.roll}, needs ${r.result.min})` : ''}.`),
  'tf-equip': (el) => tfMutation(`equip:${el.dataset.item}`, (id) => setFormEquipment(id, el.dataset.item, el.dataset.mode),
    () => (el.dataset.mode === 'wear' ? 'The item is worn by the form (its effects apply).' : 'The item merges into the form (no effect).')),
  'tf-end-concentration': () => endConcentration(),
  'tf-open-combat': () => { showTab('combat', false); $('#combat-transform', root)?.scrollIntoView({ block: 'start' }); },
  'inf-add': () => { if (infusionState) openInfuse({ characterId: C().id, state: infusionState, onDone: async () => { await classesChanged(); } }); },
  'inf-remove': async (el) => { if (await endInfusion(C().id, infusionState, el.dataset.id)) await classesChanged(); },
  'inf-refresh': async () => { await refreshInfusions(C().id); await classesChanged(); },
  'comp-add': () => openAddCompanion({ characterId: C().id, onDone: loadClasses }),
  'comp-hp': async (el) => { await changeCompanionHp(el, companions); await loadClasses(); },
  'comp-remove': async (el) => { if (await removeCompanionConfirm(el, companions)) await loadClasses(); },
  'class-start-eq-retry': () => loadClasses(),
  'coin-calc': async () => {
    await saver.flush();   // the calculator starts from the stored coins (a coin typed into a field a moment ago is saved first)
    const id = C().id;
    openCoinCalculator({ characterId: id, getWallet: () => coinWallet(C()), onApplied: (after) => { if (B && C().id === id) coinsApplied(after); } });
  },
  'class-start-eq': async (el) => {
    const equipment = await getStartingEquipment(el.dataset.version);
    openStartingEquipment({ characterId: C().id, equipment, className: startEqState?.class_name, onDone: async () => { await loadClasses(); inventory?.refresh?.(); } });
  },
  'class-primary': async (el) => {
    const k = classSummary.classes.find((x) => x.id === el.dataset.row);
    await setCharacterClass(C().id, { version: k.class_version_id, level: k.level, subclass: k.subclass_version_id, primary: true, row: k.id });
    await loadClasses();
  },
  'slot-use': (el) => slotMutation(`standard:${el.dataset.level}`, 'used', (id) => expendStandardSlot(id, Number(el.dataset.level))),
  'slot-restore': (el) => slotMutation(`standard:${el.dataset.level}`, 'restored', (id) => restoreStandardSlot(id, Number(el.dataset.level))),
  'pact-use': () => slotMutation('pact', 'used', (id) => expendPactSlot(id)),
  'pact-restore': () => slotMutation('pact', 'restored', (id) => restorePactSlot(id)),
  'temp-use': (el) => slotMutation(`temporary:${el.dataset.id}`, 'used', (id) => useTemporarySlot(id, el.dataset.id)),
  'temp-restore': (el) => slotMutation(`temporary:${el.dataset.id}`, 'restored', (id) => restoreTemporarySlot(id, el.dataset.id)),
  'slot-recover': (el) => {
    const r = classResources?.resources.find((x) => x.key === el.dataset.key);
    if (r && slotState) openRecoverSlots({ characterId: C().id, resource: r, slots: slotState, onDone: slotsChangedElsewhere });
  },
  'rider-slot': (el) => {
    const r = (derived?.attack_riders || []).find((x) => x.name === el.dataset.rider);
    if (r && slotState) openSlotRider({ characterId: C().id, rider: r, slots: slotState, onDone: slotsChangedElsewhere });
  },
  'slot-convert': (el) => {
    const r = classResources?.resources.find((x) => x.key === el.dataset.key);
    if (r && slotState) openFlexibleCasting({ characterId: C().id, resource: r, slots: slotState, onDone: slotsChangedElsewhere });
  },
  'delete-character': async () => {
    const ok = await confirmDialog(`Permanently delete ${C().name}? This cannot be undone.`, {
      title: 'Delete character', okLabel: 'Delete forever', danger: true,
    });
    if (!ok) return;
    await deleteCharacter(C().id);
    toast('Character deleted.');
    ctx.onDeleted();
  },
};

// -----------------------------------------------------------------------------
// Events
// -----------------------------------------------------------------------------

function onInput(e) {
  if (!B) return;                                            // the sheet was closed or is being replaced
  const el = e.target;
  if (el.dataset.sf === 'q' && readFilter(el, spellFilters)) { renderSpellbook(); return; }
  if (el.tagName === 'TEXTAREA' && el.classList.contains('autosize')) autoResize(el);
  if (!el.dataset.f || el.type === 'checkbox' || el.tagName === 'SELECT') return;
  commitField(el);
}

async function changePortrait(file) {
  const previous = C().portrait_url;
  toast('Uploading portrait…');
  try {
    const url = await uploadPortrait(C().id, file);
    setRow('characters', C(), { portrait_url: url });
    toast('Portrait updated.', 'good');
    if (previous && previous !== url) removePortraitFile(previous);
  } catch (err) {
    console.error(err);
    toast(err.message || 'Upload failed', 'bad');
  }
}

function onChange(e) {
  if (!B) return;                                            // a refused save reloads the view; the blurred input still fires 'change'
  const el = e.target;
  if (el.dataset.sf && readFilter(el, spellFilters)) { renderSpellbook(); return; }
  if (el.dataset.classLevel) {
    changeClassLevel({ characterId: C().id, summary: classSummary, row: el.dataset.classLevel, level: Number(el.value), onSaved: classesChanged })
      .then((done) => { if (done === false) { $('#class-card-body', root).__html = null; renderClasses(); } })
      .catch((err) => { toast(err.message, 'bad'); $('#class-card-body', root).__html = null; loadClasses(); });
    return;
  }
  if (el.id === 'tracker-preset') {
    $('#tracker-custom', root).hidden = el.value !== 'custom';
    if (el.value === 'custom') $('#tracker-custom', root).focus();
    return;
  }
  if (el.id === 'portrait-file') {
    const file = el.files?.[0];
    el.value = '';
    if (file) changePortrait(file);
    return;
  }
  if (!el.dataset.f) return;
  if (el.type === 'checkbox' || el.tagName === 'SELECT') {
    commitField(el);
    if (el.dataset.t === 'features' && el.dataset.f === 'category') rerenderList('features');
    if (el.dataset.t === 'spells' && el.dataset.f === 'level') rerenderList('spells');
    return;
  }
  // Normalise numeric fields on blur (e.g. emptied or clamped values).
  const row = findRow(el.dataset.t, el.dataset.id);
  if (row && (el.dataset.type === 'int' || el.dataset.type === 'num')) el.value = row[el.dataset.f];
}

const SLOT_ACTIONS = new Set(['slot-use', 'slot-restore', 'pact-use', 'pact-restore', 'temp-use', 'temp-restore']);
async function onClick(e) {
  const el = e.target.closest('[data-action]');
  if (!el || !root.contains(el)) return;
  const fn = actions[el.dataset.action];
  if (!fn) return;
  // the 2nd / 3rd click of a double / triple click on a slot button is not a new use (the server may already have answered
  // the first one; separate clicks have detail 1). Keyboard activation has detail 0.
  if (e.detail > 1 && SLOT_ACTIONS.has(el.dataset.action)) return;
  try {
    await fn(el);
  } catch (err) {
    console.error(err);
    toast(err.message || 'Something went wrong', 'bad');
  }
}

async function adjustSlots(form) {
  const [pool, level] = form.elements.pool.value.split(':');
  try {
    slotState = await setSlotState(C().id, pool, pool === 'pact' ? null : Number(level), Number(form.elements.expended.value),
      form.elements.reason.value.trim());
    slotEpoch += 1;
    toast('Slots corrected.', 'good');
    renderClasses();
  } catch (err) { toast(err.message, 'bad'); }
}

function onSubmit(e) {
  if (e.target.matches('[data-slot-adjust]')) { e.preventDefault(); adjustSlots(e.target); return; }
  if (e.target.matches('[data-bg-chars]')) {
    e.preventDefault();
    if (background?.selected) saveCharacteristics({ characterId: C().id, bg: background, form: e.target, onSaved: backgroundChanged }).catch((err) => toast(err.message, 'bad'));
    return;
  }
  if (e.target.id !== 'add-choice-form') return;
  e.preventDefault();
  const f = e.target.elements;
  const type = f.type.value.trim();
  if (!type) return;
  const base = type.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'choice';
  let id = base;
  for (let n = 2; pendingChoices().some((p) => p.id === id); n++) id = `${base}-${n}`;
  const choice = {
    id, type, description: f.description.value.trim(),
    options: f.options.value.split(',').map((s) => s.trim()).filter(Boolean),
  };
  setRow('characters', C(), { pending_choices: [...pendingChoices(), choice] });
  e.target.reset();
}

function onKeyDown(e) {
  if (e.target.classList?.contains('tab')) { onTabKey(e); return; }
  if (e.target.id === 'hp-amount' && e.key === 'Enter') {
    e.preventDefault();
    applyHp(e.shiftKey ? 1 : -1);
  }
  if (e.target.id === 'tracker-custom' && e.key === 'Enter') {
    e.preventDefault();
    addTracker().catch((err) => toast(err.message, 'bad'));
  }
}

// -----------------------------------------------------------------------------
// Realtime: changes from other devices / the DM
// -----------------------------------------------------------------------------

/** The coins after a calculator transaction (the server's values): shown at once; other sessions get them via Realtime. */
function coinsApplied(after) {
  serverChar = { ...serverChar, ...after };
  Object.assign(C(), after);
  syncInputs('characters', C().id);
  afterChange('characters');
}

function applyRemote(table, row, incoming) {
  const guarded = saver.protectedFields(table, row.id);
  let changed = false;
  for (const [k, v] of Object.entries(incoming)) {
    if (k in guarded) continue;
    if (JSON.stringify(row[k]) !== JSON.stringify(v)) {
      row[k] = v;
      changed = true;
    }
  }
  return changed;
}

/** Did a stored characters row change a column the derived stats read? Compared with the last stored row, not with local edits. */
function derivedColumnChanged(nw) {
  if (!serverChar || !nw) return true;
  const form = !!transformState?.active;
  return Object.keys(nw).some((k) => JSON.stringify(nw[k]) !== JSON.stringify(serverChar[k])
    && (!NON_DERIVED_FIELDS.has(k) && (!FORM_FIELDS.has(k) || form)));
}

function onRemote(table, event, nw, old) {
  if (!B || ctx?.readOnly) return;   // the cached copy shown while the same sheet reloads: the fresh read covers the change
  if (table === 'character_proficiencies') { scheduleDerived(); return; }
  // a feat added, removed or re-chosen in another session (or by the DM / an approved request): feats, derived values,
  // spells and class resources, exactly as after a local feat change
  if (table === 'character_feats' || table === 'character_feat_choices') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) scheduleFeatsChanged();
    return;
  }
  if (table === 'character_spells' || table === 'character_spellcasting_sources') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) scheduleSpellbook();
    return;
  }
  // permanent effects of used items (20261114000500; no row data reaches the client, only the revision): bonuses and spells
  if (table === 'character_permanent_effects') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) { scheduleDerived(); scheduleSpellbook(); }
    return;
  }
  if (['character_classes', 'character_spell_slot_state', 'character_temporary_spell_slots', 'character_resources',
    'character_feature_choices', 'character_optional_features'].includes(table)) {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) {
      if (table === 'character_spell_slot_state' || table === 'character_temporary_spell_slots') scheduleSlots();
      else if (table === 'character_resources') scheduleResources();   // counters only: not the class page (33-118 KB)
      else scheduleClasses();
      if (table !== 'character_spell_slot_state' && table !== 'character_temporary_spell_slots' && table !== 'character_resources') {
        scheduleDerived(); scheduleLineage(); scheduleSpellbook();
      }
    }
    return;
  }
  if (table === 'character_transformations') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) scheduleTransform();
    return;
  }
  if (table === 'character_backgrounds') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) { scheduleBackground(); scheduleDerived(); }
    return;
  }
  if (table === 'character_lineages' || table === 'character_lineage_choices') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) { scheduleLineage(); scheduleDerived(); }
    return;
  }
  if (table === 'characters') {
    // ability scores, level, speed, override or the proficiency mirror may have changed; HP, coins and other columns the
    // derived stats never read do not cost a derived re-read (every HP tap did, in every open session: incident 2026-10-23)
    if (derivedColumnChanged(nw)) scheduleDerived();
    // the server's mirror of the visible conditions changed (the only conditions signal on the legacy ?fluent=0 path)
    if (nw && 'conditions' in nw && JSON.stringify(nw.conditions) !== JSON.stringify(serverChar?.conditions)) scheduleConditions();
    serverChar = { ...nw };
    if (applyRemote('characters', C(), nw)) {
      syncInputs('characters', C().id);
      afterChange('characters');
    }
    return;
  }

  // Inventory and equipment: the inventory UI re-reads the authoritative state (no row patching, no duplicates).
  if (table === 'inventory_items' || table === 'character_equipment') {
    const rec = event === 'DELETE' ? old : nw;
    if (!rec?.character_id || rec.character_id === C().id) inventory?.scheduleRefresh();   // its onRows re-reads derived stats
    return;
  }

  const list = B[LIST_KEY[table]];
  if (!list) return;   // a source this build does not know (a newer server): nothing to patch
  if (event === 'INSERT') {
    if (nw.character_id !== C().id || list.some((r) => r.id === nw.id)) return;
    list.push(nw);
    if (table === 'notes') return;
    rerenderList(table);
  } else if (event === 'UPDATE') {
    const row = list.find((r) => r.id === nw.id);
    if (!row) return;
    const prevCategory = row.category;
    const prevLevel = row.level;
    if (!applyRemote(table, row, nw)) return;
    syncInputs(table, row.id);
    if (table === 'features' && prevCategory !== row.category) rerenderList('features');
    else if (table === 'spells' && prevLevel !== row.level) rerenderList('spells');
    else if (table === 'spell_slots') rerenderList('spell_slots');
    else if (table === 'feature_trackers') { renderStrip(); afterChange(table); }
    else afterChange(table);
  } else if (event === 'DELETE') {
    const i = list.findIndex((r) => r.id === old?.id);
    if (i < 0) return;
    list.splice(i, 1);
    rerenderList(table);
  }
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

/**
 * Mount a character sheet into `container`.
 * readOnly: render a cached snapshot while fresh data loads.
 */
export function mountSheet(container, bundle, options = {}) {
  unmountSheet({ keepRealtimeFor: bundle.character.id });
  B = bundle;
  spellbookStale = false;
  // Cached bundles from older versions may lack newer lists.
  B.attacks ||= [];
  B.spells ||= [];
  B.character.equipment_proficiencies ||= {};
  B.character.conditions ||= [];
  B.character.pending_choices ||= [];
  B.character.portrait_url ??= '';
  derived = null;
  condRows = null;
  profState = null;
  profPending = {};
  lineage = null;
  background = null;
  spellbook = null;
  classSummary = null;
  slotState = null;
  slotBusy = new Set();
  tfBusy = new Set();
  classFeatures = null;
  classResources = null;
  ctx = options;
  root = document.createElement('div');
  root.className = 'sheet-root';
  if (options.readOnly) root.classList.add('is-stale');
  container.replaceChildren(root);
  render();

  if (options.readOnly) return;

  beginSheetReads(C().id);   // every character read of this sheet is aborted when it closes (js/read-control.js)
  sheetFluent = fluentEnabled() && !!options.view;
  if (sheetFluent) {
    beginReadScope(C().id);
    seedReads(C().id, options.view);
    // progressive open, step 2: everything else the sheet reads now, plus the active tab's domain, in ONE request
    const tab = activeTabKey();
    const domain = prefetchDomain(C().id, [...SHEET_DOMAIN_READS, ...(tab === 'spells' ? ['get_character_spellbook'] : tab === 'inventory' ? ['inventory_bundle'] : [])]);
    // lowest priority, after the open is complete: the Inventory tab's session reference tables (static catalog lookups)
    if (tab !== 'inventory') domain.then(() => whenIdle(() => getLookups().catch(() => {})));
  }
  root.dataset.readPath = sheetFluent ? 'fluent' : 'legacy';
  serverChar = { ...B.character };
  root.addEventListener('input', onInput);
  root.addEventListener('change', onChange);
  root.addEventListener('click', onClick);
  root.addEventListener('keydown', onKeyDown);
  root.addEventListener('submit', onSubmit);
  attachFeatureHandlers(root, { getCharacterId: () => C().id, onChanged: classesChanged, onResources: loadResources });
  attachFeatHandlers(root, { getCharacterId: () => C().id, getState: () => featState, onChanged: featsChanged });
  rememberSpellSections(root);
  // one channel per character: a reload of the same sheet (reconnect, refused change) keeps it instead of leave + join
  if (liveCharacterId !== C().id || liveFluent !== sheetFluent) {
    unsubscribe?.();
    // fluent: once Realtime delivers changes, one revision check catches a change committed between the open and that moment.
    // The open, Realtime going live and a reconnect share ONE debounce (catchUpSoon): at most one revision read per burst.
    liveReady = false;
    unsubscribe = sheetFluent
      ? subscribeCharacterFluent(C().id, onRemote, onRevision, onReconnect, () => { liveReady = true; catchUpSoon(); })
      : subscribeCharacter(C().id, onRemote, resyncSoon);
    liveCharacterId = C().id;
    liveFluent = sheetFluent;
  }
  // fluent: the Inventory panel (7 reads + catalog on the legacy path) loads in one request on its first open
  inventoryDeferred = sheetFluent && activeTabKey() !== 'inventory';
  if (!inventoryDeferred) mountInventoryPanel();
  // a change the campaign refuses is never saved: reload the sheet so it shows the stored values again
  governance = mountGovernance($('#gov-bar', root), { characterId: C().id, reload: () => ctx.reload?.(), onRefused: () => ctx.reload?.(),
    onState: (st) => {
      const before = featRemovalPolicy();
      const craftBefore = govState?.gov?.decisions?.['inventory.craft'];
      govState = st;
      if (craftBefore !== st?.gov?.decisions?.['inventory.craft']) inventory?.craftingChanged?.();
      renderSheetChips();
      if (featState && featRemovalPolicy() !== before) rerender('#feats-card', featsCardHTML(featState, { editable: !ctx?.readOnly, removal: featRemovalPolicy() }));
    } });
  watchVitals();
  trackWeaponDetails(root);
  unsubSaver = saver.onStatus((st) => { if (st === 'saved' && derivedDirty) { derivedDirty = false; scheduleDerived(); } });
  // the viewer's measurement units (js/units.js): the numbers printed apart from their unit follow at once (free text is
  // converted by the display layer)
  bindUnitsSwitch(root);
  unsubUnits?.();
  unsubUnits = onUnitsChange(() => { if (root) refreshDerived(); });
  partySyncSoon(C().id, true);
  loadDerived();
  loadConditions();
  loadLineage();
  loadBackground();
  loadSpellbook();
  loadClasses();
  loadFeats();
  if (playTiming) rerenderPlayFeatures();
  else loadPlayTiming().then((m) => { playTiming = m; rerenderPlayFeatures(); });   // once per page session (catalog table)
  if (!sheetFluent && !fluentEnabled()) cacheSet(`bundle:${C().id}`, B);
  // a prefetched view may be a few seconds old: one revision check catches what changed in between (no full reload). A new
  // channel does that check once it is live (onLive above), which also covers the view; only a kept channel checks now. If
  // Realtime never confirms (blocked websocket), the check still runs after a few seconds.
  else if (options.view?.fetched_at && Date.now() - options.view.fetched_at > 1500) {
    if (liveReady) catchUpSoon();
    else catchUpFallback();
  }
}

// Party-wide identification (20261114000300): a share that found this character busy waits in party_share_pending; the sheet
// applies it on open and after an inventory refresh (at most every 20 s). A no-op server call when nothing waits; errors ignored.
let partySyncAt = 0;
function partySyncSoon(characterId, force = false) {
  if (ctx?.readOnly || (!force && Date.now() - partySyncAt < 20000)) return;
  partySyncAt = Date.now();
  syncPartyKnowledge(characterId).then((r) => { if (r?.applied && C()?.id === characterId) inventory?.scheduleRefresh?.(); }).catch(() => {});
}

// Quest log (docs/QUEST_LOG.md): read lazily, ONE request each time the tab is shown (also on ?fluent=0). There is no live
// push for quests: switching back to the tab or its Refresh button shows the DM's latest changes. The data stays in the
// quests module (never in B, which the legacy path caches in localStorage).
function openQuests() {
  if (!B || !root || ctx?.readOnly) return;
  const id = C().id;
  const el = $('#quests-app', root);
  if (!el) return;
  if (quests && quests.characterId === id && quests.el === el) { quests.refresh(); return; }
  const my = ++questsSeq;
  import('./quests.js?v=34').then((m) => {
    if (my !== questsSeq || !B || C().id !== id || !el.isConnected) return;
    quests?.destroy();
    quests = m.mountQuestTab(el, { characterId: id });
  }).catch((err) => { if (my === questsSeq && el.isConnected) el.innerHTML = `<p class="gov-error" role="alert">${esc(err?.message || 'The quest log could not be loaded.')}</p>`; });
}

function mountInventoryPanel() {
  inventoryDeferred = false;
  if (!root || inventory) return;
  const id = C().id;
  let invLoaded = false;
  inventory = mountInventory($('#inventory-app', root), {
    characterId: id,
    getCharacter: C,
    getInfused: () => infusedItemMap(infusionState),
    userId: state.profile?.id,
    getCampaigns: myCampaigns,
    onRows: (rows) => {
      B.inventory = rows.map(legacyInventoryRow);
      cacheLater();
      renderWeapons();   // the weapon cards get the item facts (icon, rarity, description) from the masked rows
      partySyncSoon(id);   // party shares that could not reach this character at once (20261114000300)
      if (invLoaded) scheduleDerived();   // the first load is not a change: the derived read started on mount covers it
      invLoaded = true;
    },
    getEquipmentNotes: (inventoryItemId) => equipmentNotes(derived, inventoryItemId),
    // Crafting (docs/CRAFTING_V1.md; only with js/config.js CRAFTING = 'on'): the character's player, when the campaign allows it
    crafting: { allowed: () => !!state.profile?.id && C().owner_id === state.profile.id && govState?.gov?.decisions?.['inventory.craft'] === 'player_managed' },
    loadBundle: sheetFluent ? async () => {
      const seed = await awaitSeed('inventory_bundle', id);
      if (seed.hit) { if (seed.error) throw seed.error; return seed.data; }
      const r = await readNow(id, ['inventory_bundle']);
      if (r.errors?.inventory_bundle) throw r.errors.inventory_bundle;
      return r.reads.inventory_bundle;
    } : null,
  });
}

// ---- fluent read path: one revision table instead of 70 bindings (docs/CHARACTER_DATA_INVALIDATION_MODEL.md) ------------
// The stored-row lists of the sheet: a revision of one of them re-reads that list and replays the differences through
// onRemote (same patching, focus and in-flight-edit protection as the per-row events of the legacy path).
/** Run `fn` when the browser is idle (low-priority prefetch), at the latest after 3 s. */
const whenIdle = (fn) => (window.requestIdleCallback ? window.requestIdleCallback(fn, { timeout: 3000 }) : setTimeout(fn, 1200));

// What the mounted sheet reads after the Character Shell (js/read-layer.js prefetchDomain): Play, Abilities and Build share
// these loaders, so they come in one request; Spells and Inventory add their own domain when they are the open tab.
const SHEET_DOMAIN_READS = ['get_character_proficiencies', 'get_character_lineage', 'get_character_background', 'get_character_feats',
  'get_character_class_summary', 'get_character_spell_slots', 'get_character_class_features', 'get_character_resources',
  'get_character_states', 'get_character_transformation', 'companions', 'get_character_infusions', 'starting_equipment_applied',
  'primary_class_starting_equipment', 'get_character_conditions'];
const LIST_TABLES = new Set(['notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells']);
const pendingLists = new Set();

/** A committed change of `table` for this character (revision `rev`): refresh only that domain. */
function onRevision(table, rev) {
  if (!B || !sheetFluent || ctx?.readOnly) return;
  if (rev && rev <= knownRevision(table)) return;          // already known: a duplicate or replayed event
  noteRevisions({ [table]: rev });
  if (LIST_TABLES.has(table)) { pendingLists.add(table); refreshListsSoon(); return; }
  if (table === 'character_conditions') { scheduleConditions(); return; }   // a VISIBLE change (hidden ones write no revision)
  if (table === 'inventory_items' || table === 'character_equipment') {
    if (inventory) { inventory.scheduleRefresh(); return; }  // its onRows re-reads the derived stats
    scheduleDerived();                                        // the panel is not open: AC, attacks and the stored rows only
    if (table === 'inventory_items') { pendingLists.add('inventory_items'); refreshListsSoon(); }
    return;
  }
  onRemote(table, 'UPDATE', { character_id: C().id }, null); // the legacy handler decides which loaders re-read
}

async function refreshLists() {
  if (!B || !pendingLists.size) return;
  const id = C().id;
  const tables = [...pendingLists];
  pendingLists.clear();
  let data;
  try { data = await readNow(id, tables); } catch (err) { if (!isAbortError(err)) console.warn('[lists]', err?.message || err); return; }
  if (!B || C().id !== id) return;
  for (const t of tables) {
    const rows = data.reads?.[t];
    if (!Array.isArray(rows)) continue;
    if (t === 'inventory_items') { if (!inventory) B.inventory = rows; continue; }
    const list = B[LIST_KEY[t]];
    if (!list) continue;
    const fresh = new Set(rows.map((r) => r.id));
    for (const row of rows) onRemote(t, list.some((r) => r.id === row.id) ? 'UPDATE' : 'INSERT', row, null);
    for (const r of [...list]) if (!fresh.has(r.id)) onRemote(t, 'DELETE', null, { id: r.id });
  }
}
const refreshListsSoon = debounce(refreshLists, 300);

/** After a dropped connection or a prefetched view: one request (row + revisions), then only the changed domains. */
async function reconcile() {
  if (!B || !sheetFluent) return;
  const id = C().id;
  let data;
  try { data = await readNow(id, ['characters', 'revisions']); } catch (err) { if (!isAbortError(err)) console.warn('[reconcile]', err?.message || err); return; }
  if (!B || C().id !== id) return;
  if (data.reads?.characters) onRemote('characters', 'UPDATE', data.reads.characters, null);
  for (const [t, r] of Object.entries(data.reads?.revisions || {})) if (r > knownRevision(t)) onRevision(t, r);
}

// Fluent catch-up: ONE debounce for every trigger (a stale prefetched view, Realtime going live, a reconnect), so a sheet open
// or a reconnect does at most one revision read. The read that closes the gap must come AFTER Realtime delivers changes again,
// so a reconnect ('SUBSCRIBED' after a drop) only saves own unsaved edits and waits for "Subscribed to PostgreSQL" (onLive,
// which Realtime sends again after every rejoin); a fallback reads anyway if that never comes. A flaky network that drops and
// returns several times in a few seconds causes one read, not one per return.
let catchUpReconnect = false;
const catchUpDebounced = debounce(() => {
  const reconnect = catchUpReconnect;
  catchUpReconnect = false;
  if (!B || !sheetFluent || liveCharacterId !== C().id) return;
  if (!reconnect) { reconcile(); return; }
  toast('Connection restored — showing the latest values.', 'info');
  saver.flush().finally(() => reconcile());
}, 1500);
function catchUpSoon() { catchUpDebounced(); }
/** Realtime never confirmed (blocked websocket, server trouble): check once after a few seconds anyway. */
function catchUpFallback() {
  if (!B) return;
  const id = C().id;
  setTimeout(() => { if (B && C().id === id && !liveReady) catchUpSoon(); }, 6000);
}
function onReconnect() {
  if (!B) return;
  catchUpReconnect = true;
  liveReady = false;
  saver.flush().catch(() => {});
  catchUpFallback();
}

// Legacy path (?fluent=0) after a dropped connection: own unsaved edits are saved first, then the whole sheet reloads (once
// per burst of reconnects).
const resyncSoon = debounce(() => {
  if (!B || liveCharacterId !== C().id) return;
  toast('Connection restored — showing the latest values.', 'info');
  saver.flush().finally(() => ctx?.reload?.());
}, 1500);

/** Close the sheet. keepRealtimeFor: the character about to be mounted again (its channel stays open). */
export function unmountSheet({ keepRealtimeFor = null } = {}) {
  endSheetReads();
  endReadScope();
  pendingLists.clear();
  inventoryDeferred = false;
  vitalsObserver?.disconnect();
  vitalsObserver = null;
  const tv = document.getElementById('topbar-vitals');
  if (tv) { tv.hidden = true; tv.innerHTML = ''; }
  govState = null;
  unsubSaver?.();
  unsubSaver = null;
  unsubUnits?.();
  unsubUnits = null;
  derived = null;
  condRows = null;
  profState = null;
  profPending = {};
  derivedSeq += 1;
  lineage = null;
  lineageSeq += 1;
  background = null;
  backgroundSeq += 1;
  spellbook = null;
  spellbookSeq += 1;
  classSummary = null;
  slotState = null;
  slotBusy = new Set();
  slotsSeq += 1;
  tfBusy = new Set();
  tfSeq += 1;
  transformState = null;
  classFeatures = null;
  classResources = null;
  resSeq += 1;
  classSeq += 1;
  featState = null;
  featSeq += 1;
  inventory?.destroy();
  inventory = null;
  quests?.destroy();
  quests = null;
  questsSeq += 1;
  governance?.destroy();
  governance = null;
  if (!keepRealtimeFor || keepRealtimeFor !== liveCharacterId) {
    unsubscribe?.();
    unsubscribe = null;
    liveCharacterId = null;
    liveFluent = false;
    liveReady = false;
  }
  serverChar = null;
  spellbookStale = false;
  B = null;
  root = null;
}
