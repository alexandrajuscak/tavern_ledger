// Derived character stats on the sheet: AC breakdown, warnings, equipped weapon attacks, proficiency manager.
// The rules live in the database (get_character_derived_stats); this module only turns the structured result into text.
import { $, esc, toast, openModal } from './utils.js?v=36';
import * as api from './inventory-api.js?v=36';
import { weaponCardHTML, unknownWeaponCardHTML } from './weapon-card.js?v=36';

const fmt = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const FORMULA = { unarmored: 'Unarmored', light_armor: 'Light armor', medium_armor: 'Medium armor', heavy_armor: 'Heavy armor' };
const INACTIVE = { not_equipped: 'not equipped', not_attuned: 'needs attunement', wearing_armor: 'only works without armor',
  using_shield: 'only works without a shield' };
const SLOT = { main_hand: 'Main hand', off_hand: 'Off hand' };
const ARMOR_CODES = ['nonproficient_armor', 'nonproficient_shield', 'spellcasting_restricted', 'stealth_disadvantage',
  'strength_requirement_unmet', 'armor_stats_unknown', 'hidden_item', 'legacy_equipped_ignored', 'lineage_armor_no_benefit'];

/** A readable sentence for one structured warning. */
export function warningText(w) {
  const name = w.source_name || 'This item';
  switch (w.code) {
    case 'nonproficient_armor':
    case 'nonproficient_shield':
      return `Not proficient with ${w.missing_group_name || 'this armor'} (${name}). It still counts for your AC, but you have `
        + 'disadvantage on Strength and Dexterity checks, saving throws and attack rolls.';
    case 'spellcasting_restricted':
      return 'You can’t cast spells while wearing armor or a shield you aren’t proficient with.';
    case 'stealth_disadvantage': return `Stealth checks have disadvantage while wearing ${name}.`;
    case 'strength_requirement_unmet':
      if (!w.speed_penalty && w.speed_penalty_ignored_by) {
        return `${name} requires Strength ${w.required} (yours is ${w.current}), but ${w.speed_penalty_ignored_by} keeps heavy armor from slowing you.`;
      }
      return `${name} requires Strength ${w.required}. Your Strength is ${w.current}, so your speed is reduced by ${w.speed_penalty} ft while you wear it.`;
    case 'lineage_armor_no_benefit':
      return `${name} gives you no benefit: your ${w.trait_name || 'natural armor'} sets your Armor Class instead.`;
    case 'armor_stats_unknown':
      return `${name} has no armor statistics in the catalog, so it doesn’t change your AC. Set a manual override if needed.`;
    case 'hidden_item': return 'An equipped item is private homebrew you can’t see, so its effects aren’t included here.';
    case 'legacy_equipped_ignored':
      return `${w.count} old inventory ${w.count === 1 ? 'entry is' : 'entries are'} marked as equipped but not linked to the catalog; they don’t affect your stats.`;
    case 'nonproficient_weapon': return `Not proficient with ${w.missing_group_name || name}: no proficiency bonus on the attack roll.`;
    default: return name;
  }
}

export const armorWarnings = (d) => (d?.warnings || []).filter((w) => ARMOR_CODES.includes(w.code));

/** Short notes next to an equipped item in the Inventory tab. */
export function equipmentNotes(d, inventoryItemId) {
  const out = [];
  for (const w of d?.warnings || []) {
    if (w.source_id !== inventoryItemId) continue;
    if (['nonproficient_armor', 'nonproficient_shield', 'nonproficient_weapon'].includes(w.code)) out.push('Not proficient');
    if (w.code === 'strength_requirement_unmet') out.push(`Needs Strength ${w.required}`);
    if (w.code === 'stealth_disadvantage') out.push('Stealth disadvantage');
    if (w.code === 'armor_stats_unknown') out.push('No AC data');
  }
  return out;
}

/** The small text line under the AC number. */
export function acNote(d, { short = false } = {}) {
  if (!d) return '';
  const n = armorWarnings(d).filter((w) => w.code !== 'legacy_equipped_ignored').length;
  const parts = [];
  if (d.armor_class.source === 'override') parts.push('manual');
  if (n) parts.push(short ? `${n}` : `${n} warning${n === 1 ? '' : 's'}`);
  return parts.join(' · ');
}

