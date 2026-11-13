// Weapon cards in the Actions tab (Play): one card per equipped weapon, in the style of the spell cards (icon, name, tags, the
// two numbers players roll, description). docs/DERIVED_CHARACTER_STATS.md "Weapon cards".
// * The numbers (to hit, damage, the "How this is calculated" breakdown) come only from get_character_derived_stats: nothing is
//   recomputed here.
// * What the card says about the ITEM (name, icon, rarity, magic, attunement, description, modifiers) comes only from the masked
//   inventory data the sheet already has (the Inventory panel's rows + the character's knowledge read, or the raw inventory row):
//   an unidentified or partly identified weapon shows its decoy and the revealed facts only. Nothing is fetched for the card.
// * Three empty slots for release R-D ("Weapon actions", "Special", "Condition") return '' today.
// The hooks of the earlier cards stay: .entry.derived-weapon[data-weapon], [data-attack-bonus], details[data-details] (one <summary>).
import { esc } from './utils.js?v=32';
import { icon, ITEM_ICONS } from './icons.js?v=32';

const fmt = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const cap = (s) => String(s || '').replace(/^\w/, (c) => c.toUpperCase());
const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const SLOT = { main_hand: 'Main hand', off_hand: 'Off hand' };
const DAMAGE_IDS = ['acid', 'bludgeoning', 'cold', 'fire', 'force', 'lightning', 'necrotic', 'piercing', 'poison', 'psychic', 'radiant', 'slashing', 'thunder'];
const PROPERTY = { ammunition: 'Ammunition', explosive: 'Explosive', finesse: 'Finesse', heavy: 'Heavy', light: 'Light', loading: 'Loading',
  reach: 'Reach', special: 'Special', thrown: 'Thrown', 'two-handed': 'Two-handed', versatile: 'Versatile' };
const PROPERTY_HINT = { finesse: 'Use Strength or Dexterity, whichever is better', heavy: 'Small creatures have disadvantage', light: 'Good for fighting with two weapons',
  loading: 'One shot per action, bonus action or reaction', reach: 'Adds 5 feet to your reach', thrown: 'Can be thrown for a ranged attack',
  'two-handed': 'Needs two hands', versatile: 'One or two hands', ammunition: 'Needs ammunition', special: 'See the description' };

/** A distance in feet as text (stored units). The viewer's Metric choice converts it on screen (js/units.js display layer). */
const distance = (ft) => `${ft} ft`;

// ---- future blocks (release R-D: item effects, BG3 style). They render nothing until the data exists. ------------------------
// Each gets the derived weapon and the viewer's item info; it must return '' when there is nothing to show, and must never show
// anything for an item the viewer does not know (info.known === false).
/** "Weapon actions": special attacks the weapon grants (R-D). */
export function weaponActionsHTML(/* w, info */) { return ''; }
/** "Special": passive weapon effects (R-D). */
export function weaponSpecialHTML(/* w, info */) { return ''; }
/** "Condition": conditions a hit can apply (R-D). */
export function weaponConditionHTML(/* w, info */) { return ''; }

const chip = (text, { cls = '', title = '' } = {}) => `<span class="sp-badge wpn-chip ${cls}"${title ? ` title="${esc(title)}"` : ''}>${esc(text)}</span>`;
const dmgChip = (t) => `<span class="dmg-chip" data-dmg="${DAMAGE_IDS.includes(t) ? t : 'none'}"><span class="sp-swatch" aria-hidden="true"></span>${esc(cap(t))}</span>`;

