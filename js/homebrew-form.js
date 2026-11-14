// Homebrew item form: create, edit and "convert a legacy item". Progressive: basic fields, a section for the chosen
// type, and an Advanced section. Validation here is only UX; the database RPCs are authoritative.
import * as api from './inventory-api.js?v=35';
import { $, $$, esc, openModal, confirmDialog } from './utils.js?v=35';
import { icon } from './icons.js?v=35';
import { iconPickerHTML } from './item-icon-gallery.js?v=35';

const KINDS = ['weapon', 'armor', 'gear', 'tool', 'ammunition', 'potion', 'scroll', 'magic_item', 'herbs_plants'];
const PLANT_PROPS = [['alchemical', 'Alchemical'], ['medicinal', 'Medicinal'], ['poisonous', 'Poisonous'], ['edible', 'Edible']];
const USE_ACTIONS = [['', '—'], ['action', 'Action'], ['bonus_action', 'Bonus action'], ['reaction', 'Reaction'], ['minute', '1 minute or more'], ['special', 'Special']];
const listText = (a) => (Array.isArray(a) ? a.join(', ') : '');
const listOf = (v) => String(v || '').split(',').map((x) => x.trim()).filter(Boolean);
const DICE = /^([1-9][0-9]?d(4|6|8|10|12|20|100)([+-][0-9]{1,3})?|[0-9]{1,3})$/;
const EFFECT_DICE = /^[1-9][0-9]?d[0-9]{1,3}$/;
const VIS_LABEL = { official: 'Official', private: 'My homebrew', campaign: 'Campaign homebrew' };

const num = (v) => (String(v ?? '').trim() === '' ? null : Number(v));
const opt = (list, sel, label = (x) => x.name) => list.map((x) => `<option value="${esc(x.id)}" ${x.id === sel ? 'selected' : ''}>${esc(label(x))}</option>`).join('');

/**
 * openHomebrewForm({ mode: 'create'|'edit'|'convert', lookups, campaigns: [{id, name}], defaults: {campaignId, allowPrivate},
 *                    initial: { item, container, effect }, usageCount, onSubmit(definition, stats, requestId) => Promise })
 * onSubmit is called with the same requestId for every retry of this form (idempotent create/convert).
 */