const itemButton = (id, label) => (id
  ? `<button type="button" class="btn-link" data-goto-item="${esc(id)}">${esc(label)}</button>`
  : esc(label));

function breakdownRow(p) {
  if (p.effect === 'base_ac') {
    const label = p.source_type === 'rule' ? 'Unarmored base' : itemButton(p.source_id, p.source_name);
    return `<tr><th scope="row">${label}</th><td>${p.value}</td></tr>`;
  }
  if (p.effect === 'ability_modifier') {
    let note = '';
    if (p.mode === 'capped') note = p.modifier > p.cap ? `${fmt(p.modifier)} limited to a maximum of +${p.cap}` : `maximum +${p.cap}`;
    if (p.mode === 'none') note = `${fmt(p.modifier)} not applied (heavy armor)`;
    return `<tr><th scope="row">Dexterity modifier${note ? ` <span class="muted small">(${esc(note)})</span>` : ''}</th><td>${fmt(p.value)}</td></tr>`;
  }
  const label = p.source_type === 'shield' ? itemButton(p.source_id, p.source_name) : itemButton(p.source_id, p.source_name);
  return `<tr><th scope="row">${label}</th><td>${fmt(p.value)}</td></tr>`;
}

/** The AC breakdown dialog. onOverride(value|null) saves characters.ac_override; onGotoItem(id) opens the item. */
export function openAcBreakdown(d, { onOverride, onGotoItem }) {
  const ac = d.armor_class;
  const warnings = armorWarnings(d);
  const inactive = ac.inactive_effects || [];
  const legacyDiffers = ac.legacy_stored != null && ac.legacy_stored !== ac.calculated && ac.override == null;
  const m = openModal({
    title: 'Armor Class',
    body: `
      <p class="ac-headline"><span class="ac-big">${ac.value}</span>
        ${ac.source === 'override'
          ? `<span>Manual override. The calculated AC from equipment is <strong>${ac.calculated}</strong>.</span>`
          : `<span>${esc(FORMULA[ac.base_formula] || ac.base_formula)}, calculated from equipment.</span>`}</p>
      <table class="ac-table">
        <caption class="sr-only">How the calculated Armor Class is made up</caption>
        <tbody>${ac.breakdown.map(breakdownRow).join('')}</tbody>
        <tfoot><tr><th scope="row">Calculated AC</th><td>${ac.calculated}</td></tr></tfoot>
      </table>
      ${(ac.alternatives || []).map((a) => `<p class="muted small">Without armor your AC would be ${a.value}.</p>`).join('')}
      ${inactive.length ? `<p class="small"><strong>Not counted:</strong> ${inactive.map((e) =>
        `${itemButton(e.source_id, e.source_name)} (${esc(INACTIVE[e.inactive_reason] || e.inactive_reason)})`).join(', ')}</p>` : ''}
      ${warnings.length ? `
        <section class="derived-warnings" aria-label="Armor warnings">
          <h3>Armor warnings</h3>
          <ul>${warnings.map((w) => `<li><strong>Warning:</strong> ${esc(warningText(w))}</li>`).join('')}</ul>
        </section>` : ''}
      <section class="ac-override">
        <h3>Manual override</h3>
        <p class="muted small">Only for AC sources the app doesn’t calculate yet (e.g. Unarmored Defense, natural armor).
          While set, it replaces the calculated value.</p>
        <form class="row gap" data-form="ac-override">
          <label class="field"><span>Override AC</span>
            <input type="number" name="override" min="0" max="50" inputmode="numeric" value="${ac.override ?? ''}"></label>
          <button type="submit" class="btn btn-sm">Save override</button>
          ${ac.override != null ? '<button type="button" class="btn btn-sm btn-ghost" data-clear-override>Use calculated AC</button>' : ''}
        </form>
        ${legacyDiffers ? `<p class="small">Previously entered AC on this sheet: <strong>${ac.legacy_stored}</strong> (no longer used).
          <button type="button" class="btn-link" data-use-legacy>Use ${ac.legacy_stored} as override</button></p>` : ''}
      </section>`,
    footer: '<button type="button" class="btn btn-gold" data-close>Close</button>',
  });
  m.el.addEventListener('click', (e) => {
    const go = e.target.closest('[data-goto-item]');
    if (go) { m.close(); onGotoItem(go.dataset.gotoItem); return; }
    if (e.target.closest('[data-clear-override]')) { onOverride(null); m.close(); }
    if (e.target.closest('[data-use-legacy]')) { onOverride(ac.legacy_stored); m.close(); }
  });
  $('[data-form="ac-override"]', m.el).addEventListener('submit', (e) => {
    e.preventDefault();
    const raw = e.target.elements.override.value.trim();
    const v = raw === '' ? null : Number(raw);
    if (v != null && (!Number.isInteger(v) || v < 0 || v > 50)) { toast('Enter a whole number from 0 to 50.', 'bad'); return; }
    onOverride(v);
    m.close();
  });
  return m;
}

