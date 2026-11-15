// Weapon cards in the Actions tab (Play): one card per equipped weapon, in the style of the spell cards (icon, name, tags, the
// two numbers players roll, description). docs/DERIVED_CHARACTER_STATS.md "Weapon cards".
// * The numbers (to hit, damage, the "How this is calculated" breakdown) come only from get_character_derived_stats: nothing is
//   recomputed here.
// * What the card says about the ITEM (name, icon, rarity, magic, attunement, description, modifiers) comes only from the masked
//   inventory data the sheet already has (the Inventory panel's rows + the character's knowledge read, or the raw inventory row):
//   an unidentified or partly identified weapon shows its decoy and the revealed facts only. Nothing is fetched for the card.
// * The blocks "Weapon actions", "Special", "Condition" (R-D2) come from derived weapon_blocks (absent for an unknown copy).
// The hooks of the earlier cards stay: .entry.derived-weapon[data-weapon], [data-attack-bonus], details[data-details] (one <summary>).
// * The icon (js/weapon-icons.js) and the magic bonus tag use only what the viewer may see: a masked copy gets its decoy's icon.
// * The name opens a details dialog (openWeaponDetail), like the name of a spell card: properties explained, range / reach, both
//   damage grips, the item text. No extra read: it shows the same data as the card.
import { esc, openModal } from './utils.js?v=41';
import { icon } from './icons.js?v=41';
import { effectText } from './item-effects.js?v=41';
import { weaponIconKey, weaponIsKnown } from './weapon-icons.js?v=41';

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

// ---- weapon blocks (R-D2, docs/ITEM_EFFECTS.md "Weapon blocks"): "Weapon actions", "Special", "Condition" -------------------------
// The data comes only from the derived read (w.weapon_blocks): the server leaves it out for a copy the viewer does not know, so
// these never show anything for an unidentified / hidden weapon. info.known === false is checked again as a second layer.
// ctx: { resource(key) -> the live counter of get_character_resources (remaining / max) or null, editable }.
const COST = { action: 'Action', bonus_action: 'Bonus action', reaction: 'Reaction' };
const PER = { short_rest: 'short rest', long_rest: 'long rest' };
const ABBR = { str: 'STR', dex: 'DEX', con: 'CON', int: 'INT', wis: 'WIS', cha: 'CHA' };
const blocksOf = (w, info) => (info?.known === false ? null : w?.weapon_blocks || null);
const saveText = (b) => (b.save_dc != null ? `DC ${b.save_dc} ${ABBR[b.save_ability] || ''} save` : '');
const dmgText = (b) => (b.damage ? `${b.damage}${b.damage_type ? ` ${b.damage_type}` : ''}` : '');

function usesHTML(a, ctx) {
  if (!a.uses) return chip('Unlimited', { cls: 'wpn-uses' });
  const per = PER[a.recharge] || 'rest';
  const r = a.resource_key ? ctx?.resource?.(a.resource_key) : null;
  if (!r) return chip(`${a.uses}× per ${per}`, { cls: 'wpn-uses', title: a.available === false ? 'Not available now (needs attunement)' : '' });
  const left = r.remaining ?? a.uses;
  const max = r.max ?? a.uses;
  const buttons = ctx?.editable ? `
      <button type="button" class="btn btn-sm" data-cf-action="res-use" data-key="${esc(r.key)}" data-focus-key="wpn-use:${esc(r.key)}"
        aria-label="Use ${esc(a.name)}" ${!r.active || left <= 0 ? 'disabled' : ''}>Use</button>
      <button type="button" class="btn btn-sm" data-cf-action="res-restore" data-key="${esc(r.key)}" data-focus-key="wpn-restore:${esc(r.key)}"
        aria-label="Restore one use of ${esc(a.name)}" ${!r.expended ? 'disabled' : ''}>Restore</button>` : '';
  return `<span class="wpn-counter cf-res-actions" data-wpn-uses="${esc(r.key)}"><span class="cf-res-count" data-wpn-left>${esc(`${left} / ${max}`)}</span>
      <span class="muted small">per ${esc(per)}</span>${buttons}</span>`;
}

/** "Weapon actions": named actions the wielder can take (cost, roll, damage, uses with Use / Restore for limited ones). */
export function weaponActionsHTML(w, info, ctx = {}) {
  const list = blocksOf(w, info)?.actions || [];
  if (!list.length) return '';
  return `<section class="wpn-block wpn-actions" data-wpn-block="actions"><h4 class="wpn-block-title">Weapon actions</h4>
    ${list.map((a) => {
      const roll = a.roll === 'attack' && a.attack_bonus != null ? `To hit ${fmt(a.attack_bonus)}` : a.roll === 'save' ? saveText(a) : '';
      return `<article class="wpn-act" data-wpn-action="${esc(a.seq)}">
        <div class="wpn-act-head"><strong class="wpn-act-name">${esc(a.name)}</strong>
          ${chip(COST[a.cost] || 'Action', { cls: 'wpn-cost' })}${roll ? chip(roll, { cls: 'wpn-roll' }) : ''}${dmgText(a) ? chip(dmgText(a), { cls: 'wpn-dmg' }) : ''}
          ${a.available === false ? chip('Needs attunement', { cls: 'wpn-attune' }) : ''}</div>
        ${a.description ? `<p class="wpn-desc small">${esc(a.description)}</p>` : ''}
        <div class="wpn-act-uses">${usesHTML(a, ctx)}</div>
      </article>`;
    }).join('')}</section>`;
}