/** The weapon's properties as chips; range and reach as distances. Only facts the derived read already carries. */
function propertyChips(w) {
  const props = w.properties || [];
  const out = [];
  if (w.weapon_group) out.push(chip(`${cap(w.weapon_group)} ${w.is_ranged ? 'ranged' : 'melee'}`, { cls: 'wpn-group' }));
  for (const p of props) {
    if (p === 'versatile') { out.push(chip(w.versatile_damage ? `Versatile (${w.versatile_damage})` : 'Versatile', { title: PROPERTY_HINT[p] })); continue; }
    if (p === 'reach') { out.push(chip(`Reach (${distance(10)})`, { title: PROPERTY_HINT[p] })); continue; }
    out.push(chip(PROPERTY[p] || cap(String(p).replace(/[-_]/g, ' ')), { title: PROPERTY_HINT[p] || '' }));
  }
  if (w.range_normal) {
    const r = w.range_max && w.range_max !== w.range_normal ? `${distance(w.range_normal)} / ${distance(w.range_max)}` : distance(w.range_normal);
    out.push(chip(`Range ${r}`, { cls: 'wpn-range', title: 'Normal / long range (disadvantage beyond normal range)' }));
  }
  return out.join('');
}

/** The tags about the ITEM: what the viewer legitimately knows (info from the masked inventory data). */
function itemChips(info, infused) {
  if (!info) return '';
  const out = [];
  if (info.rarity) out.push(`<span class="badge inv-b-rarity${info.magic ? ' inv-b-magic' : ''} inv-r-${esc(info.rarity)}" data-wpn-rarity="${esc(info.rarity)}">${esc(info.rarityLabel || cap(info.rarity))}</span>`);
  else if (info.magic) out.push(`<span class="badge inv-b-magic">${icon('item.magic', { size: 14 })}Magic</span>`);
  if (info.attunement) out.push(chip(info.attuned ? 'Attuned' : 'Needs attunement', { cls: info.attuned ? 'wpn-attuned' : 'wpn-attune' }));
  if (infused) out.push(`<span class="badge inv-b-magic inv-b-infused">${icon('item.magic', { size: 14 })}Infused: ${esc(infused.label)}</span>`);
  for (const m of info.modifiers || []) out.push(`<span class="badge inv-b-magic">${esc(m)}</span>`);
  if (info.known === false) out.push(chip(info.state === 'partially_identified' ? 'Partly identified' : 'Unidentified', { cls: 'wpn-unknown-chip' }));
  return out.join('');
}

function abilityRule(w) {
  if (w.ability_rule === 'finesse_best') return 'finesse: the better of Strength and Dexterity';
  if (w.ability_rule === 'ranged_dex') return 'ranged weapon';
  return 'melee weapon';
}

/**
 * One card for an equipped weapon. w: an element of derived.equipped_weapon_attacks. info: what the viewer knows about the item
 * (see js/sheet.js weaponInfo) or null. opts: { open: Set of open detail keys, infused: Map inventory item id -> infusion }.
 */