const openDetails = new Set();   // weapon cards whose "How this is calculated" is open, kept across re-renders

/** Natural weapons from the lineage (claws, horns, bite …): unarmed strikes with Strength, always proficient. */
function naturalWeaponsHTML(d) {
  return (d?.natural_weapons || []).map((w) => `
    <article class="entry derived-weapon natural-weapon" data-natural-weapon="${esc(w.name)}">
      <div class="entry-head">
        <h3 class="entry-name">${esc(w.name)}</h3>
        <span class="badge">Lineage</span>
      </div>
      <div class="roll-row">
        <div class="roll roll-hit"><span class="roll-label">To hit</span><span class="roll-val" data-attack-bonus>${fmt(w.attack_bonus)}</span></div>
        <div class="roll roll-dmg dt-${esc(w.damage_type || '')}">
          <span class="roll-label">Damage</span>
          <span class="roll-val">${esc(w.damage)}</span>
          <span class="roll-type">${esc(w.damage_type || '')}</span>
        </div>
      </div>
      <p class="muted small">Unarmed strike from ${esc(w.source_name)}: Strength ${fmt(w.ability_modifier)} + proficiency ${fmt(w.proficiency_bonus)}.</p>
      ${w.attack_disadvantage ? '<p class="derived-note"><strong>Note:</strong> Disadvantage on this attack: you wear armor or a shield you aren’t proficient with.</p>' : ''}
    </article>`).join('');
}

/**
 * Cards for equipped weapons (js/weapon-card.js). opts.info(inventoryItemId) -> what the viewer knows about the item (masked
 * inventory data) or null; opts.infused: Map of Artificer infusions. An equipped item in a hand that the player cannot see in the
 * catalog (unidentified) gets a card with its decoy only.
 */
export function equippedWeaponsHTML(d, opts = {}) {
  const list = d?.equipped_weapon_attacks || [];
  const natural = naturalWeaponsHTML(d);
  const hidden = (d?.warnings || []).filter((w) => w.code === 'hidden_item' && SLOT[w.slot_id] && w.source_id);
  if (!list.length && !hidden.length) return natural || '<p class="empty">No weapon equipped. Equip one in the Inventory tab.</p>';
  return list.map((w) => weaponCardHTML(w, opts.info?.(w.inventory_item_id) || null, { open: openDetails, infused: opts.infused, resource: opts.resource, editable: opts.editable }))
    .concat(hidden.map((h) => unknownWeaponCardHTML(h.source_id, h.slot_id, opts.info?.(h.source_id) || null))).join('') + natural;
}

export function trackWeaponDetails(container) {
  container.addEventListener('toggle', (e) => {
    const k = e.target.dataset?.details;
    if (!k) return;
    if (e.target.open) openDetails.add(k); else openDetails.delete(k);
  }, true);
}

/** Owned tools, informational only. */
export function toolsHTML(d) {
  const tools = d?.tools || [];
  if (!tools.length) return '';
  return `<p class="small"><strong>Tools you carry:</strong> ${tools.map((t) =>
    `${esc(t.name)} <span class="muted">(${t.proficient ? 'proficient' : 'not proficient'})</span>`).join(', ')}.
    <span class="muted">Tool proficiency is informational; the DM handles tool checks.</span></p>`;
}