/** "Special": passive effects; a linked item effect is applied automatically by the derived stats (shown, not recomputed). */
export function weaponSpecialHTML(w, info) {
  const list = blocksOf(w, info)?.special || [];
  if (!list.length) return '';
  return `<section class="wpn-block wpn-special" data-wpn-block="special"><h4 class="wpn-block-title">Special</h4>
    ${list.map((x) => `<article class="wpn-act" data-wpn-special="${esc(x.seq)}"><div class="wpn-act-head"><strong class="wpn-act-name">${esc(x.name)}</strong>
      ${x.effect ? (x.effect.active === false
        ? chip(`${effectText(x.effect)} (not active now)`, { cls: 'wpn-auto is-inactive', title: 'Applies automatically once the weapon meets its condition (for example attuned)' })
        : chip(`${effectText(x.effect)} (applied automatically)`, { cls: 'wpn-auto' })) : ''}</div>
      ${x.text ? `<p class="wpn-desc small">${esc(x.text)}</p>` : ''}</article>`).join('')}</section>`;
}

/** "Condition": what a hit or a weapon action applies (a reminder: nothing is applied to targets automatically). */
export function weaponConditionHTML(w, info) {
  const list = blocksOf(w, info)?.conditions || [];
  if (!list.length) return '';
  return `<section class="wpn-block wpn-conditions" data-wpn-block="conditions"><h4 class="wpn-block-title">Condition</h4>
    ${list.map((c) => `<article class="wpn-act" data-wpn-condition="${esc(c.seq)}"><div class="wpn-act-head"><strong class="wpn-act-name">${esc(c.name)}</strong>
      ${chip(c.applies_on === 'action' ? 'By a weapon action' : 'On a hit', { cls: 'wpn-on' })}
      ${saveText(c) ? chip(saveText(c), { cls: 'wpn-roll' }) : ''}
      ${c.duration ? chip(c.duration, { cls: 'wpn-dur' }) : ''}</div>
      ${c.text ? `<p class="wpn-desc small">${esc(c.text)}</p>` : ''}</article>`).join('')}</section>`;
}

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
  if (!w.is_ranged && !props.includes('reach')) out.push(chip(`Reach ${distance(5)}`, { cls: 'wpn-range', title: 'Melee attacks reach targets within this distance' }));
  if (w.range_normal) out.push(chip(`Range ${rangeText(w)}`, { cls: 'wpn-range', title: 'Normal / long range (disadvantage beyond normal range)' }));
  return out.join('');
}
const rangeText = (w) => (w.range_max && w.range_max !== w.range_normal ? `${distance(w.range_normal)} / ${distance(w.range_max)}` : distance(w.range_normal));

/**
 * The weapon's own magic bonus (the parts of the derived breakdown that come from this copy: catalog effects, modifiers such as
 * +1, infusions), already included in To hit / Damage. Only for a copy the viewer knows: a masked copy shows no magic tag.
 */
export function weaponMagicBonus(w, info) {
  if (!weaponIsKnown(w, info)) return null;
  const own = (parts, effect) => (parts || []).filter((p) => p.effect === effect && p.source_id === w.inventory_item_id)
    .reduce((n, p) => n + (Number(p.value) || 0), 0);
  const hit = own(w.attack_breakdown, 'attack_bonus');
  const dmg = own(w.damage_breakdown, 'damage_bonus');
  return hit || dmg ? { hit, dmg } : null;
}
const magicText = (m) => (m.hit === m.dmg ? `Magic ${fmt(m.hit)}` : [m.hit ? `${fmt(m.hit)} to hit` : '', m.dmg ? `${fmt(m.dmg)} damage` : ''].filter(Boolean).join(', '));
const magicChip = (m) => (m ? `<span class="badge inv-b-magic wpn-magic" data-wpn-magic title="This weapon's magic bonus (already in To hit and Damage)">${icon('item.magic', { size: 14 })}${esc(magicText(m))}</span>` : '');

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
 * (see js/sheet.js weaponInfo) or null. opts: { open: Set of open detail keys, infused: Map inventory item id -> infusion,
 *   resource(key): live counter of a limited weapon action, editable: show Use / Restore }.
 */