export function weaponCardHTML(w, info, { open = new Set(), infused = null } = {}) {
  const prof = w.proficiency || {};
  const group = prof.group_name || prof.missing_group_name || '';
  const magic = (w.attack_breakdown || []).filter((p) => p.effect === 'attack_bonus');
  const dmgMagic = (w.damage_breakdown || []).filter((p) => p.effect === 'damage_bonus');
  const profLine = w.proficient
    ? `${fmt(w.proficiency_bonus)} <span class="muted small">(proficient${prof.matched_by === 'item' ? ' with this weapon' : group ? `: ${esc(group)}` : ''})</span>`
    : `+0 <span class="muted small">(not proficient${group ? ` with ${esc(group)}` : ''})</span>`;
  const notes = [];
  if (!w.proficient) notes.push(`Not proficient with ${group || 'this weapon'}: no proficiency bonus on the attack roll.`);
  if (w.attack_disadvantage) notes.push('Disadvantage on this attack: you wear armor or a shield you aren’t proficient with.');
  const key = `weapon:${w.inventory_item_id}`;
  const known = info?.known !== false;
  // the name the player sees on their own copy (decoy while unidentified); "Weapon" when no row is loaded
  const name = info?.name || 'Weapon';   // never the derived (catalog) name: it may be the true name of a disguised copy
  const iconName = info?.icon || ITEM_ICONS.weapon;
  const inf = infused?.get?.(w.inventory_item_id) || null;
  const desc = info?.description || '';   // the catalog text when known, the decoy text otherwise (already masked by weaponInfo)
  const rarity = known ? info?.rarity : null;
  return `
    <article class="entry derived-weapon wpn-card" data-weapon="${esc(w.inventory_item_id)}" data-dmg="${esc(w.damage_type || 'none')}"${rarity ? ` data-rarity="${esc(rarity)}"` : ''}>
      <div class="wpn-top">
        ${icon(iconName, { size: 36, cls: 'wpn-icon', src: known ? info?.iconSrc : null })}
        <h3 class="entry-name wpn-title">${esc(name)}</h3>
        <span class="badge wpn-slot" title="Equipped">${esc(SLOT[w.slot_id] || w.slot_id)}</span>
      </div>
      <div class="sp-tags wpn-tags">${w.damage_type ? dmgChip(w.damage_type) : ''}${propertyChips(w)}${itemChips(info, inf)}</div>
      <div class="roll-row">
        <div class="roll roll-hit"><span class="roll-label">To hit</span><span class="roll-val" data-attack-bonus>${fmt(w.attack_bonus)}</span></div>
        <div class="roll roll-dmg dt-${esc(w.damage_type || '')}">
          <span class="roll-label">Damage</span>
          <span class="roll-val">${esc(w.damage ?? '—')}</span>
          <span class="roll-type">${esc(w.damage_type || '')}</span>
        </div>
      </div>
      ${notes.map((n) => `<p class="derived-note"><strong>Note:</strong> ${esc(n)}</p>`).join('')}
      ${desc ? `<p class="wpn-desc small" data-wpn-desc>${esc(desc)}</p>` : ''}
      ${info?.notes ? `<p class="wpn-notes small muted"><strong>Your notes:</strong> ${esc(info.notes)}</p>` : ''}
      ${weaponActionsHTML(w, info)}${weaponSpecialHTML(w, info)}${weaponConditionHTML(w, info)}
      <details data-details="${esc(key)}" ${open.has(key) ? 'open' : ''}>
        <summary data-focus-key="${esc(key)}:details">How this is calculated</summary>
        <table class="ac-table">
          <tbody>
            <tr><th scope="row">${ABILITY[w.ability]} modifier <span class="muted small">(${esc(abilityRule(w))})</span></th><td>${fmt(w.ability_modifier)}</td></tr>
            <tr><th scope="row">Proficiency bonus</th><td>${profLine}</td></tr>
            ${magic.map((p) => `<tr><th scope="row">${esc(p.source_name)}</th><td>${fmt(p.value)}</td></tr>`).join('')}
          </tbody>
          <tfoot><tr><th scope="row">Attack bonus</th><td>${fmt(w.attack_bonus)}</td></tr></tfoot>
        </table>
        <p class="small">Damage: ${esc(w.damage_dice || '—')} ${esc(w.damage_type || '')}
          ${w.versatile_damage ? `(two hands: ${esc(w.versatile_damage)})` : ''}
          + ${ABILITY[w.ability]} ${fmt(w.ability_modifier)}${dmgMagic.map((p) => ` + ${esc(p.source_name)} ${fmt(p.value)}`).join('')}</p>
      </details>
    </article>`;
}

/**
 * An equipped item in a hand whose catalog row the player cannot read (unidentified): only its decoy and what the DM revealed;
 * no numbers (the derived read has none for it). info may be null: then only "an unknown item".
 */
export function unknownWeaponCardHTML(inventoryItemId, slotId, info) {
  return `
    <article class="entry wpn-card wpn-unknown" data-weapon-unknown="${esc(inventoryItemId)}">
      <div class="wpn-top">
        ${icon(info?.icon || 'item.gear', { size: 36, cls: 'wpn-icon' })}
        <h3 class="entry-name wpn-title">${esc(info?.name || 'An unknown item')}</h3>
        <span class="badge wpn-slot" title="Equipped">${esc(SLOT[slotId] || slotId)}</span>
      </div>
      <div class="sp-tags wpn-tags">${itemChips(info ? { ...info, known: false } : { known: false }, null)}</div>
      ${info?.description ? `<p class="wpn-desc small" data-wpn-desc>${esc(info.description)}</p>` : ''}
      <p class="muted small">You don’t know what this item does yet. Your DM tells you what happens when you use it.</p>
    </article>`;
}
