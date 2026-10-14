import {
  ABILITIES, ABILITY_BY_KEY, SKILLS, SKILL_BY_KEY, CLASSES, HIT_DICE, ALIGNMENTS,
  RESOURCE_PRESETS, RESET_LABELS, FEATURE_CATEGORIES,
  DAMAGE_TYPES, SPELL_EFFECT_TYPES, SPELL_SCHOOLS, ATTACK_ABILITIES, EQUIPMENT_PROFICIENCIES, WEAPONS,
  ACTIVATIONS, ACTIVATION_BY_KEY, CASTING_TIMES, CONDITIONS, CONDITION_BY_NAME,
  weaponToAttack, ordinal, castingGroup, skillLevel, skillValue, mod, fmt, profBonus, xpForNextLevel, levelForXp,
} from './dnd.js?v=4';
import {
  saver, insertRow, deleteRow, deleteCharacter, subscribeCharacter, state, isDM, uploadPortrait, removePortraitFile,
} from './store.js?v=4';
import { $, $$, esc, clamp, toast, confirmDialog, openModal, cacheSet, debounce, autoResize } from './utils.js?v=4';
import { exportCharacter, downloadJson } from './transfer.js?v=4';
import { openLevelUp } from './levelup.js?v=4';

// -----------------------------------------------------------------------------
// Module state — one sheet is mounted at a time.
// -----------------------------------------------------------------------------

let B = null; // bundle: { character, inventory, notes, slots, trackers, features, attacks, spells }
let root = null;
let ctx = null; // { reload, onDeleted }
let unsubscribe = null;
const editing = new Set(); // "table:id" of attack/spell cards open for editing

const TABS = [
  { key: 'combat', label: 'Combat' },
  { key: 'stats', label: 'Stats' },
  { key: 'spells', label: 'Spells' },
  { key: 'inventory', label: 'Inventory' },
  { key: 'features', label: 'Features' },
  { key: 'resources', label: 'Resources' },
  { key: 'notes', label: 'Notes' },
  { key: 'bio', label: 'Bio' },
];

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
  return t === 'attacks' ? 'combat' : t; // the Combat tab used to be called "attacks"
};
const setTab = (t) => { try { localStorage.setItem('tavern-ledger:tab', t); } catch { /* ignore */ } };

const cacheLater = debounce(() => { if (B) cacheSet(`bundle:${C().id}`, B); }, 1000);

// -----------------------------------------------------------------------------
// Derived values
// -----------------------------------------------------------------------------

const pb = () => profBonus(C().level);
const abilityMod = (key) => mod(C()[ABILITY_BY_KEY[key].col]);
const saveProf = (key) => !!C().save_proficiencies?.[key];
const skillProf = (key) => skillLevel(C().skill_proficiencies?.[key]); // 0 none, 1 proficient, 2 expertise
const saveBonus = (key) => abilityMod(key) + (saveProf(key) ? pb() : 0);
const skillBonus = (key) => abilityMod(SKILL_BY_KEY[key].ability) + skillProf(key) * pb();
const initiative = () => abilityMod('dex') + (C().initiative_bonus || 0);
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

function subtitle() {
  const c = C();
  const cls = [c.class_name, c.subclass && `(${c.subclass})`].filter(Boolean).join(' ');
  return [`Level ${c.level}`, c.race, cls].filter(Boolean).join(' · ');
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
    case 'speed': return String(c.speed);
    case 'spelldc': return c.spellcasting_ability ? String(8 + pb() + abilityMod(c.spellcasting_ability)) : '—';
    case 'spellatk': return c.spellcasting_ability ? fmt(pb() + abilityMod(c.spellcasting_ability)) : '—';
    case 'xpnext': {
      const next = xpForNextLevel(c.level);
      if (next == null) return 'Max level';
      const ready = levelForXp(c.experience) > c.level;
      return ready ? `Ready to level up! (${next.toLocaleString()} XP)` : `Next level at ${next.toLocaleString()} XP`;
    }
    case 'weight': {
      const w = B.inventory.reduce((sum, i) => sum + Number(i.weight || 0) * Number(i.quantity || 0), 0);
      return `${Math.round(w * 100) / 100} lb`;
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
    el.setAttribute('aria-pressed', on);
  });
  $$('[data-action="cycle-skill"]', root).forEach((el) => {
    const lvl = skillProf(el.dataset.k);
    el.dataset.level = lvl;
    el.title = ['Not proficient', 'Proficient', 'Expertise'][lvl];
  });
  $$('[data-action="toggle-inspiration"]', root).forEach((el) => {
    el.classList.toggle('on', !!c.inspiration);
    el.setAttribute('aria-pressed', !!c.inspiration);
  });
  $$('[data-action="death"]', root).forEach((el) => {
    const count = el.dataset.kind === 'success' ? c.death_successes : c.death_failures;
    el.classList.toggle('on', Number(el.dataset.i) < count);
  });
  $$('[data-action="toggle-equip"]', root).forEach((el) => {
    const on = !!c.equipment_proficiencies?.[el.dataset.k];
    el.classList.toggle('on', on);
    el.setAttribute('aria-pressed', on);
  });
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