export function weaponCardHTML(w, info, { open = new Set(), infused = null, resource = null, editable = false } = {}) {
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
  const iconName = weaponIconKey(w, info);   // the decoy's icon for a masked copy (js/weapon-icons.js)
  const inf = infused?.get?.(w.inventory_item_id) || null;
  const desc = info?.description || '';   // the catalog text when known, the decoy text otherwise (already masked by weaponInfo)
  const rarity = known ? info?.rarity : null;
  return `
    <article class="entry derived-weapon wpn-card" data-weapon="${esc(w.inventory_item_id)}" data-dmg="${esc(w.damage_type || 'none')}"${rarity ? ` data-rarity="${esc(rarity)}"` : ''}>
      <div class="wpn-top">
        ${icon(iconName, { size: 36, cls: 'wpn-icon', src: weaponIsKnown(w, info) ? info?.iconSrc : null })}
        <h3 class="entry-name wpn-title"><button type="button" class="btn-link wpn-name" data-action="weapon-detail" data-wpn-id="${esc(w.inventory_item_id)}"
          data-focus-key="${esc(key)}:name" aria-label="${esc(name)}: show details">${esc(name)}</button></h3>
        <span class="badge wpn-slot" title="Equipped">${esc(SLOT[w.slot_id] || w.slot_id)}</span>
      </div>
      <div class="sp-tags wpn-tags">${w.damage_type ? dmgChip(w.damage_type) : ''}${propertyChips(w)}${magicChip(weaponMagicBonus(w, info))}${itemChips(info, inf)}</div>
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
      ${weaponActionsHTML(w, info, { resource, editable })}${weaponSpecialHTML(w, info)}${weaponConditionHTML(w, info)}
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

/**
 * "Expand for details", like a spell card's name: a dialog with the same facts as the card spelled out (each property explained,
 * reach / range, one- and two-handed damage, the ability used, the item text and the player's notes). Uses only w (derived) and
 * info (masked inventory view) the card already has; never reads anything.
 */
export function openWeaponDetail(w, info, { infused = null } = {}) {
  const name = info?.name || 'Weapon';
  const known = info?.known !== false;
  const row = (k, v) => (v ? `<div class="kv"><span>${esc(k)}</span><strong>${v}</strong></div>` : '');
  const props = (w.properties || []).map((p) => `<li><strong>${esc(PROPERTY[p] || cap(String(p).replace(/[-_]/g, ' ')))}</strong>${PROPERTY_HINT[p] ? `: ${esc(PROPERTY_HINT[p])}` : ''}</li>`).join('');
  const kind = `${w.weapon_group ? `${cap(w.weapon_group)} ` : ''}${w.is_ranged ? 'ranged' : 'melee'} weapon`;
  const reach = w.is_ranged ? '' : distance((w.properties || []).includes('reach') ? 10 : 5);
  const desc = info?.description || '';
  return openModal({
    title: name,
    wide: true,
    body: `
      <div class="wpn-detail" data-wpn-detail="${esc(w.inventory_item_id)}">
      <p class="sp-detail-badges">${icon(weaponIconKey(w, info), { size: 28, cls: 'wpn-icon', src: weaponIsKnown(w, info) ? info?.iconSrc : null })}
        ${w.damage_type ? dmgChip(w.damage_type) : ''}${magicChip(weaponMagicBonus(w, info))}${itemChips(info, infused?.get?.(w.inventory_item_id) || null)}</p>
      <div class="kv-list" data-wpn-facts>
        ${row('Type', esc(kind))}
        ${row('To hit', esc(fmt(w.attack_bonus)))}
        ${row('Damage', `${esc(w.damage ?? '—')} ${esc(w.damage_type || '')}`)}
        ${w.versatile_damage ? row('Two-handed', `${esc(w.versatile_damage)} <span class="muted small">(dice, before modifiers)</span>`) : ''}
        ${row('Ability', `${esc(ABILITY[w.ability] || w.ability)} <span class="muted small">(${esc(abilityRule(w))})</span>`)}
        ${row('Reach', esc(reach))}
        ${w.range_normal ? row(w.is_ranged ? 'Range' : 'Thrown range', esc(rangeText(w))) : ''}
        ${row('Proficient', w.proficient ? 'Yes' : 'No')}
        ${row('Slot', esc(SLOT[w.slot_id] || w.slot_id))}
      </div>
      ${props ? `<h4 class="lin-group-title">Properties</h4><ul class="wpn-props small">${props}</ul>` : ''}
      ${desc ? `<h4 class="lin-group-title">Description</h4><p class="wpn-desc small">${esc(desc)}</p>` : ''}
      ${info?.notes ? `<p class="wpn-notes small muted"><strong>Your notes:</strong> ${esc(info.notes)}</p>` : ''}
      ${known ? '' : '<p class="muted small">You haven’t identified this item: only what you know about it is shown.</p>'}
      </div>`,
    footer: '<button type="button" class="btn btn-gold" data-close>Close</button>',
  });
}