export function openHomebrewForm(o) {
  const L = o.lookups;
  const it = o.initial?.item || {};
  const cont = o.initial?.container || null;
  const fx = o.initial?.effect || null;
  const det = it.details || {};
  const requestId = (crypto.randomUUID && crypto.randomUUID()) || fallbackUuid();
  const edit = o.mode === 'edit';
  const canChangeVisibility = !edit || it.is_mine;
  let duplicateConfirmed = edit;
  let busy = false;
  let touched = false;
  const campaignId = edit ? it.campaign_id : (o.defaults?.campaignId || '');
  const visibility = campaignId ? 'campaign' : 'private';
  const kinds = L.kinds.filter((k) => KINDS.includes(k.id));
  const title = { create: 'Create a homebrew item', edit: `Edit homebrew definition: ${it.name || ''}`, convert: 'Convert the legacy item to homebrew' }[o.mode];
  const fid = (n) => `hb-${n}`;
  const field = (name, label, control, hint = '') => `
    <label class="field" for="${fid(name)}"><span>${label}</span>${control}
      ${hint ? `<small class="muted" id="${fid(name)}-hint">${hint}</small>` : ''}
      <small class="hb-error" id="${fid(name)}-err" role="alert" hidden></small></label>`;
  const input = (name, type, value, extra = '') =>
    `<input id="${fid(name)}" name="${name}" type="${type}" value="${esc(value ?? '')}" aria-describedby="${fid(name)}-err" ${extra}>`;

  const m = openModal({
    title,
    wide: true,
    body: `
      <form class="hb-form" novalidate>
        ${o.mode === 'edit' && o.usageCount > 0 ? `<p class="inv-note warn" role="note">This definition is used by ${o.usageCount} inventory ${o.usageCount === 1 ? 'entry' : 'entries'}; your changes will affect all of them.</p>` : ''}
        ${o.mode === 'convert' ? '<p class="muted small">The legacy item becomes a homebrew item and its entry is linked to it. The original values are kept in the audit record; a description or weight that differs is kept in the entry’s personal notes.</p>' : ''}
        <div class="hb-error-summary inv-note warn" role="alert" hidden></div>
        <fieldset class="hb-section"><legend>Basics</legend>
          ${field('name', 'Name', input('name', 'text', it.name, 'required maxlength="120" autocomplete="off"'))}
          <div class="hb-row">
            ${field('kind_id', 'Type', `<select id="${fid('kind_id')}" name="kind_id" ${edit ? 'disabled' : ''} aria-describedby="${fid('kind_id')}-err">${opt(kinds, it.kind_id || 'gear')}</select>`,
              edit ? 'The type cannot change after creation.' : '')}
            ${field('category_id', 'Category', `<select id="${fid('category_id')}" name="category_id" aria-describedby="${fid('category_id')}-err"></select>`)}
          </div>
          ${field('description', 'Description', `<textarea id="${fid('description')}" name="description" rows="3" maxlength="4000" aria-describedby="${fid('description')}-err">${esc(it.description || '')}</textarea>`)}
          <div class="hb-row">
            ${field('weight_lb', 'Weight (lb) <small class="us-unit-note">US units</small>', input('weight_lb', 'number', it.weight_lb, 'min="0" step="0.01" inputmode="decimal"'))}
            ${field('cost_value', 'Cost', input('cost_value', 'number', it.cost_value, 'min="0" step="0.01" inputmode="decimal"'))}
            ${field('cost_unit', 'Coin', `<select id="${fid('cost_unit')}" name="cost_unit"><option value="">—</option>${opt(L.currencies, it.cost_unit || 'gp', (c) => c.id)}</select>`)}
          </div>
          <div class="hb-visibility" role="radiogroup" aria-label="Who can see this item">
            <span class="field-label">Visibility</span>
            <label><input type="radio" name="visibility" value="private" ${visibility === 'private' ? 'checked' : ''} ${canChangeVisibility && o.defaults?.allowPrivate !== false ? '' : 'disabled'}> ${icon('ui.locked', { size: 16 })}Private — only you</label>
            <label><input type="radio" name="visibility" value="campaign" ${visibility === 'campaign' ? 'checked' : ''} ${canChangeVisibility && o.campaigns.length ? '' : 'disabled'}> ${icon('dm.campaign', { size: 16 })}Campaign — all members</label>
            <select name="campaign_id" aria-label="Campaign" ${canChangeVisibility ? '' : 'disabled'}>${opt(o.campaigns, campaignId)}</select>
            ${canChangeVisibility ? '' : '<small class="muted">Only the author can change who can see this item.</small>'}
            <small class="hb-error" id="${fid('visibility')}-err" role="alert" hidden></small>
          </div>
        </fieldset>
        <fieldset class="hb-section" data-for="weapon"><legend>Weapon</legend>
          <div class="hb-row">
            ${field('weapon_group', 'Weapon group', `<select id="${fid('weapon_group')}" name="weapon_group"><option value="simple">Simple</option><option value="martial">Martial</option><option value="firearm">Firearm</option></select>`)}
            ${field('damage_dice', 'Damage dice (required)', input('damage_dice', 'text', it.damage_dice, 'placeholder="1d8" maxlength="12" aria-required="true"'))}
            ${field('damage_type_id', 'Damage type', `<select id="${fid('damage_type_id')}" name="damage_type_id"><option value="">—</option>${opt(L.damageTypes, it.damage_type_id)}</select>`)}
          </div>
          <div class="hb-checks" role="group" aria-label="Weapon properties">
            ${L.weaponProperties.map((p) => `<label><input type="checkbox" name="prop" value="${esc(p.id)}" ${(it.weapon_properties || []).includes(p.id) ? 'checked' : ''}> ${esc(p.name)}</label>`).join('')}
          </div>
          <div class="hb-row">
            ${field('versatile_damage', 'Versatile damage', input('versatile_damage', 'text', it.versatile_damage, 'placeholder="1d10" maxlength="12"'), 'Needs the Versatile property.')}
            ${field('range_normal', 'Normal range (ft)', input('range_normal', 'number', it.range_normal, 'min="1" step="1"'))}
            ${field('range_max', 'Maximum range (ft)', input('range_max', 'number', it.range_max, 'min="1" step="1"'))}
          </div>
          <div class="hb-row">
            ${field('ammo_type_id', 'Ammunition type', `<select id="${fid('ammo_type_id')}" name="ammo_type_id"><option value="">—</option>${opt(L.ammoTypes, it.weapon_ammo_type_id)}</select>`, 'Needs the Ammunition property.')}
            <span data-firearm>${field('reload', 'Reload', input('reload', 'number', it.reload, 'min="1" max="50" step="1"'))}</span>
            <span data-firearm>${field('misfire', 'Misfire', input('misfire', 'number', it.misfire, 'min="1" max="20" step="1"'))}</span>
          </div>
        </fieldset>
        <fieldset class="hb-section" data-for="armor"><legend>Armor</legend>
          <div class="hb-row">
            <span data-armor="body">${field('base_ac', 'Base AC', input('base_ac', 'number', it.base_ac, 'min="1" max="30" step="1"'))}</span>
            <span data-armor="shield">${field('ac_bonus', 'AC bonus (shield)', input('ac_bonus', 'number', it.ac_bonus ?? 2, 'min="0" max="10" step="1"'))}</span>
            <span data-armor="body">${field('dex_modifier_mode', 'Dexterity modifier', `<select id="${fid('dex_modifier_mode')}" name="dex_modifier_mode"><option value="full">Full</option><option value="capped">Capped</option><option value="none">None</option></select>`)}</span>
            <span data-armor="capped">${field('dex_cap', 'Dexterity cap', input('dex_cap', 'number', it.dex_cap ?? 2, 'min="0" max="10" step="1"'))}</span>
          </div>
          <div class="hb-row">
            ${field('strength_requirement', 'Strength requirement', input('strength_requirement', 'number', it.strength_requirement, 'min="1" max="30" step="1"'))}
            <label class="hb-inline"><input type="checkbox" name="stealth_disadvantage" ${it.stealth_disadvantage ? 'checked' : ''}> Stealth disadvantage</label>
          </div>
        </fieldset>
        <fieldset class="hb-section" data-for="ammunition"><legend>Ammunition</legend>
          <div class="hb-row">
            ${field('ammunition_type', 'Ammunition type', `<select id="${fid('ammunition_type')}" name="ammunition_type"><option value="">—</option>${opt(L.ammoTypes, it.ammo_type_id)}</select>`)}
            ${field('pack_size', 'Pieces per pack', input('pack_size', 'number', it.pack_size ?? 1, 'min="1" max="1000" step="1"'))}
          </div>
        </fieldset>
        <fieldset class="hb-section hb-details" data-for="herbs_plants"><legend>Herbs &amp; Plants (all optional)</legend>
          <div class="hb-row">
            ${field('environment', 'Environment', input('environment', 'text', det.environment, 'maxlength="120" placeholder="Damp forest floor"'))}
            ${field('region', 'Region', input('region', 'text', det.region, 'maxlength="120"'))}
            ${field('shelf_life', 'Shelf life', input('shelf_life', 'text', det.shelf_life, 'maxlength="200" placeholder="About a month once picked"'))}
          </div>
          <div class="hb-checks" role="group" aria-label="Plant properties">
            ${PLANT_PROPS.map(([k, l]) => `<label><input type="checkbox" name="plant_prop" value="${k}" ${(det.properties || []).includes(k) ? 'checked' : ''}> ${l}</label>`).join('')}
          </div>
          ${field('harvesting', 'Harvesting notes', `<textarea id="${fid('harvesting')}" name="harvesting" rows="2" maxlength="1000">${esc(det.harvesting || '')}</textarea>`)}
          <p class="muted small">A herb needs only a name. Nothing here is automated; a mechanical use belongs in "Use effect" (mark it consumable).</p>
        </fieldset>
        <fieldset class="hb-section hb-details" data-for="potion"><legend>Potion details (all optional)</legend>
          <div class="hb-row">
            ${field('doses', 'Doses', input('doses', 'number', det.doses, 'min="1" max="100" step="1"'))}
            ${field('use_action', 'Use', `<select id="${fid('use_action')}" name="use_action">${USE_ACTIONS.map(([k, l]) => `<option value="${k}" ${det.use_action === k ? 'selected' : ''}>${l}</option>`).join('')}</select>`)}
            ${field('saving_throw', 'Saving throw', input('saving_throw', 'text', det.saving_throw, 'maxlength="60" placeholder="CON DC 12"'))}
            ${field('potion_duration', 'Duration', input('potion_duration', 'text', det.duration, 'maxlength="100"'))}
          </div>
          ${field('effect_text', 'Effect (text)', `<textarea id="${fid('effect_text')}" name="effect_text" rows="2" maxlength="1000">${esc(det.effect_text || '')}</textarea>`, 'A reminder only. A structured healing or damage effect goes in "Use effect".')}
          ${field('ingredients', 'Ingredients (comma separated)', input('ingredients', 'text', listText(det.ingredients), 'maxlength="1200"'))}
        </fieldset>
        <details class="hb-crafting quiet-details" ${det.ingredient_tags || det.recipe_refs || det.preparation ? 'open' : ''}><summary>Crafting notes (for a future crafting system)</summary>
          <div class="hb-row">
            ${field('ingredient_tags', 'Ingredient tags (comma separated)', input('ingredient_tags', 'text', listText(det.ingredient_tags), 'maxlength="500" placeholder="calming, silver"'))}
            ${field('recipe_refs', 'Recipe references (comma separated)', input('recipe_refs', 'text', listText(det.recipe_refs), 'maxlength="1000"'))}
          </div>
          ${field('preparation', 'Preparation notes', `<textarea id="${fid('preparation')}" name="preparation" rows="2" maxlength="1000">${esc(det.preparation || '')}</textarea>`)}
        </details>
        ${iconPickerHTML('icon_key', it.icon_key, { legend: 'Icon' })}
        <fieldset class="hb-section" data-for="effect"><legend>Use effect</legend>
          <div class="hb-row">
            ${field('effect_type', 'Effect', `<select id="${fid('effect_type')}" name="effect_type"><option value="">No automatic effect</option>${['healing', 'damage', 'buff', 'condition', 'cast_spell', 'other'].map((x) => `<option value="${x}" ${fx?.effect_type === x ? 'selected' : ''}>${x.replace('_', ' ')}</option>`).join('')}</select>`)}
            ${field('dice_expression', 'Dice', input('dice_expression', 'text', fx?.dice_expression, 'placeholder="2d4" maxlength="12"'))}
            ${field('flat_value', 'Flat bonus', input('flat_value', 'number', fx?.flat_value, 'step="1"'))}
          </div>
          <div class="hb-row">
            ${field('effect_damage_type', 'Damage type', `<select id="${fid('effect_damage_type')}" name="effect_damage_type"><option value="">—</option>${opt(L.damageTypes, fx?.damage_type_id)}</select>`)}
            ${field('duration', 'Duration', input('duration', 'text', fx?.duration, 'maxlength="100"'))}
            ${field('target_type', 'Target', `<select id="${fid('target_type')}" name="target_type"><option value="">—</option>${['self', 'creature', 'area', 'object'].map((x) => `<option ${fx?.target_type === x ? 'selected' : ''}>${x}</option>`).join('')}</select>`)}
          </div>
        </fieldset>
        <fieldset class="hb-section" data-for="container"><legend>Container</legend>
          <div class="hb-row">
            ${field('capacity_weight_lb', 'Capacity (lb) <small class="us-unit-note">US units</small>', input('capacity_weight_lb', 'number', cont?.capacity_weight_lb, 'min="0" step="0.1"'))}
            ${field('capacity_volume_cuft', 'Capacity (cubic feet)', input('capacity_volume_cuft', 'number', cont?.capacity_volume_cuft, 'min="0" step="0.1"'))}
          </div>
          <div class="hb-checks">
            <label><input type="checkbox" name="weightless_contents" ${cont?.weightless_contents ? 'checked' : ''}> Contents are weightless</label>
            <label><input type="checkbox" name="extradimensional" ${cont?.extradimensional ? 'checked' : ''}> Extradimensional</label>
          </div>
        </fieldset>
        <details class="hb-advanced"><summary>Advanced</summary>
          <div class="hb-row">
            ${field('rarity_id', 'Rarity', `<select id="${fid('rarity_id')}" name="rarity_id"><option value="">—</option>${opt(L.rarities, it.rarity_id)}</select>`, 'Required for magic items.')}
          </div>
          <div class="hb-checks">
            <label><input type="checkbox" name="is_magic" ${it.is_magic ? 'checked' : ''}> Magic item</label>
            <label><input type="checkbox" name="requires_attunement" ${it.requires_attunement ? 'checked' : ''}> Requires attunement</label>
            <label><input type="checkbox" name="is_consumable" ${it.is_consumable ? 'checked' : ''}> Consumable (used up)</label>
            <label><input type="checkbox" name="stackable" ${it.stackable ? 'checked' : ''}> Stackable</label>
            <label><input type="checkbox" name="is_container" ${cont ? 'checked' : ''}> This item is a container</label>
          </div>
        </details>
        <div class="hb-duplicates" role="status" hidden></div>
      </form>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-submit>${edit ? 'Save definition' : o.mode === 'convert' ? 'Convert' : 'Create item'}</button>`,
  });
  const form = $('form', m.el);
  const f = form.elements;
  const submitBtn = $('[data-submit]', m.el);
  if (it.weapon_group) f.weapon_group.value = it.weapon_group;
  if (it.dex_modifier_mode) f.dex_modifier_mode.value = it.dex_modifier_mode;

  function fillCategories() {
    const kind = f.kind_id.value;
    const list = L.categories.filter((c) => c.kind_id === kind);
    const current = f.category_id.value || it.category_id || '';
    f.category_id.innerHTML = `<option value="">${kind === 'armor' ? 'Choose…' : '—'}</option>${opt(list, current)}`;
  }

  function sync() {
    const kind = f.kind_id.value;
    if (['potion', 'scroll'].includes(kind)) { f.is_consumable.checked = true; f.is_consumable.disabled = true; } else f.is_consumable.disabled = false;
    $$('.hb-section[data-for]', form).forEach((s) => {
      const k = s.dataset.for;
      s.hidden = !(k === kind || (k === 'effect' && f.is_consumable.checked) || (k === 'container' && f.is_container.checked));
    });
    const props = $$('input[name="prop"]:checked', form).map((x) => x.value);
    f.versatile_damage.disabled = !props.includes('versatile');
    f.ammo_type_id.disabled = !props.includes('ammunition');
    $$('[data-firearm]', form).forEach((x) => { x.hidden = f.weapon_group.value !== 'firearm'; });
    const shield = f.category_id.value === 'shield';
    $$('[data-armor="body"]', form).forEach((x) => { x.hidden = shield; });
    $$('[data-armor="shield"]', form).forEach((x) => { x.hidden = !shield; });
    $$('[data-armor="capped"]', form).forEach((x) => { x.hidden = shield || f.dex_modifier_mode.value !== 'capped'; });
    f.campaign_id.disabled = !canChangeVisibility || form.querySelector('input[name="visibility"]:checked')?.value !== 'campaign';
  }

  function setError(name, msg) {
    const el = $(`#${fid(name)}-err`, form);
    if (!el) return;
    el.textContent = msg || '';
    el.hidden = !msg;
    const ctl = f[name];
    if (ctl?.setAttribute) ctl.setAttribute('aria-invalid', msg ? 'true' : 'false');
  }

  function collect() {
    const errors = {};
    const kind = f.kind_id.value;
    const name = f.name.value.trim();
    if (!name) errors.name = 'Enter a name.';
    else if (name.length > 120) errors.name = 'At most 120 characters.';
    if (f.description.value.length > 4000) errors.description = 'At most 4000 characters.';
    for (const k of ['weight_lb', 'cost_value']) {
      const v = num(f[k].value);
      if (v != null && (!Number.isFinite(v) || v < 0)) errors[k] = 'Must be a number of at least 0.';
    }
    if (kind === 'armor' && !f.category_id.value) errors.category_id = 'Choose light, medium, heavy armor or shield.';
    if (f.is_magic.checked && !f.rarity_id.value) errors.rarity_id = 'A magic item needs a rarity.';
    const vis = form.querySelector('input[name="visibility"]:checked')?.value || 'private';
    if (vis === 'campaign' && !f.campaign_id.value) errors.visibility = 'Choose a campaign.';
    const def = {
      name, kind_id: kind, category_id: f.category_id.value || null, description: f.description.value.trim() || null,
      weight_lb: num(f.weight_lb.value), cost_value: num(f.cost_value.value), cost_unit: num(f.cost_value.value) == null ? null : (f.cost_unit.value || 'gp'),
      rarity_id: f.rarity_id.value || null, is_magic: f.is_magic.checked, requires_attunement: f.requires_attunement.checked,
      is_consumable: f.is_consumable.checked, stackable: f.stackable.checked,
    };
    if (canChangeVisibility) def.campaign_id = vis === 'campaign' ? f.campaign_id.value : null;
    def.icon_key = form.querySelector('input[name="icon_key"]:checked')?.value || null;
    // details: only the fields of the chosen type are sent (values left in a hidden section never reach the item)
    const details = { ingredient_tags: listOf(f.ingredient_tags.value), recipe_refs: listOf(f.recipe_refs.value), preparation: f.preparation.value.trim() || null };
    if (kind === 'herbs_plants') {
      Object.assign(details, { environment: f.environment.value.trim() || null, region: f.region.value.trim() || null, harvesting: f.harvesting.value.trim() || null,
        shelf_life: f.shelf_life.value.trim() || null, properties: $$('input[name="plant_prop"]:checked', form).map((x) => x.value) });
    }
    if (kind === 'potion') {
      const doses = num(f.doses.value);
      if (doses != null && (!Number.isInteger(doses) || doses < 1 || doses > 100)) errors.doses = 'Doses are a whole number from 1 to 100.';
      Object.assign(details, { doses, use_action: f.use_action.value || null, saving_throw: f.saving_throw.value.trim() || null,
        duration: f.potion_duration.value.trim() || null, effect_text: f.effect_text.value.trim() || null, ingredients: listOf(f.ingredients.value) });
    }
    def.details = Object.fromEntries(Object.entries(details).filter(([, v]) => v != null && !(Array.isArray(v) && !v.length)));
    const stats = {};
    if (kind === 'weapon') {
      const props = $$('input[name="prop"]:checked', form).map((x) => x.value);
      const w = {
        weapon_group: f.weapon_group.value, damage_dice: f.damage_dice.value.trim() || null, damage_type_id: f.damage_type_id.value || null,
        properties: props, versatile_damage: props.includes('versatile') ? f.versatile_damage.value.trim() || null : null,
        range_normal: num(f.range_normal.value), range_max: num(f.range_max.value),
        ammo_type_id: props.includes('ammunition') ? f.ammo_type_id.value || null : null,
      };
      if (w.weapon_group === 'firearm') { w.reload = num(f.reload.value); w.misfire = num(f.misfire.value); }
      if (w.damage_dice && !DICE.test(w.damage_dice)) errors.damage_dice = 'Use a format like 1d8, 2d6+1 or a flat number.';
      if (!w.damage_dice) errors.damage_dice = 'A weapon needs damage dice, for example 1d8.';
      if (w.versatile_damage && !DICE.test(w.versatile_damage)) errors.versatile_damage = 'Use a format like 1d10.';
      if ((w.range_normal == null) !== (w.range_max == null)) errors.range_max = 'Give both ranges or none.';
      else if (w.range_max != null && w.range_max < w.range_normal) errors.range_max = 'Cannot be smaller than the normal range.';
      if (w.weapon_group === 'firearm' && (!w.reload || !w.misfire)) errors.reload = 'A firearm needs reload and misfire.';
      stats.weapon = w;
    }
    if (kind === 'armor') {
      const shield = f.category_id.value === 'shield';
      const a = shield
        ? { ac_bonus: num(f.ac_bonus.value) }
        : { base_ac: num(f.base_ac.value), dex_modifier_mode: f.dex_modifier_mode.value,
            dex_cap: f.dex_modifier_mode.value === 'capped' ? num(f.dex_cap.value) : null };
      a.strength_requirement = num(f.strength_requirement.value);
      a.stealth_disadvantage = f.stealth_disadvantage.checked;
      if (shield && (a.ac_bonus == null || a.ac_bonus < 0 || a.ac_bonus > 10)) errors.ac_bonus = 'A shield needs an AC bonus from 0 to 10.';
      if (!shield && (a.base_ac == null || a.base_ac < 1 || a.base_ac > 30)) errors.base_ac = 'Base AC must be 1–30.';
      stats.armor = a;
    }
    if (kind === 'ammunition') {
      if (!f.ammunition_type.value) errors.ammunition_type = 'Choose the ammunition type.';
      stats.ammunition = { ammo_type_id: f.ammunition_type.value || null, pack_size: num(f.pack_size.value) || 1 };
    }
    if (f.is_consumable.checked && f.effect_type.value) {
      const e = { effect_type: f.effect_type.value, dice_expression: f.dice_expression.value.trim() || null, flat_value: num(f.flat_value.value),
        damage_type_id: f.effect_type.value === 'damage' ? f.effect_damage_type.value || null : null,
        duration: f.duration.value.trim() || null, target_type: f.target_type.value || null };
      if (e.dice_expression && !EFFECT_DICE.test(e.dice_expression)) errors.dice_expression = 'Use a format like 2d4 (the bonus goes into Flat bonus).';
      if (['healing', 'damage'].includes(e.effect_type) && !e.dice_expression && e.flat_value == null) errors.dice_expression = 'Healing and damage need dice or a flat bonus.';
      stats.effect = e;
    }
    if (f.is_container.checked) {
      stats.container = { capacity_weight_lb: num(f.capacity_weight_lb.value), capacity_volume_cuft: num(f.capacity_volume_cuft.value),
        weightless_contents: f.weightless_contents.checked, extradimensional: f.extradimensional.checked };
    }
    return { def, stats, errors };
  }

  function showErrors(errors, serverMessage = '') {
    $$('.hb-error', form).forEach((e) => { e.hidden = true; e.textContent = ''; });
    $$('[aria-invalid]', form).forEach((e) => e.setAttribute('aria-invalid', 'false'));
    Object.entries(errors).forEach(([k, v]) => setError(k, v));
    const summary = $('.hb-error-summary', form);
    const msgs = serverMessage ? [serverMessage] : Object.values(errors);
    summary.hidden = !msgs.length;
    summary.textContent = msgs.length ? (serverMessage || `Please fix ${msgs.length} field${msgs.length > 1 ? 's' : ''}.`) : '';
    const first = Object.keys(errors)[0];
    if (first) {
      if (first.match(/^(rarity_id)$/)) $('.hb-advanced', form).open = true;
      (f[first]?.focus ? f[first] : summary).focus?.();
    }
  }

  async function duplicatesOk(name) {
    if (duplicateConfirmed) return true;
    let similar = [];
    try { similar = await api.findSimilarItems(name); } catch { similar = []; }
    similar = similar.filter((x) => x.id !== it.id);
    if (!similar.length) return true;
    const box = $('.hb-duplicates', form);
    const groups = ['official', 'private', 'campaign'].map((v) => [v, similar.filter((x) => x.visibility === v)]).filter(([, l]) => l.length);
    box.innerHTML = `<p class="inv-note warn">An item with a similar name already exists. You can still create yours.</p>
      ${groups.map(([v, l]) => `<p class="small"><b>${VIS_LABEL[v]}:</b> ${l.map((x) => esc(x.name)).join(', ')}</p>`).join('')}`;
    box.hidden = false;
    duplicateConfirmed = true;
    submitBtn.textContent = o.mode === 'convert' ? 'Convert anyway' : 'Create anyway';
    box.scrollIntoView({ block: 'nearest' });
    return false;
  }

  async function submit() {
    if (busy) return;
    const { def, stats, errors } = collect();
    if (Object.keys(errors).length) { showErrors(errors); return; }
    showErrors({});
    if (!(await duplicatesOk(def.name))) return;
    if (edit && o.usageCount > 1 && !(await confirmDialog(`This definition is used by ${o.usageCount} inventory entries. Change all of them?`, { okLabel: 'Save' }))) return;
    if (o.mode === 'convert' && !(await confirmDialog(`Convert “${def.name}” into a homebrew item and link the legacy entry to it?`, { okLabel: 'Convert' }))) return;
    busy = true;
    submitBtn.disabled = true;
    submitBtn.setAttribute('aria-busy', 'true');
    const label = submitBtn.textContent;
    submitBtn.textContent = 'Saving…';
    try {
      await o.onSubmit(def, stats, requestId);
      m.close();
    } catch (raw) {
      const e = api.normalizeError(raw);
      if (e.kind === 'network' && !edit) {
        // The request may have reached the server. Check before allowing a retry (the retry is idempotent anyway).
        try {
          const found = await api.getCatalogItems([`hb-${requestId}`], { fresh: true });
          if (found.size) { await o.onSubmit(def, stats, requestId); m.close(); return; }
        } catch { /* still offline */ }
      }
      showErrors({}, e.message);
    } finally {
      busy = false;
      submitBtn.disabled = false;
      submitBtn.removeAttribute('aria-busy');
      if (submitBtn.textContent === 'Saving…') submitBtn.textContent = label;
    }
  }

  form.addEventListener('change', (e) => {
    if (e.target.name === 'kind_id') {
      fillCategories();
      if (!touched) { // sensible defaults for the new type until the user sets these flags themselves
        const consumable = ['potion', 'scroll', 'ammunition'].includes(e.target.value);
        f.is_consumable.checked = consumable;
        f.stackable.checked = consumable || e.target.value === 'herbs_plants';
      }
    }
    if (['is_consumable', 'stackable'].includes(e.target.name)) touched = true;
    if (e.target.name === 'name') duplicateConfirmed = edit;
    sync();
  });
  form.addEventListener('input', (e) => { if (e.target.name === 'name' && !edit) { duplicateConfirmed = false; $('.hb-duplicates', form).hidden = true; submitBtn.textContent = o.mode === 'convert' ? 'Convert' : 'Create item'; } });
  form.addEventListener('submit', (e) => { e.preventDefault(); submit(); });
  submitBtn.addEventListener('click', submit);
  fillCategories();
  sync();
  return m;
}

function fallbackUuid() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