const TYPE_LABEL = { weapon: 'Weapon', armor: 'Armor', shield: 'Shield', tool: 'Tool' };

/** Specific (item) proficiencies as a list with remove buttons. */
export function specificProficienciesHTML(d, { editable = true } = {}) {
  const items = (d?.proficiencies || []).filter((p) => p.item_id);
  if (!items.length) return '<p class="muted small">No specific weapon, armor or tool proficiencies.</p>';
  return `<ul class="prof-items">${items.map((p) => `
    <li><span>${esc(p.name)} <span class="muted small">${TYPE_LABEL[p.proficiency_type] || ''}</span></span>
      ${editable && ['manual', 'sheet', 'import'].includes(p.source_type)
        ? `<button type="button" class="btn btn-sm btn-ghost" data-remove-prof="${esc(p.item_id)}" aria-label="Remove ${esc(p.name)}">Remove</button>`
        : `<span class="muted small">${p.source_type === 'lineage' ? 'from your lineage' : p.source_type === 'class' ? `from ${esc((p.notes || 'your class').split(': ')[0])}` : `from ${esc(p.source_type)}`}</span>`}</li>`).join('')}</ul>`;
}

/** Dialog: specific weapon / armor / tool proficiencies with search. Groups stay on the Abilities tab chips. */
export function openProficiencyManager(characterId, getDerived, onChanged) {
  const m = openModal({
    title: 'Specific proficiencies',
    body: `
      <p class="muted small">Groups (Simple Weapons, Light Armor …) are the chips on the Abilities tab. Add single weapons, armor or tools here,
        e.g. a Longsword or Thieves’ Tools. Missing proficiency never stops you from equipping or using an item.</p>
      <div data-list>${specificProficienciesHTML(getDerived())}</div>
      <form class="stack mt" data-form="prof-search">
        <div class="form-grid">
          <label class="field"><span>Type</span>
            <select name="kind"><option value="weapon">Weapon</option><option value="armor">Armor or shield</option><option value="tool">Tool or kit</option></select></label>
          <label class="field"><span>Search</span><input name="q" type="search" placeholder="e.g. longsword" autocomplete="off"></label>
        </div>
        <div data-results class="prof-results" aria-live="polite"></div>
      </form>`,
    footer: '<button type="button" class="btn btn-gold" data-close>Done</button>',
  });
  const form = $('[data-form="prof-search"]', m.el);
  const results = $('[data-results]', m.el);
  let seq = 0;
  async function search() {
    const my = ++seq;
    results.innerHTML = '<p class="muted small">Searching…</p>';
    try {
      const rows = await api.searchProficiencyItems(form.elements.kind.value, form.elements.q.value.trim());
      if (my !== seq) return;
      results.innerHTML = rows.length
        ? `<ul class="prof-items">${rows.map((r) => `<li><span>${esc(r.name)}</span>
            <button type="button" class="btn btn-sm" data-add-prof="${esc(r.id)}">Add</button></li>`).join('')}</ul>`
        : '<p class="muted small">Nothing found.</p>';
    } catch (err) { if (my === seq) results.innerHTML = `<p class="muted small">${esc(err.message)}</p>`; }
  }
  let t;
  form.addEventListener('input', () => { clearTimeout(t); t = setTimeout(search, 250); });
  form.addEventListener('submit', (e) => { e.preventDefault(); search(); });
  m.el.addEventListener('click', async (e) => {
    const add = e.target.closest('[data-add-prof]');
    const rem = e.target.closest('[data-remove-prof]');
    if (!add && !rem) return;
    const btn = add || rem;
    btn.disabled = true;
    try {
      await api.setCharacterProficiency(characterId, { item: (add || rem).dataset[add ? 'addProf' : 'removeProf'], enabled: !!add });
      await onChanged();
      $('[data-list]', m.el).innerHTML = specificProficienciesHTML(getDerived());
      toast(add ? 'Proficiency added.' : 'Proficiency removed.', 'good');
      if (rem) $('input[name=q]', m.el).focus();
    } catch (err) {
      toast(err.message, 'bad');
    } finally { btn.disabled = false; }
  });
  search();
  return m;
}