function refreshHp() {
  const c = C();
  const max = Math.max(1, c.hp_max);
  const pct = clamp((c.hp_current / max) * 100, 0, 100);
  const tempPct = clamp((c.hp_temp / max) * 100, 0, 100 - pct);
  const card = $('#hp-card', root);
  if (!card) return;
  $('.hp-fill', card).style.width = `${pct}%`;
  $('.hp-temp-fill', card).style.left = `${pct}%`;
  $('.hp-temp-fill', card).style.width = `${tempPct}%`;
  card.dataset.state = c.hp_current <= 0 ? 'down' : pct <= 25 ? 'critical' : pct <= 50 ? 'bloodied' : 'healthy';
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
    default: return el.value;
  }
}

function clampField(table, field, v, row) {
  if (table === 'characters') {
    if (field === 'level') return clamp(v, 1, 20);
    if (ABILITIES.some((a) => a.col === field)) return clamp(v, 1, 30);
    if (field === 'hp_max') return Math.max(1, v);
    if (field === 'hp_current') return clamp(v, 0, 9999);
    if (['hp_temp', 'experience', 'hit_dice_current', 'cp', 'sp', 'ep', 'gp', 'pp'].includes(field)) return Math.max(0, v);
  }
  if (table === 'feature_trackers') {
    if (field === 'max') return clamp(v, 0, 999);
    if (field === 'current') return clamp(v, 0, row.max);
  }
  if (table === 'inventory_items' && (field === 'quantity' || field === 'weight')) return Math.max(0, v);
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
  if (table === 'characters') refreshCharacterBits();
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

function stripHTML() {
  const trackers = B.trackers.map((t) => `
    <div class="res-chip">
      <div class="res-name">${esc(t.name)}</div>
      <div data-pips="tracker:${t.id}">${trackerPips(t)}</div>
    </div>`);
  const slots = B.slots.filter((s) => s.total > 0).map((s) => `
    <div class="res-chip slot-chip">
      <div class="res-name">Lvl ${s.level} slots</div>
      <div data-pips="slot:${s.id}">${slotBoxes(s)}</div>
    </div>`);
  const all = [...trackers, ...slots];
  return all.length
    ? all.join('')
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
    : `<span>${esc(initials(c.name))}</span>`;
}

const activeConditions = () => (Array.isArray(C().conditions) ? C().conditions : []);

function conditionsHTML() {
  const chips = activeConditions().map((name, i) =>
    `<button type="button" class="condition-chip" data-action="show-condition" data-i="${i}">${esc(name)}</button>`).join('');
  return `${chips}<button type="button" class="condition-add" data-action="add-condition">+ Condition</button>`;
}

/** Character-level bits that are not plain inputs: avatar and conditions. */
function refreshCharacterBits() {
  for (const [sel, html] of [['#sheet-avatar', avatarHTML()], ['#conditions-row', conditionsHTML()], ['#portrait-preview', avatarHTML()]]) {
    const el = $(sel, root);
    if (el && el.__html !== html) { el.innerHTML = html; el.__html = html; }
  }
}

function headerHTML() {
  const owner = isDM() ? state.profiles.find((p) => p.id === C().owner_id) : null;
  return `
  <header class="sheet-header">
    <button type="button" class="avatar" id="sheet-avatar" data-action="tab" data-tab="bio" aria-label="Portrait (edit on the Bio tab)">${avatarHTML()}</button>
    <div class="sheet-id">
      <h1 class="char-name" data-derive="name"></h1>
      <div class="char-sub" data-derive="subtitle"></div>
      ${owner && owner.id !== state.profile.id ? `<div class="owner-tag">Player: ${esc(owner.display_name || owner.email)}</div>` : ''}
    </div>
    <div class="sheet-actions">
      <button type="button" class="btn btn-gold" data-action="level-up">▲ Level Up</button>
      <button type="button" class="btn" data-action="short-rest" title="Restore short-rest resources">☾ Short Rest</button>
      <button type="button" class="btn" data-action="long-rest" title="Restore HP, slots and resources">☀ Long Rest</button>
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

function combatHTML() {
  const c = C();
  return `
  <div class="combat-grid">
    <div class="hp-card" id="hp-card">
      <div class="hp-top">
        <span class="stat-label">Hit Points</span>
        <label class="temp-hp">Temp ${numInput('characters', c, 'hp_temp', 'temp-input', 'min="0" aria-label="Temporary hit points"')}</label>
      </div>
      <div class="hp-row">
        ${numInput('characters', c, 'hp_current', 'hp-current', 'aria-label="Current hit points"')}
        <span class="hp-sep">/</span>
        ${numInput('characters', c, 'hp_max', 'hp-max', 'min="1" aria-label="Maximum hit points"')}
      </div>
      <div class="hp-bar"><div class="hp-fill"></div><div class="hp-temp-fill"></div></div>
      <div class="hp-controls">
        <button type="button" class="btn btn-bad" data-action="hp-damage">Damage</button>
        <input type="number" inputmode="numeric" min="0" id="hp-amount" placeholder="0" aria-label="Amount">
        <button type="button" class="btn btn-good" data-action="hp-heal">Heal</button>
      </div>
      <div class="down-only">${deathSavesHTML()}</div>
    </div>
    <div class="tiles">
      <div class="tile tile-ac"><span class="stat-label"><span class="lbl-long">Armor Class</span><span class="lbl-short">AC</span></span>${numInput('characters', c, 'ac', 'big-num', 'aria-label="Armor class"')}</div>
      <div class="tile"><span class="stat-label">Initiative</span><span class="big-num" data-derive="init"></span></div>
      <div class="tile"><span class="stat-label">Speed</span><div class="with-unit">${numInput('characters', c, 'speed', 'big-num', 'aria-label="Speed"')}<span class="unit">ft</span></div></div>
      <div class="tile"><span class="stat-label">Proficiency</span><span class="big-num" data-derive="pb"></span></div>
    </div>
  </div>
  <div class="conditions-row" id="conditions-row" aria-label="Conditions">${conditionsHTML()}</div>
  <div class="resource-strip" id="resource-strip">${stripHTML()}</div>
  <button type="button" class="compact-toggle" data-action="toggle-compact" aria-label="Collapse or expand combat bar"></button>`;
}

const getCompact = () => { try { return localStorage.getItem('tavern-ledger:compact') === '1'; } catch { return false; } };
const setCompact = (on) => { try { localStorage.setItem('tavern-ledger:compact', on ? '1' : '0'); } catch { /* ignore */ } };

function statsHTML() {
  const c = C();
  const abilities = ABILITIES.map((a) => `
    <div class="ability">
      <span class="ability-name" title="${a.name}">${a.short}</span>
      <span class="ability-mod" data-derive="mod:${a.key}"></span>
      ${numInput('characters', c, a.col, 'ability-score', `min="1" max="30" aria-label="${a.name} score"`)}
    </div>`).join('');

  const saves = ABILITIES.map((a) => `
    <li>
      <button type="button" class="prof-dot" data-action="toggle-save" data-k="${a.key}" aria-label="${a.name} save proficiency"></button>
      <span class="bonus" data-derive="save:${a.key}"></span>
      <span class="li-name">${a.name}</span>
    </li>`).join('');

  const skills = SKILLS.map((s) => `
    <li>
      <button type="button" class="prof-dot" data-action="cycle-skill" data-k="${s.key}" aria-label="${s.name} proficiency"></button>
      <span class="bonus" data-derive="skill:${s.key}"></span>
      <span class="li-name">${s.name}</span>
      <span class="abil-tag">${ABILITY_BY_KEY[s.ability].short}</span>
    </li>`).join('');

  return `
  <div class="stats-layout">
    <div class="abilities">${abilities}</div>

    <div class="stats-cols">
      <div class="col">
        <section class="card">
          <h3>Saving Throws</h3>
          <ul class="prof-list">${saves}</ul>
        </section>
        <section class="card">
          <h3>Senses & Status</h3>
          <div class="kv-list">
            <div class="kv"><span>Passive Perception</span><strong data-derive="passive:perception"></strong></div>
            <div class="kv"><span>Passive Insight</span><strong data-derive="passive:insight"></strong></div>
            <div class="kv"><span>Passive Investigation</span><strong data-derive="passive:investigation"></strong></div>
            <div class="kv"><span>Inspiration</span><button type="button" class="toggle" data-action="toggle-inspiration" aria-label="Inspiration"></button></div>
            <div class="kv"><span>Initiative misc. bonus</span>${numInput('characters', c, 'initiative_bonus', 'small-num', 'aria-label="Initiative bonus"')}</div>
          </div>
        </section>
        <section class="card">
          <h3>Hit Dice</h3>
          <div class="hd-row">
            ${numInput('characters', c, 'hit_dice_current', 'small-num', 'min="0" aria-label="Hit dice remaining"')}
            <span class="muted">of <span data-derive="level"></span></span>
            <select ${cbind('hit_die')} aria-label="Hit die">
              ${HIT_DICE.map((d) => `<option ${c.hit_die === d ? 'selected' : ''}>${d}</option>`).join('')}
            </select>
          </div>
          <h3 class="mt">Death Saves</h3>
          ${deathSavesHTML()}
        </section>
      </div>

      <div class="col">
        <section class="card">
          <h3>Skills <span class="hint">tap ○ to cycle: none → proficient → expertise</span></h3>
          <ul class="prof-list skills-list">${skills}</ul>
        </section>
      </div>

      <div class="col">
        <section class="card">
          <h3>Proficiencies <span class="hint">tap to toggle</span></h3>
          <div class="chip-grid">
            ${EQUIPMENT_PROFICIENCIES.map((p) => `<button type="button" class="chip-toggle" data-action="toggle-equip" data-k="${p.key}">${p.label}</button>`).join('')}
          </div>
          <label class="field mt"><span>Tools, languages & other</span>
            ${textArea('characters', c, 'proficiencies', 'notes-area', 'placeholder="Tools: Thieves\' tools&#10;Languages: Common, Elvish"')}
          </label>
        </section>
      </div>
    </div>
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
  `<button type="button" class="icon-btn edit-btn" data-action="toggle-edit" data-key="${key}" aria-label="Edit">✎</button>`;

// ---- Attacks -------------------------------------------------------------

function attackViewHTML(a) {
  const meta = [a.attack_kind === 'ranged' ? 'Ranged' : 'Melee', a.range, a.properties].filter(Boolean).map(esc).join(' · ');
  return `
    <div class="entry-head">
      <h4 class="entry-name">${esc(a.name || 'Unnamed attack')}</h4>
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
    : '<p class="empty">No attacks yet. Add a weapon below.</p>';
}

// ---- Combat tab: everything grouped by how you use it ----------------------

const GROUP_HINTS = {
  action: 'One per turn. Anyone can also: Attack · Cast a Spell · Dash · Disengage · Dodge · Help · Hide · Ready · Use an Object.',
  bonus_action: 'One per turn, only if a feature or spell gives you one.',
  reaction: 'One per round, and it can happen on other creatures’ turns. Everyone can make an opportunity attack when an enemy leaves their reach.',
};
const GROUP_EMPTY = {
  action: 'No special actions yet.',
  bonus_action: 'No bonus actions yet. Set a feature’s type to “Bonus Action” on the Features tab, or give a spell a “1 bonus action” casting time.',
  reaction: 'No reactions yet. Set a feature’s type to “Reaction”, or give a spell a “1 reaction” casting time.',
};

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
        <h4 class="entry-name">${esc(f.name || 'Unnamed feature')}</h4>
        ${source ? `<div class="entry-sub">${esc(source)}</div>` : ''}
      </div>
      <button type="button" class="icon-btn edit-btn" data-action="goto-feature" data-id="${f.id}" aria-label="Edit on the Features tab">✎</button>
    </div>
    ${f.description ? `<p class="entry-notes">${esc(f.description)}</p>` : ''}`;
}

const featureCard = (f) =>
  `<article class="entry combat-feature"><div class="entry-view" data-view="features:${f.id}">${featureViewHTML(f)}</div></article>`;
const spellCard = (s) =>
  `<article class="entry combat-spell"><div class="entry-view" data-view="spells:${s.id}">${spellViewHTML(s)}</div></article>`;

function combatGroupsHTML() {
  lastCombatSignature = combatSignature();
  const groups = ['action', 'bonus_action', 'reaction'].map((key) => {
    const { feats, spells } = groupItems(key);
    const items = [...feats.map(featureCard), ...spells.map(spellCard)].join('');
    return `
      <section class="combat-group group-${key}">
        <h3 class="section-title">${ACTIVATION_BY_KEY[key].plural}</h3>
        <p class="group-hint">${GROUP_HINTS[key]}</p>
        <div class="entry-list">${items || `<p class="empty">${GROUP_EMPTY[key]}</p>`}</div>
      </section>`;
  }).join('');
  const passive = groupItems('passive').feats;
  return `${groups}
    <details class="combat-group passive-group" ${passive.length ? '' : 'hidden'}>
      <summary><span class="section-title">Passive Features</span> <span class="count">${passive.length}</span>
        <span class="hint">always on, nothing to activate</span></summary>
      <div class="entry-list">${passive.map(featureCard).join('')}</div>
    </details>`;
}

function refreshCombat() {
  if (combatSignature() !== lastCombatSignature) rerender('#combat-groups', combatGroupsHTML());
}

function combatTabHTML() {
  const group = (cat, kind, label) => `
    <optgroup label="${label}">
      ${WEAPONS.map((w, i) => (w.cat === cat && w.kind === kind ? `<option value="${i}">${w.name} (${w.dice} ${w.type})</option>` : '')).join('')}
    </optgroup>`;
  return `
  <details class="card turn-guide">
    <summary>New to combat? How your turn works</summary>
    <ul>
      <li><strong>Move</strong> up to your speed (<span data-derive="speed"></span> ft). You can split it before and after your action.</li>
      <li><strong>Action</strong>: one per turn, e.g. attack with a weapon or cast a spell.</li>
      <li><strong>Bonus action</strong>: only when a feature or spell says you can use one.</li>
      <li><strong>Reaction</strong>: one per round, even on other creatures’ turns.</li>
      <li><strong>Attacking:</strong> roll a d20 and add <em>To hit</em>. If the total equals or beats the target’s AC, you hit: roll the <em>Damage</em>.</li>
      <li><strong>Saving throw spells:</strong> the target rolls a d20 + their save. If they roll below your <em>DC</em>, the spell’s full effect lands.</li>
      <li><strong>Natural 20</strong> on an attack is a critical hit: roll the damage dice twice.</li>
    </ul>
  </details>

  <h3 class="section-title">Attacks <span class="hint">use your Action</span></h3>
  <div id="attacks-list" class="entry-list">${attacksListHTML()}</div>
  <details class="card add-weapon">
    <summary>+ Add a weapon or attack</summary>
    <div class="add-tracker mt">
      <select id="weapon-preset" aria-label="Weapon">
        <option value="custom">Custom attack…</option>
        <option value="unarmed">Unarmed strike (1 bludgeoning)</option>
        ${group('simple', 'melee', 'Simple melee')}
        ${group('simple', 'ranged', 'Simple ranged')}
        ${group('martial', 'melee', 'Martial melee')}
        ${group('martial', 'ranged', 'Martial ranged')}
      </select>
      <button type="button" class="btn btn-gold" data-action="add-attack">+ Add</button>
    </div>
    <p class="muted small">“To hit” and “Damage” are worked out from your ability scores and proficiency, so they stay correct when you level up. Tap ✎ on a card to change anything.</p>
  </details>

  <div id="combat-groups">${combatGroupsHTML()}</div>

  <section class="card mt">
    <h3>Other combat notes</h3>
    ${textArea('notes', note('attacks'), 'content', 'notes-area', 'placeholder="Tactics, reminders, anything else…"')}
  </section>`;
}

// ---- Spells --------------------------------------------------------------

function spellViewHTML(s) {
  const key = `spells:${s.id}`;
  const sub = s.level === 0
    ? `${s.school ? `${esc(s.school)} ` : ''}cantrip`
    : `${ordinal(s.level)}${s.school ? ` · ${esc(s.school)}` : ''}`;
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
        <h4 class="entry-name">${esc(s.name || 'Unnamed spell')}</h4>
        <div class="entry-sub">${sub}
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
          <h3>${level === 0 ? 'Cantrips' : `Level ${level} spells`}
            ${level === 0 ? '<span class="hint">at will, no slot needed</span>' : ''}
          </h3>
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

  return `
  <section class="card spellcasting-card">
    <div class="spell-stats">
      <label class="field"><span>Spellcasting ability</span>
        <select ${cbind('spellcasting_ability')}>
          <option value="">—</option>
          ${ABILITIES.map((a) => `<option value="${a.key}" ${c.spellcasting_ability === a.key ? 'selected' : ''}>${a.name}</option>`).join('')}
        </select>
      </label>
      <div class="mini-tile"><span class="stat-label">Spell save DC</span><span class="big-num" data-derive="spelldc"></span></div>
      <div class="mini-tile"><span class="stat-label">Spell attack</span><span class="big-num" data-derive="spellatk"></span></div>
    </div>
    <details class="slot-manager">
      <summary>Manage spell slots</summary>
      <p class="muted small">Use − / + to set how many slots you have. Tap a box to mark it used.</p>
      <div class="slot-list">${slots}</div>
      <button type="button" class="btn btn-sm mt" data-action="reset-slots">Restore all slots</button>
    </details>
  </section>
  <div id="spells-list">${spellsListHTML()}</div>
  <datalist id="casting-times">${CASTING_TIMES.map((x) => `<option value="${x}">`).join("")}</datalist>
  <section class="card mt">
    <h3>Spell notes</h3>
    ${textArea('notes', note('spells'), 'content', 'notes-area', 'placeholder="Anything else about your magic…"')}
  </section>`;
}

function inventoryItemHTML(item) {
  return `
  <div class="item card" data-item="${item.id}">
    <div class="item-row">
      <label class="equip" title="Equipped">
        <input type="checkbox" ${bind('inventory_items', item, 'equipped', 'bool')} ${item.equipped ? 'checked' : ''}>
        <span></span>
      </label>
      ${textInput('inventory_items', item, 'name', 'item-name', 'aria-label="Item name" placeholder="Item name"')}
      <label class="item-qty"><span>Qty</span>${numInput('inventory_items', item, 'quantity', '', 'min="0"')}</label>
      <label class="item-wt"><span>lb</span><input type="number" inputmode="decimal" step="0.1" min="0" ${bind('inventory_items', item, 'weight', 'num')} value="${esc(item.weight)}"></label>
      <button type="button" class="icon-btn danger" data-action="delete-item" data-id="${item.id}" aria-label="Delete item">🗑</button>
    </div>
    ${textArea('inventory_items', item, 'description', 'item-desc', 'rows="1" placeholder="Description, properties, charges…"')}
  </div>`;
}

function inventoryHTML() {
  const c = C();
  const coins = ['cp', 'sp', 'ep', 'gp', 'pp'].map((k) => `
    <label class="coin coin-${k}"><span>${k.toUpperCase()}</span>${numInput('characters', c, k, '', 'min="0"')}</label>`).join('');
  return `
  <section class="card">
    <h3>Coins</h3>
    <div class="coins">${coins}</div>
  </section>
  <div class="section-head">
    <h3>Items <span class="hint">total weight <span data-derive="weight"></span></span></h3>
    <button type="button" class="btn btn-gold btn-sm" data-action="add-item">+ Add item</button>
  </div>
  <div id="inventory-list" class="item-list">${inventoryListHTML()}</div>`;
}

function inventoryListHTML() {
  return B.inventory.length
    ? B.inventory.map(inventoryItemHTML).join('')
    : '<p class="empty">Your pack is empty.</p>';
}

function featureHTML(f) {
  return `
  <div class="feature card" data-feature="${f.id}">
    <div class="feature-head">
      ${textInput('features', f, 'name', 'feature-name', 'aria-label="Feature name" placeholder="Feature name"')}
      <button type="button" class="icon-btn danger" data-action="delete-feature" data-id="${f.id}" aria-label="Delete feature">🗑</button>
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

function featuresHTML() {
  return `<div id="features-list">${featuresListHTML()}</div>`;
}

function featuresListHTML() {
  return FEATURE_CATEGORIES.map((cat) => {
    const list = B.features.filter((f) => f.category === cat.key);
    return `
    <section class="feature-group">
      <div class="section-head">
        <h3>${cat.label} <span class="count">${list.length || ''}</span></h3>
        <button type="button" class="btn btn-sm" data-action="add-feature" data-cat="${cat.key}">+ Add</button>
      </div>
      ${list.map(featureHTML).join('') || '<p class="empty">None yet.</p>'}
    </section>`;
  }).join('');
}

function trackerRowHTML(t) {
  return `
  <div class="tracker card" data-tracker="${t.id}">
    ${textInput('feature_trackers', t, 'name', 'tracker-name', 'aria-label="Resource name"')}
    <label class="field-inline"><span>Current</span>${numInput('feature_trackers', t, 'current', 'small-num', 'min="0"')}</label>
    <label class="field-inline"><span>Max</span>${numInput('feature_trackers', t, 'max', 'small-num', 'min="0"')}</label>
    <label class="field-inline"><span>Resets</span>
      <select ${bind('feature_trackers', t, 'reset_on')}>
        ${Object.entries(RESET_LABELS).map(([k, l]) => `<option value="${k}" ${t.reset_on === k ? 'selected' : ''}>${l}</option>`).join('')}
      </select>
    </label>
    <button type="button" class="icon-btn danger" data-action="delete-tracker" data-id="${t.id}" aria-label="Delete resource">🗑</button>
  </div>`;
}

function resourcesHTML() {
  return `
  <section class="card">
    <h3>Add a resource</h3>
    <div class="add-tracker">
      <select id="tracker-preset" aria-label="Resource type">
        ${RESOURCE_PRESETS.map((p, i) => `<option value="${i}">${p.name}</option>`).join('')}
        <option value="custom">Custom…</option>
      </select>
      <input type="text" id="tracker-custom" placeholder="Custom name" hidden>
      <button type="button" class="btn btn-gold" data-action="add-tracker">+ Add</button>
    </div>
    <p class="muted small">Resources appear in the combat bar at the top. Short and long rests restore them automatically.</p>
  </section>
  <div id="trackers-list" class="tracker-list">${trackersListHTML()}</div>`;
}

function trackersListHTML() {
  return B.trackers.length ? B.trackers.map(trackerRowHTML).join('') : '<p class="empty">No resources yet.</p>';
}

function notesHTML() {
  const block = (kind, title, placeholder) => `
    <section class="card">
      <h3>${title}</h3>
      ${textArea('notes', note(kind), 'content', 'notes-area tall', `placeholder="${placeholder}"`)}
    </section>`;
  return `
  <div class="notes-grid">
    ${block('character', 'Character Notes', 'Personality, ideals, bonds, flaws, backstory…')}
    ${block('session', 'Session Notes', 'What happened this session, loot, leads, things to remember next time…')}
    ${block('campaign', 'Campaign Notes', 'NPCs, places, factions, quests, the bigger picture…')}
  </div>
  <p class="muted small center">Notes save automatically as you type.</p>`;
}

function bioHTML() {
  const c = C();
  const ownerSelect = isDM() && state.profiles.length ? `
    <label class="field"><span>Player (owner)</span>
      <select ${cbind('owner_id')}>
        ${state.profiles.map((p) => `<option value="${p.id}" ${p.id === c.owner_id ? 'selected' : ''}>${esc(p.display_name || p.email)}${p.role === 'dm' ? ' (DM)' : ''}</option>`).join('')}
      </select>
    </label>` : '';
  return `
  <section class="card">
    <h3>Identity</h3>
    <div class="form-grid">
      <label class="field span-2"><span>Name</span>${textInput('characters', c, 'name')}</label>
      <label class="field"><span>Race</span>${textInput('characters', c, 'race')}</label>
      <label class="field"><span>Class</span>${textInput('characters', c, 'class_name', '', 'list="class-list"')}</label>
      <label class="field"><span>Subclass</span>${textInput('characters', c, 'subclass')}</label>
      <label class="field"><span>Background</span>${textInput('characters', c, 'background')}</label>
      <label class="field"><span>Alignment</span>${textInput('characters', c, 'alignment', '', 'list="alignment-list"')}</label>
      <label class="field"><span>Level</span>${numInput('characters', c, 'level', '', 'min="1" max="20"')}</label>
      <label class="field"><span>Experience</span>${numInput('characters', c, 'experience', '', 'min="0"')}<small class="muted" data-derive="xpnext"></small></label>
      ${ownerSelect}
    </div>
    <datalist id="class-list">${CLASSES.map((x) => `<option value="${x}">`).join('')}</datalist>
    <datalist id="alignment-list">${ALIGNMENTS.map((x) => `<option value="${x}">`).join('')}</datalist>
  </section>
  <section class="card">
    <h3>Portrait</h3>
    <div class="portrait-editor">
      <div class="avatar avatar-lg" id="portrait-preview">${avatarHTML()}</div>
      <div class="stack grow">
        <div class="row gap">
          <label class="btn btn-gold btn-sm file-btn">Upload image
            <input type="file" accept="image/*" id="portrait-file" hidden>
          </label>
          <button type="button" class="btn btn-sm" data-action="remove-portrait">Remove</button>
        </div>
        <label class="field"><span>…or paste an image URL</span>${textInput('characters', c, 'portrait_url', '', 'placeholder="https://…" inputmode="url"')}</label>
      </div>
    </div>
  </section>
  <section class="card">
    <h3>Backup & sharing</h3>
    <p class="muted small">Download this character as a JSON file. You can import it again from the character list, e.g. to copy a character or move it to another campaign.</p>
    <button type="button" class="btn btn-sm" data-action="export-json">⬇ Download JSON</button>
  </section>
  <section class="card danger-zone">
    <h3>Danger zone</h3>
    <p class="muted small">Deleting a character removes its inventory, notes, features and resources permanently.</p>
    <button type="button" class="btn btn-bad" data-action="delete-character">Delete character</button>
  </section>`;
}

function render() {
  const active = TABS.some((t) => t.key === getTab()) ? getTab() : 'combat';
  root.innerHTML = `
  <div class="sheet">
    ${headerHTML()}
    <section class="combat-bar ${getCompact() ? 'compact' : ''}" aria-label="Combat">${combatHTML()}</section>
    <nav class="tabs" role="tablist">
      ${TABS.map((t) => `<button type="button" role="tab" class="tab" data-action="tab" data-tab="${t.key}" aria-selected="${t.key === active}">${t.label}</button>`).join('')}
    </nav>
    <div class="panels">
      <section class="panel" data-panel="combat">${combatTabHTML()}</section>
      <section class="panel" data-panel="stats">${statsHTML()}</section>
      <section class="panel" data-panel="spells">${spellsHTML()}</section>
      <section class="panel" data-panel="inventory">${inventoryHTML()}</section>
      <section class="panel" data-panel="features">${featuresHTML()}</section>
      <section class="panel" data-panel="resources">${resourcesHTML()}</section>
      <section class="panel" data-panel="notes">${notesHTML()}</section>
      <section class="panel" data-panel="bio">${bioHTML()}</section>
    </div>
  </div>`;
  showTab(active, false);
  refreshDerived();
  refreshToggles();
  refreshHp();
}

function showTab(key, scroll = true) {
  setTab(key);
  $$('.tab', root).forEach((t) => t.setAttribute('aria-selected', t.dataset.tab === key));
  $$('.panel', root).forEach((p) => { p.hidden = p.dataset.panel !== key; });
  $$(`.panel[data-panel="${key}"] textarea.autosize`, root).forEach(autoResize);
  if (scroll) {
    const tabs = $('.tabs', root);
    const top = tabs.getBoundingClientRect().top + window.scrollY - 70;
    if (window.scrollY > top) window.scrollTo({ top, behavior: 'smooth' });
    $(`.tab[data-tab="${key}"]`, root)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
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
  if (table === 'inventory_items') rerender('#inventory-list', inventoryListHTML());
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

function applyHp(sign) {
  const input = $('#hp-amount', root);
  const amt = parseInt(input.value, 10);
  if (!amt || amt < 0) {
    input.focus();
    toast('Enter an amount first');
    return;
  }
  const c = C();
  if (sign < 0) {
    const absorbed = Math.min(c.hp_temp, amt);
    setRow('characters', c, {
      hp_temp: c.hp_temp - absorbed,
      hp_current: Math.max(0, c.hp_current - (amt - absorbed)),
    });
  } else {
    const patch = { hp_current: Math.min(c.hp_max, c.hp_current + amt) };
    if (c.hp_current <= 0) Object.assign(patch, { death_successes: 0, death_failures: 0 });
    setRow('characters', c, patch);
  }
  input.value = '';
}

async function rest(kind) {
  const long = kind === 'long';
  const ok = await confirmDialog(
    long
      ? 'Restore HP, spell slots, half your hit dice and all short/long-rest resources?'
      : 'Restore all short-rest resources? (Spend hit dice by editing them on the Stats tab.)',
    { title: long ? 'Long Rest' : 'Short Rest', okLabel: long ? 'Take long rest' : 'Take short rest' },
  );
  if (!ok) return;

  for (const t of B.trackers) {
    const resets = long ? t.reset_on !== 'none' : t.reset_on === 'short';
    if (resets && t.current !== t.max) setRow('feature_trackers', t, { current: t.max });
  }
  if (long) {
    const c = C();
    setRow('characters', c, {
      hp_current: c.hp_max,
      hp_temp: 0,
      death_successes: 0,
      death_failures: 0,
      hit_dice_current: Math.min(c.level, c.hit_dice_current + Math.max(1, Math.floor(c.level / 2))),
    });
    for (const s of B.slots) if (s.used) setRow('spell_slots', s, { used: 0 });
  }
  toast(long ? 'Long rest taken. You feel refreshed.' : 'Short rest taken.', 'good');
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

async function addItem() {
  const row = await insertRow('inventory_items', {
    character_id: C().id, name: 'New item', sort_order: B.inventory.length,
  });
  if (!B.inventory.some((i) => i.id === row.id)) B.inventory.push(row);
  rerenderList('inventory_items');
  const input = $(`[data-t="inventory_items"][data-id="${row.id}"][data-f="name"]`, root);
  input?.focus();
  input?.select();
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

function setConditions(list) {
  setRow('characters', C(), { conditions: list });
}

function openConditionPicker() {
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

function showCondition(i) {
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
  'toggle-compact': () => {
    const bar = $('.combat-bar', root);
    setCompact(bar.classList.toggle('compact'));
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
    setRow('characters', C(), { save_proficiencies: { ...C().save_proficiencies, [k]: !saveProf(k) } });
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
  'add-condition': () => openConditionPicker(),
  'show-condition': (el) => showCondition(Number(el.dataset.i)),
  'remove-portrait': async () => {
    const url = C().portrait_url;
    if (!url) return;
    setRow('characters', C(), { portrait_url: '' });
    await removePortraitFile(url);
  },
  'export-json': () => {
    const slug = (C().name || 'character').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    downloadJson(exportCharacter(B), `${slug || 'character'}.json`);
  },
  'toggle-inspiration': () => setRow('characters', C(), { inspiration: !C().inspiration }),
  death: (el) => {
    const field = el.dataset.kind === 'success' ? 'death_successes' : 'death_failures';
    const i = Number(el.dataset.i);
    setRow('characters', C(), { [field]: i < C()[field] ? i : i + 1 });
  },
  'short-rest': () => rest('short'),
  'long-rest': () => rest('long'),
  'add-item': addItem,
  'delete-item': (el) => removeRow('inventory_items', el.dataset.id, 'item'),
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
  'toggle-equip': (el) => {
    const k = el.dataset.k;
    const cur = C().equipment_proficiencies || {};
    setRow('characters', C(), { equipment_proficiencies: { ...cur, [k]: !cur[k] } });
  },
  'level-up': async () => {
    await saver.flush();
    openLevelUp(B, { onApplied: () => ctx.reload() });
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
  const el = e.target;
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
  const el = e.target;
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

async function onClick(e) {
  const el = e.target.closest('[data-action]');
  if (!el || !root.contains(el)) return;
  const fn = actions[el.dataset.action];
  if (!fn) return;
  try {
    await fn(el);
  } catch (err) {
    console.error(err);
    toast(err.message || 'Something went wrong', 'bad');
  }
}

function onKeyDown(e) {
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

function onRemote(table, event, nw, old) {
  if (!B) return;
  if (table === 'characters') {
    if (applyRemote('characters', C(), nw)) {
      syncInputs('characters', C().id);
      afterChange('characters');
    }
    return;
  }

  const list = B[LIST_KEY[table]];
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
  unmountSheet();
  B = bundle;
  // Cached bundles from older versions may lack newer lists.
  B.attacks ||= [];
  B.spells ||= [];
  B.character.equipment_proficiencies ||= {};
  B.character.conditions ||= [];
  B.character.portrait_url ??= '';
  ctx = options;
  root = document.createElement('div');
  root.className = 'sheet-root';
  if (options.readOnly) root.classList.add('is-stale');
  container.replaceChildren(root);
  render();

  if (options.readOnly) return;

  root.addEventListener('input', onInput);
  root.addEventListener('change', onChange);
  root.addEventListener('click', onClick);
  root.addEventListener('keydown', onKeyDown);
  unsubscribe = subscribeCharacter(C().id, onRemote);
  cacheSet(`bundle:${C().id}`, B);
}

export function unmountSheet() {
  unsubscribe?.();
  unsubscribe = null;
  B = null;
  root = null;
}
