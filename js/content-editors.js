// DM Space content editors (docs/CUSTOM_CONTENT_LIFECYCLE.md and the CUSTOM_*.md pages): one schema-driven form per content
// type, the lifecycle actions (save draft, validate, preview, publish, new version, archive, restore, duplicate, delete) and a
// preview of what players will see. The definition is validated and materialized by the database (_dm_try / _dm_materialize).

import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=28';
import * as dm from './dm-api.js?v=28';
import { icon } from './icons.js?v=28';
import { spellIconHTML } from './spell-icons.js?v=28';
import { iconPickerHTML } from './item-icon-gallery.js?v=28';
import { supabase } from './supabase.js?v=28';
import { CONTENT_MANAGEMENT } from './config.js?v=28';

/** The content management actions (usage report, delete any unused content, duplicate official) are behind js/config.js
 *  CONTENT_MANAGEMENT; 'off' keeps the earlier buttons. The database authorizes every action itself. */
export const contentManagementEnabled = () => (CONTENT_MANAGEMENT || 'off') !== 'off';

export const TYPE = {
  spell: { icon: icon('dm/spell'), label: 'Spell' }, item: { icon: icon('dm/item'), label: 'Item' }, feat: { icon: icon('dm/feat'), label: 'Feat' },
  creature: { icon: icon('dm/creature'), label: 'Creature / Wild Shape form' }, companion: { icon: icon('dm/companion'), label: 'Companion template' },
  background: { icon: icon('dm/background'), label: 'Background' }, lineage: { icon: icon('dm/lineage'), label: 'Lineage' },
  condition: { icon: icon('dm/condition'), label: 'Condition / effect' },
};
export const STATUS = {
  draft: 'Draft', validation_failed: 'Needs fixes', ready_for_review: 'Ready to publish', published: 'Published', revised: 'New version in progress',
  archived: 'Archived', superseded: 'Replaced by a newer version',
};
const ABIL = [['str', 'Strength'], ['dex', 'Dexterity'], ['con', 'Constitution'], ['int', 'Intelligence'], ['wis', 'Wisdom'], ['cha', 'Charisma']];
const opts = (list) => list.map((x) => (Array.isArray(x) ? x : [x, x]));
const CR = ['0', '0.125', '0.25', '0.5', ...Array.from({ length: 20 }, (_, i) => String(i + 1))];
const crLabel = (v) => ({ 0.125: '1/8', 0.25: '1/4', 0.5: '1/2' }[v] || String(v));

// ---- schemas -------------------------------------------------------------------------------------------------------------
const HOMEBREW_KINDS = ['weapon', 'armor', 'tool', 'gear', 'ammunition', 'potion', 'scroll', 'magic_item', 'herbs_plants'];
// item details sent per type (_item_details refuses the fields of another type)
const DETAIL_KEYS = { common: ['ingredient_tags', 'recipe_refs', 'preparation'], herbs_plants: ['environment', 'region', 'harvesting', 'properties', 'shelf_life'],
  potion: ['doses', 'use_action', 'effect_text', 'saving_throw', 'duration', 'ingredients'] };
// field: [path, label, kind, extra]; kind: text | area | num | sel | check | multi | rows
const textFields = [
  ['summary', 'Short summary (players see it in lists)', 'text', { max: 400 }],
  ['player_text', 'Player-facing description', 'area', { max: 4000 }],
  ['dm_notes', 'DM-only notes (never shown to players)', 'area', { max: 4000, dm: true }],
];
function schemaFor(type, ref) {
  const dmg = ref.damageTypes.map((d) => [d.id, d.name]);
  const creature = (p) => [
    { title: 'Creature', fields: [
      [`${p}size`, 'Size', 'sel', { options: opts(['Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gargantuan']) }],
      [`${p}creature_type`, 'Type', 'sel', { options: opts(['beast', 'monstrosity', 'elemental', 'fey', 'plant', 'celestial', 'fiend', 'undead', 'construct', 'dragon', 'aberration', 'ooze', 'giant', 'humanoid']) }],
      [`${p}challenge_rating`, 'Challenge rating', 'sel', { options: CR.map((c) => [c, crLabel(c)]), number: true }],
      [`${p}armor_class`, 'Armor Class', 'num'], [`${p}armor_type`, 'Armor (text)', 'text'],
      [`${p}hit_points`, 'Hit points', 'num'], [`${p}hit_dice`, 'Hit dice (e.g. 2d8+2)', 'text'] ] },
    { title: 'Speed', fields: ['walk', 'climb', 'swim', 'fly', 'burrow'].map((k) => [`${p}speed.${k}`, k[0].toUpperCase() + k.slice(1), 'num']) },
    { title: 'Ability scores', fields: ABIL.map(([k, l]) => [`${p}abilities.${k}`, l, 'num']) },
    { title: 'Senses, skills, defenses', fields: [
      [`${p}senses.darkvision`, 'Darkvision (ft)', 'num'], [`${p}senses.passive_perception`, 'Passive Perception', 'num'],
      [`${p}skills`, 'Skills (e.g. perception:3, stealth:4)', 'text', { map: true }], [`${p}languages`, 'Languages', 'text'],
      [`${p}damage_resistances`, 'Resistances', 'multi', { options: dmg }], [`${p}damage_immunities`, 'Immunities', 'multi', { options: dmg }],
      [`${p}condition_immunities`, 'Condition immunities (comma separated)', 'text', { list: true }] ] },
    { title: 'Traits', fields: [[`${p}traits`, 'Traits', 'rows', { row: [['name', 'Name', 'text'], ['summary', 'What it does', 'text']] }]] },
    { title: 'Actions', fields: [[`${p}actions`, 'Actions', 'rows', { row: [['name', 'Name', 'text'], ['kind', 'Kind', 'sel', { options: opts(['melee', 'ranged', 'other']) }],
      ['attack_bonus', 'To hit', 'num'], ['reach', 'Reach / range (ft)', 'num'], ['damage.0.dice', 'Damage (e.g. 1d6+3)', 'text'],
      ['damage.0.type', 'Damage type', 'sel', { options: [['', '—'], ...dmg] }], ['summary', 'Notes', 'text']] }]] },
  ];
  switch (type) {
    case 'spell': return [
      { title: 'Spell', fields: [['definition.level', 'Level', 'sel', { options: Array.from({ length: 10 }, (_, i) => [String(i), i ? `Level ${i}` : 'Cantrip']), number: true }],
        ['definition.school', 'School', 'sel', { options: [['', 'Choose…'], ...ref.schools.map((s) => [s.id, s.name])] }],
        ['ruleset', 'Rules', 'sel', { options: [['2024', '2024'], ['2014', '2014']] }],
        ['definition.class_lists', 'Class spell lists', 'multi', { options: ref.spellLists.map((l) => [l.id, l.name]) }]] },
      { title: 'Casting', fields: [['definition.casting_time.unit', 'Casting time', 'sel', { options: opts([['action', 'Action'], ['bonus_action', 'Bonus action'], ['reaction', 'Reaction'], ['minute', 'Minute(s)'], ['hour', 'Hour(s)'], ['special', 'Special']]) }],
        ['definition.casting_time.amount', 'Amount', 'num'], ['definition.reaction_trigger', 'Reaction trigger', 'text'],
        ['definition.range.type', 'Range', 'sel', { options: opts([['self', 'Self'], ['touch', 'Touch'], ['distance', 'Distance'], ['sight', 'Sight'], ['unlimited', 'Unlimited'], ['special', 'Special']]) }],
        ['definition.range.distance', 'Distance', 'num'], ['definition.range.unit', 'Unit', 'sel', { options: opts([['feet', 'feet'], ['miles', 'miles']]) }],
        ['definition.area.shape', 'Area', 'sel', { options: [['', 'None'], ...opts(['cone', 'cube', 'sphere', 'line', 'cylinder', 'radius'])] }], ['definition.area.size', 'Area size (ft)', 'num'],
        ['definition.duration.type', 'Duration', 'sel', { options: opts([['instantaneous', 'Instantaneous'], ['timed', 'Timed'], ['until_dispelled', 'Until dispelled'], ['permanent', 'Permanent'], ['special', 'Special']]) }],
        ['definition.duration.amount', 'Duration amount', 'num'], ['definition.duration.unit', 'Duration unit', 'sel', { options: [['', '—'], ...opts(['round', 'minute', 'hour', 'day'])] }],
        ['definition.concentration', 'Concentration', 'check'], ['definition.ritual', 'Ritual', 'check']] },
      { title: 'Components', fields: [['definition.components.v', 'Verbal', 'check'], ['definition.components.s', 'Somatic', 'check'], ['definition.components.m', 'Material', 'check'],
        ['definition.components.material', 'Material', 'text'], ['definition.components.cost_gp', 'Material cost (gp)', 'num'], ['definition.components.consumed', 'Consumed', 'check']] },
      { title: 'Attack or saving throw', fields: [['definition.attack_type', 'Spell attack', 'sel', { options: [['', 'None'], ['melee', 'Melee'], ['ranged', 'Ranged']] }],
        ['definition.save_ability', 'Saving throw', 'sel', { options: [['', 'None'], ...ABIL] }]] },
      { title: 'Effects', fields: [['definition.effects', 'Effects', 'rows', { row: [['category', 'Effect', 'sel', { options: opts([['damage', 'Damage'], ['healing', 'Healing'], ['temp_hp', 'Temporary HP'], ['condition', 'Condition'], ['utility', 'Utility'], ['other', 'Other']]) }],
        ['dice', 'Dice (e.g. 3d6)', 'text'], ['damage_types', 'Damage types', 'multi', { options: dmg }], ['half_on_save', 'Half on a save', 'check'],
        ['scaling.type', 'Scaling', 'sel', { options: opts([['none', 'None'], ['slot_level', 'Per slot level'], ['character_level', 'By character level']]) }], ['scaling.dice', 'Extra dice', 'text']] }],
        ['definition.higher_levels', 'At higher levels', 'area']] },
      { title: 'Text', fields: textFields },
    ];
    case 'item': return [
      // the types a homebrew item can have (_write_homebrew); mounts and vehicles are catalog-only
      { title: 'Item', fields: [['definition.item.kind_id', 'Type', 'sel', { options: ref.itemKinds.filter((k) => HOMEBREW_KINDS.includes(k.id)).map((k) => [k.id, k.name]) }],
        ['definition.item.category_id', 'Category (weapons, armor, herbs)', 'text', { datalist: ['simple-melee', 'simple-ranged', 'martial-melee', 'martial-ranged', 'light-armor', 'medium-armor', 'heavy-armor', 'shield', 'wondrous-item', 'ring', 'wand', 'staff', 'rod',
          'plant-herb', 'plant-flower', 'plant-root', 'plant-fungus', 'plant-seed', 'plant-leaf', 'plant-fruit-berry', 'plant-bark', 'plant-resin', 'plant-material', 'plant-other'] }],
        ['definition.item.rarity_id', 'Rarity', 'sel', { options: [['', '—'], ...ref.rarities.map((r) => [r.id, r.name])] }],
        ['definition.item.is_magic', 'Magical', 'check'], ['definition.item.requires_attunement', 'Requires attunement', 'check'],
        ['definition.item.is_consumable', 'Consumable', 'check'], ['definition.item.stackable', 'Stackable', 'check'],
        ['definition.item.weight_lb', 'Weight (lb)', 'num'], ['definition.item.cost_value', 'Cost', 'num'],
        ['definition.item.cost_unit', 'Cost unit', 'sel', { options: opts(['gp', 'sp', 'cp', 'pp']) }]] },
      { title: 'Weapon', for: 'weapon', fields: [['definition.stats.weapon.weapon_group', 'Weapon group', 'sel', { options: [['', '—'], ['simple', 'Simple'], ['martial', 'Martial']] }],
        ['definition.stats.weapon.damage_dice', 'Damage dice (required)', 'text'], ['definition.stats.weapon.damage_type_id', 'Damage type', 'sel', { options: [['', '—'], ...dmg] }],
        ['definition.stats.weapon.range_normal', 'Range (normal)', 'num'], ['definition.stats.weapon.range_max', 'Range (long)', 'num']] },
      { title: 'Armor', for: 'armor', fields: [['definition.stats.armor.base_ac', 'Base AC (required, except shields)', 'num'], ['definition.stats.armor.ac_bonus', 'AC bonus (shields)', 'num'],
        ['definition.stats.armor.dex_modifier_mode', 'DEX', 'sel', { options: [['', '—'], ['full', 'Full'], ['capped', 'Capped'], ['none', 'None']] }],
        ['definition.stats.armor.dex_cap', 'DEX cap', 'num'], ['definition.stats.armor.strength_requirement', 'STR requirement', 'num'],
        ['definition.stats.armor.stealth_disadvantage', 'Stealth disadvantage', 'check']] },
      { title: 'Ammunition', for: 'ammunition', fields: [['definition.stats.ammunition.ammo_type_id', 'Ammunition type (required)', 'sel', { options: [['', '—'], ...(ref.ammoTypes || []).map((a) => [a.id, a.name])] }],
        ['definition.stats.ammunition.pack_size', 'Pieces per pack', 'num']] },
      { title: 'Herbs & Plants (all optional)', for: 'herbs_plants', fields: [['definition.item.details.environment', 'Environment', 'text', { max: 120 }],
        ['definition.item.details.region', 'Region', 'text', { max: 120 }], ['definition.item.details.shelf_life', 'Shelf life', 'text', { max: 200 }],
        ['definition.item.details.properties', 'Properties', 'multi', { options: [['alchemical', 'Alchemical'], ['medicinal', 'Medicinal'], ['poisonous', 'Poisonous'], ['edible', 'Edible']] }],
        ['definition.item.details.harvesting', 'Harvesting notes', 'area', { max: 1000 }]] },
      { title: 'Potion details (all optional)', for: 'potion', fields: [['definition.item.details.doses', 'Doses', 'num'],
        ['definition.item.details.use_action', 'Use', 'sel', { options: [['', '—'], ['action', 'Action'], ['bonus_action', 'Bonus action'], ['reaction', 'Reaction'], ['minute', '1 minute or more'], ['special', 'Special']] }],
        ['definition.item.details.saving_throw', 'Saving throw', 'text', { max: 60 }], ['definition.item.details.duration', 'Duration', 'text', { max: 100 }],
        ['definition.item.details.effect_text', 'Effect (text, a reminder)', 'area', { max: 1000 }],
        ['definition.item.details.ingredients', 'Ingredients (comma separated)', 'text', { list: true, max: 1200 }]] },
      { title: 'Crafting notes and icon', fields: [['definition.item.details.ingredient_tags', 'Ingredient tags (comma separated)', 'text', { list: true, max: 500 }],
        ['definition.item.details.recipe_refs', 'Recipe references (comma separated)', 'text', { list: true, max: 1000 }],
        ['definition.item.details.preparation', 'Preparation notes', 'area', { max: 1000 }], ['definition.item.icon_key', 'Icon', 'icon']] },
      { title: 'Hidden from players (DM only)', dm: true, fields: [['definition.hidden.unidentified_name', 'Name while unidentified', 'text'],
        ['definition.hidden.unidentified_description', 'Description while unidentified', 'area'], ['definition.hidden.curse', 'Curse (stays secret until you reveal it)', 'area'],
        ['definition.hidden.properties', 'Secret properties (reveal them one by one)', 'rows', { row: [['key', 'Key', 'text'], ['label', 'Name', 'text'], ['text', 'What it does', 'text']] }]] },
      // 20261112000300: players can Examine an unidentified copy with the total of their roll; you confirm unless automatic
      { title: 'Identification by players (DM only)', dm: true, key: 'identify', fields: [['definition.hidden.identify_dc', 'Examine DC (empty: players cannot examine it)', 'num'],
        ['definition.hidden.identify_checks', 'Checks that can identify it (none ticked: any check)', 'multi', { options: [...ref.skills.map((x) => [x.id, x.name]), ...ref.tools.map((x) => [x.id, x.name])] }],
        ['definition.hidden.identify_reveal', 'A success reveals (nothing ticked: everything)', 'multi', { options: [['all', 'Everything (identified)'], ['name', 'The true name'], ['description', 'The description'],
          ['details', 'Herb / potion details'], ['magic', 'That it is magical'], ['rarity', 'Rarity'], ['attunement', 'Attunement'], ['curse', 'The curse']] }],
        ['definition.hidden.identify_auto', 'Reveal at once when the roll meets the DC (no confirmation by you)', 'check'],
        ['definition.hidden.identify_retry', 'Another attempt after a failure', 'sel', { options: [['dm', 'Only when I allow it'], ['once', 'Never (one attempt)'], ['per_long_rest', 'After a long rest'], ['unlimited', 'Any time']] }],
        ['definition.hidden.fail_hint', 'Shown after a failed attempt (may be wrong but plausible)', 'area'],
        ['definition.hidden.kind_face', 'Type shown while unidentified', 'sel', { options: [['', 'Default (Herbs & Plants: shown, others: hidden)'], ['show', 'Show the type'], ['hide', 'Hide the type']] }]] },
      { title: 'Text', fields: textFields },
    ];
    case 'feat': return [
      { title: 'Feat', fields: [['ruleset', 'Rules', 'sel', { options: [['2024', '2024'], ['2014', '2014']] }],
        ['definition.category', 'Category', 'sel', { options: opts([['general', 'General'], ['origin', 'Origin'], ['fighting_style', 'Fighting Style'], ['epic_boon', 'Epic Boon'], ['other', 'Other']]) }],
        ['definition.repeatable', 'Repeatable', 'sel', { options: opts([['once', 'Once'], ['repeatable', 'Repeatable'], ['repeatable_distinct', 'Repeatable with a different choice']]) }],
        ['definition.min_level', 'Minimum level', 'num'], ['definition.prerequisite_text', 'Prerequisite (as text)', 'text']] },
      { title: 'Prerequisites (checked automatically)', fields: [['definition.prerequisites', 'Prerequisites', 'rows', { row: [
        ['kind', 'Kind', 'sel', { options: opts([['character_level', 'Character level'], ['ability', 'Ability score'], ['armor_proficiency', 'Armor training'], ['spellcasting', 'Spellcasting'], ['lineage', 'Lineage'], ['feat', 'Feat'], ['text', 'Other (DM check)']]) }],
        ['target', 'Target (str, medium-armor, elf…)', 'text'], ['value', 'Value', 'text'], ['label', 'Label', 'text']] }]] },
      { title: 'Ability Score Increase', fields: [['asi.from', 'Abilities to choose from', 'multi', { options: ABIL }], ['asi.amount', 'Increase', 'num'], ['asi.max', 'Maximum', 'num']] },
      { title: 'Effects', fields: [['definition.effects', 'Effects', 'rows', { row: [
        ['type', 'Effect', 'sel', { options: opts([['speed_bonus', 'Speed +'], ['ac_bonus', 'AC +'], ['initiative_bonus', 'Initiative +'], ['hp_per_level', 'HP per level'], ['hp_flat', 'HP maximum +'],
          ['ability_bonus', 'Ability +'], ['save_bonus', 'Saving throw +'], ['attack_bonus', 'Attack +'], ['damage_bonus', 'Damage +'], ['resistance', 'Resistance'],
          ['proficiency', 'Proficiency'], ['expertise', 'Expertise'], ['sense', 'Sense'], ['informational', 'Reminder only']]) }],
        ['target', 'Target (str, skill, fire, darkvision…)', 'text'], ['value', 'Value', 'num'], ['value_text', 'Value text (skill id, pb…)', 'text'], ['label', 'Label', 'text']] }]] },
      { title: 'Uses', fields: [['definition.resources', 'Resources', 'rows', { row: [['key', 'Key (a-z, -)', 'text'], ['name', 'Name', 'text'],
        ['max_fixed', 'Uses', 'num'], ['max_pb', 'Proficiency Bonus uses', 'check'], ['recharge', 'Recharge', 'sel', { options: opts([['long_rest', 'Long rest'], ['short_rest', 'Short rest'], ['short_or_long_rest', 'Short or long rest']]) }]] }]] },
      { title: 'Text', fields: textFields },
    ];
    case 'creature': return [...creature('definition.'), { title: 'Use', fields: [['definition.wild_shape_eligible', 'Available for Wild Shape (after your grant)', 'check'],
      ['definition.companion_eligible', 'Can be a companion', 'check']] }, { title: 'Text', fields: textFields }];
    case 'companion': return [...creature('definition.creature.'), { title: 'Template', fields: [['definition.hp_formula.base', 'Base hit points', 'num'],
      ['definition.hp_formula.per_level', 'Extra HP per owner level', 'num'], ['definition.rules', 'Rules (initiative, commands, death)', 'area'],
      ['definition.rest_behavior', 'Rests', 'text']] }, { title: 'Text', fields: textFields }];
    case 'background': return [
      { title: 'Background', fields: [['ruleset', 'Rules', 'sel', { options: [['2024', '2024 (abilities + Origin feat)'], ['2014', 'Legacy (2014)']] }],
        ['definition.abilities', 'Three abilities (2024)', 'multi', { options: ABIL, max: 3 }],
        ['definition.feat', 'Origin feat (2024)', 'sel', { options: [['', '—'], ...ref.originFeats.map((f) => [f.id, `${f.name} (${f.ruleset})`])] }],
        ['definition.feat_parameter', 'Feat option (e.g. Wizard for Magic Initiate)', 'text'],
        ['definition.skills', 'Skills', 'multi', { options: ref.skills.map((s) => [s.id, s.name]) }],
        ['definition.tools', 'Tools', 'multi', { options: ref.tools.map((t) => [t.id, t.name]) }],
        ['definition.languages', 'Languages (legacy)', 'multi', { options: ref.languages.map((l) => [l.id, l.name]) }],
        ['definition.feature.name', 'Feature name (legacy)', 'text'], ['definition.feature.summary', 'Feature summary (legacy)', 'text']] },
      { title: 'Equipment', fields: [['definition.equipment', 'Equipment', 'rows', { row: [['label', 'Item', 'text'], ['item_id', 'Catalog item id (optional)', 'text'], ['quantity', 'Qty', 'num']] }],
        ['definition.gold', 'Or gold instead (GP)', 'num']] },
      { title: 'Text', fields: textFields },
    ];
    case 'lineage': return [
      { title: 'Lineage', fields: [['definition.creature_type', 'Creature type', 'sel', { options: opts(['humanoid', 'fey']) }],
        ['definition.ability_mode', 'Ability Score Increases', 'sel', { options: [['', 'None (2024 style: from the background)'], ['21', '+2 and +1'], ['111', '+1, +1 and +1']] }],
        ['definition.feat_choice', 'Choose a feat', 'check']] },
      { title: 'Traits', fields: [['definition.traits', 'Traits', 'rows', { row: [['name', 'Name', 'text'], ['summary', 'What it does', 'text'],
        ['effect_type', 'Automated part', 'sel', { options: opts([['', 'None (reminder)'], ['speed', 'Speed'], ['sense', 'Sense'], ['resistance', 'Resistance'], ['language', 'Language'], ['proficiency', 'Proficiency'], ['ability_bonus', 'Ability +']]) }],
        ['effect_target', 'Target (walk, darkvision, fire, skill…)', 'text'], ['effect_value', 'Value', 'text']] }]] },
      { title: 'Text', fields: textFields },
    ];
    case 'condition': return [
      { title: 'Condition', fields: [['definition.category', 'Category', 'sel', { options: opts([['curse', 'Curse'], ['disease', 'Disease'], ['blessing', 'Blessing'], ['magical', 'Magical effect'], ['environmental', 'Environmental'], ['other', 'Other']]) }],
        ['definition.duration', 'Duration', 'text'], ['definition.removal', 'How it ends', 'text'],
        ['definition.save.ability', 'Saving throw', 'sel', { options: [['', 'None'], ...ABIL] }], ['definition.save.dc', 'DC', 'num'], ['definition.save.repeat', 'Repeat the save each turn', 'check']] },
      { title: 'Effects', fields: [['definition.effects', 'Effects', 'rows', { row: [['type', 'Effect', 'sel', { options: opts([['ac_bonus', 'AC'], ['speed_bonus', 'Speed'], ['save_bonus', 'Saving throws'],
        ['attack_bonus', 'Attack rolls'], ['check_advantage', 'Advantage on checks'], ['check_disadvantage', 'Disadvantage on checks'], ['save_disadvantage', 'Disadvantage on saves'],
        ['attack_disadvantage', 'Disadvantage on attacks'], ['resistance', 'Resistance'], ['vulnerability', 'Vulnerability'], ['immunity', 'Immunity'],
        ['spellcasting_restriction', 'No spellcasting'], ['action_restriction', 'Action restriction'], ['informational', 'Reminder']]) }],
        ['target', 'Target (str, fire, …)', 'text'], ['value', 'Value', 'num'], ['text', 'Notes', 'text']] }]] },
      { title: 'Text', fields: textFields },
    ];
    default: return [{ title: 'Text', fields: textFields }];
  }
}

// ---- path helpers --------------------------------------------------------------------------------------------------------
const get = (o, path) => path.split('.').reduce((a, k) => (a == null ? undefined : a[k]), o);
function set(o, path, v) {
  const ks = path.split('.');
  let cur = o;
  ks.slice(0, -1).forEach((k, i) => { if (cur[k] == null) cur[k] = /^\d+$/.test(ks[i + 1]) ? [] : {}; cur = cur[k]; });
  cur[ks[ks.length - 1]] = v;
}
const prune = (o) => {
  if (Array.isArray(o)) return o.map(prune).filter((x) => x !== undefined);
  if (o && typeof o === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(o)) { const p = prune(v); if (p !== undefined && p !== '' && !(typeof p === 'object' && !Array.isArray(p) && !Object.keys(p).length)) out[k] = p; }
    return out;
  }
  return o;
};

// ---- form rendering ------------------------------------------------------------------------------------------------------
function fieldHTML([path, label, kind, x = {}], model, prefix = '') {
  const v = get(model, path);
  const id = `ce-${(prefix + path).replace(/[^a-z0-9]/gi, '-')}`;
  const name = prefix + path;
  switch (kind) {
    case 'area': return `<label class="field ${x.dm ? 'dm-only-field' : ''}" for="${id}"><span>${esc(label)}</span><textarea id="${id}" name="${esc(name)}" rows="3" maxlength="${x.max || 4000}">${esc(v ?? '')}</textarea></label>`;
    // measurements are entered in US units (js/units.js converts for display only): say so while the viewer uses Metric
    case 'num': return `<label class="field field-num" for="${id}"><span>${esc(label)}${/weight_lb|\.speed\.|range\.distance|range_normal|range_max|reach/.test(name) ? ' <small class="us-unit-note">US units</small>' : ''}</span><input id="${id}" type="number" step="any" name="${esc(name)}" value="${esc(v ?? '')}" data-num></label>`;
    case 'icon': return iconPickerHTML(name, v, { legend: label });
    case 'check': return `<label class="check-field"><input type="checkbox" name="${esc(name)}" ${v ? 'checked' : ''} data-bool><span>${esc(label)}</span></label>`;
    case 'sel': return `<label class="field" for="${id}"><span>${esc(label)}</span><select id="${id}" name="${esc(name)}" ${x.number ? 'data-num' : ''}>${x.options.map(([ov, ol]) =>
      `<option value="${esc(ov)}" ${String(v ?? '') === String(ov) ? 'selected' : ''}>${esc(ol)}</option>`).join('')}</select></label>`;
    case 'multi': return `<fieldset class="field-multi"><legend>${esc(label)}</legend><div class="multi-opts" ${x.max ? `data-max="${x.max}"` : ''}>${x.options.map(([ov, ol]) =>
      `<label class="check-field"><input type="checkbox" name="${esc(name)}" value="${esc(ov)}" data-multi ${(v || []).includes(ov) ? 'checked' : ''}><span>${esc(ol)}</span></label>`).join('')}</div></fieldset>`;
    case 'rows': {
      const rows = Array.isArray(v) ? v : [];
      return `<div class="ce-rows" data-rows="${esc(name)}" data-row-spec='${esc(JSON.stringify(x.row))}'>
        ${rows.map((r, i) => rowHTML(x.row, r, `${name}.${i}.`)).join('')}
        <button type="button" class="btn btn-sm" data-add-row="${esc(name)}">+ Add ${esc(label.toLowerCase().replace(/s$/, ''))}</button></div>`;
    }
    default: {
      const val = x.map && v && typeof v === 'object' ? Object.entries(v).map(([k, n]) => `${k}:${n}`).join(', ') : x.list && Array.isArray(v) ? v.join(', ') : v ?? '';
      return `<label class="field" for="${id}"><span>${esc(label)}</span><input id="${id}" name="${esc(name)}" value="${esc(val)}" ${x.map ? 'data-map' : ''} ${x.list ? 'data-list' : ''}
        maxlength="${x.max || 300}" ${x.datalist ? `list="${id}-dl"` : ''}>${x.datalist ? `<datalist id="${id}-dl">${x.datalist.map((d) => `<option value="${esc(d)}">`).join('')}</datalist>` : ''}</label>`;
    }
  }
}
const rowHTML = (spec, r, prefix) => `<div class="ce-row">${spec.map((f) => fieldHTML(f, r, prefix)).join('')}
  <button type="button" class="btn btn-xs btn-ghost" data-remove-row aria-label="Remove this row">Remove</button></div>`;

/** Read the form back into {name, summary, player_text, dm_notes, ruleset, definition}. */
function readForm(form, type, base) {
  const model = { definition: {} };
  $$('[name]', form).forEach((el) => {
    const n = el.name;
    if (el.type === 'radio') { if (el.checked) set(model, n, el.value || undefined); return; }   // '' = category default (sent as null below)
    if (el.dataset.multi !== undefined) {
      const cur = get(model, n) || [];
      if (el.checked) cur.push(el.value);
      set(model, n, cur);
    } else if (el.dataset.bool !== undefined) set(model, n, el.checked);
    else if (el.dataset.num !== undefined) set(model, n, el.value === '' ? undefined : Number(el.value));
    else if (el.dataset.map !== undefined) set(model, n, Object.fromEntries(el.value.split(',').map((x) => x.trim().split(':')).filter((p) => p[0]).map(([k, n2]) => [k.trim(), Number(n2)])));
    else if (el.dataset.list !== undefined) set(model, n, el.value.split(',').map((x) => x.trim()).filter(Boolean));
    else set(model, n, el.value);
  });
  const d = prune(model.definition || {}) || {};
  // type-specific shaping into the definition format of _dm_materialize
  if (type === 'item' && d.stats) {
    // only the stats of the chosen type are sent: values left in a hidden Weapon / Armor section never become mechanics
    const kind = d.item?.kind_id;
    if (kind !== 'weapon') delete d.stats.weapon;
    if (kind !== 'armor') delete d.stats.armor;
    if (kind !== 'ammunition') delete d.stats.ammunition;
    if (!Object.keys(d.stats).length) delete d.stats;
  }
  if (type === 'item' && d.item) {
    // details of the chosen type only (values left in a hidden Herbs / Potion section never reach the item); an emptied icon is null
    const kind = d.item.kind_id;
    const keep = [...DETAIL_KEYS.common, ...(DETAIL_KEYS[kind] || [])];
    const det = Object.fromEntries(Object.entries(d.item.details || {}).filter(([k, v]) => keep.includes(k) && v != null && v !== '' && !(Array.isArray(v) && !v.length)));
    if (Object.keys(det).length) d.item.details = det; else delete d.item.details;
    if (!d.item.icon_key) d.item.icon_key = null;
  }
  // the coin select always has a value: without a cost it must not be sent ("Cost needs both an amount and a coin")
  if (type === 'item' && d.item && d.item.cost_value == null) delete d.item.cost_unit;
  if (type === 'feat') {
    const asi = prune(model.asi || {});
    d.choices = (base.definition?.choices || []).filter((c) => c.key !== 'asi');
    if (asi?.from?.length) d.choices.unshift({ key: 'asi', kind: 'ability_increase', label: 'Ability Score Increase', min: 1, max: 1,
      config: { amount: asi.amount || 1, max: asi.max || 20, from: asi.from } });
    d.resources = (d.resources || []).map((r) => ({ key: r.key, name: r.name, recharge: r.recharge || 'long_rest',
      max: r.max_pb ? { terms: [{ of: 'proficiency_bonus' }] } : { fixed: r.max_fixed || 1 } }));
  }
  if (type === 'lineage') {
    d.traits = (d.traits || []).map((t) => ({ name: t.name, summary: t.summary || t.name,
      effects: t.effect_type ? [{ type: t.effect_type, target: t.effect_target, ...(Number.isFinite(Number(t.effect_value)) && t.effect_value !== '' ? { value: Number(t.effect_value) } : { value_text: t.effect_value }) }] : [] }));
    if (d.ability_mode === '21') { d.ability_patterns = [[2, 1]]; d.ability_picks = 2; }
    if (d.ability_mode === '111') { d.ability_patterns = [[1, 1, 1]]; d.ability_picks = 3; }
    delete d.ability_mode;
  }
  if (['creature', 'companion'].includes(type)) {
    const c = type === 'companion' ? d.creature : d;
    if (c?.actions) c.actions = c.actions.map((a) => ({ ...a, targets: 'one target' }));
  }
  return { name: model.name || base.name, summary: model.summary ?? '', player_text: model.player_text ?? '', dm_notes: model.dm_notes ?? '',
           ruleset: model.ruleset || null, definition: d };
}

/** The definition shaped back into the form model (inverse of the shaping in readForm). */
function formModel(type, v) {
  const m = { name: v.name, summary: v.summary, player_text: v.player_text, dm_notes: v.dm_notes, ruleset: v.ruleset || '2024', definition: structuredClone(v.definition || {}) };
  const d = m.definition;
  if (type === 'item' && d.hidden && d.hidden.kind_face == null && typeof d.hidden.show_kind === 'boolean') {
    d.hidden.kind_face = d.hidden.show_kind ? 'show' : 'hide';   // the editor has no show_kind field: keep its meaning on save
  }
  if (type === 'feat') {
    const asi = (d.choices || []).find((c) => c.key === 'asi');
    if (asi) m.asi = { from: asi.config?.from, amount: asi.config?.amount, max: asi.config?.max };
    d.resources = (d.resources || []).map((r) => ({ key: r.key, name: r.name, recharge: r.recharge, max_fixed: r.max?.fixed, max_pb: !!r.max?.terms }));
  }
  if (type === 'lineage') {
    d.traits = (d.traits || []).map((t) => ({ name: t.name, summary: t.summary, effect_type: t.effects?.[0]?.type || '', effect_target: t.effects?.[0]?.target || '',
      effect_value: t.effects?.[0]?.value ?? t.effects?.[0]?.value_text ?? '' }));
    d.ability_mode = d.ability_patterns ? (d.ability_patterns[0]?.length === 3 ? '111' : '21') : '';
  }
  return m;
}

/** The rarity of an item as a named badge (same classes as the inventory), never the raw id. */
function rarityChip(id, magic, ref) {
  const name = id === 'unknown' ? 'Unknown rarity' : ref?.rarities?.find((r) => r.id === id)?.name || String(id).replace(/_/g, ' ');
  return `<span class="badge inv-b-rarity${magic ? ' inv-b-magic' : ''} inv-r-${esc(id)}" title="Rarity: ${esc(name)}">${esc(name)}</span>`;
}

// ---- preview ----------------------------------------------------------------------------------------------------------------
export function previewHTML(type, p, player, ref = null) {
  if (!p) return '<p class="muted">No preview.</p>';
  const head = `<h3>${esc(p.name || player?.name || '')}</h3>${player?.summary ? `<p><em>${esc(player.summary)}</em></p>` : ''}`;
  switch (type) {
    case 'spell': return `<article class="preview-card spell-preview"><div class="spell-preview-head">${spellIconHTML(p, { size: 34 })}${head}</div>
      <p class="small">${esc(p.level === 0 ? 'Cantrip' : `Level ${p.level}`)} ${esc(p.school || '')}${p.ritual ? ' · ritual' : ''}${p.concentration ? ' · concentration' : ''}</p>
      <dl class="mini-dl"><dt>Casting time</dt><dd>${esc(p.casting_time || '')}</dd><dt>Range</dt><dd>${esc(p.range || '')}</dd>
        <dt>Components</dt><dd>${esc(p.components || '')}</dd><dt>Duration</dt><dd>${esc(p.duration || '')}</dd></dl>
      ${(p.effects || []).map((e) => `<p class="small">${esc(e.category || '')}: ${esc(e.dice || '')} ${esc((e.damage_types || []).join(', '))}</p>`).join('')}
      ${player?.player_text ? `<p>${esc(player.player_text)}</p>` : ''}<p class="feat-b feat-b-homebrew">Campaign custom</p></article>`;
    case 'item': return `<article class="preview-card">${head}<p class="small">${esc(p.kind_name || p.kind_id || '')}
      ${p.rarity_id ? rarityChip(p.rarity_id, p.is_magic, ref) : ''}${p.is_magic ? ' · magical' : ''}${p.requires_attunement ? ' · attunement' : ''}</p>${p.description ? `<p>${esc(p.description)}</p>` : ''}
      ${p.damage_dice ? `<p class="small">Damage ${esc(p.damage_dice)} ${esc(p.damage_type_id || '')}</p>` : ''}${p.base_ac ? `<p class="small">AC ${esc(p.base_ac)}</p>` : ''}
      <p class="muted small">Unidentified copies show only the disguise you set; secrets stay with you.</p></article>`;
    case 'feat': return `<article class="preview-card">${head}<p class="small">${esc(p.category || '')} · ${esc(p.ruleset || '')}</p>
      ${p.prerequisite_text ? `<p class="small">Prerequisite: ${esc(p.prerequisite_text)}</p>` : ''}
      <ul class="feat-effects">${(p.effects || []).map((e) => `<li>${esc(e.label || e.effect_type)}</li>`).join('')}</ul></article>`;
    case 'creature': case 'companion': return `<article class="preview-card statblock">${head}
      <p class="small"><em>${esc(p.size)} ${esc(p.creature_type)}</em> · CR ${esc(crLabel(p.challenge_rating))}</p>
      <p class="small"><strong>AC</strong> ${esc(p.armor_class)} · <strong>HP</strong> ${esc(p.hit_points)}${p.hit_dice ? ` (${esc(p.hit_dice)})` : ''} · <strong>Speed</strong> ${esc(Object.entries(p.speed || {}).map(([k, n]) => `${k} ${n} ft`).join(', '))}</p>
      <p class="small">${ABIL.map(([k]) => `<strong>${k.toUpperCase()}</strong> ${esc(p.abilities?.[k] ?? '—')}`).join(' · ')}</p>
      ${(p.traits || []).map((t) => `<p class="small"><strong>${esc(t.name)}.</strong> ${esc(t.summary || '')}</p>`).join('')}
      ${(p.actions || []).map((a) => `<p class="small"><strong>${esc(a.name)}.</strong> ${a.attack_bonus != null ? `+${esc(a.attack_bonus)} to hit` : ''} ${esc((a.damage || []).map((x) => `${x.dice} ${x.type || ''}`).join(', '))} ${esc(a.summary || '')}</p>`).join('')}
      ${type === 'creature' ? '<p class="muted small">As a Wild Shape form it appears in a Druid\'s picker only after you grant it.</p>' : ''}</article>`;
    case 'background': return `<article class="preview-card">${head}<p class="small">${esc(p.ruleset || '')}</p>
      ${(p.ability_options || p.abilities || []).length ? `<p class="small">Abilities: ${esc((p.ability_options || p.abilities).map((a) => a.ability || a).join(', '))}</p>` : ''}
      ${p.feat ? `<p class="small">Origin feat: ${esc(p.feat.name || p.feat.id || p.feat)}</p>` : ''}</article>`;
    case 'lineage': return `<article class="preview-card">${head}${(p.traits || []).map((t) => `<p class="small"><strong>${esc(t.name)}.</strong> ${esc(t.summary)}</p>`).join('')}</article>`;
    default: return `<article class="preview-card">${head}${player?.player_text ? `<p>${esc(player.player_text)}</p>` : ''}</article>`;
  }
}

// ---- usage report and permanent delete (20261109000300) --------------------------------------------------------------------------
const USAGE_LABEL = {
  character_spells: 'characters know or prepare it', character_resources: 'free-cast counters', feat_spell_grants: 'feats grant it',
  class_feature_effects: 'class features grant it', inventory_instances: 'inventory entries', equipped_instances: 'equipped',
  attuned_instances: 'attuned', inventory_history: 'inventory history entries', owned_assets: 'owned assets', background_equipment: 'background equipment',
  proficiencies: 'proficiencies', items_based_on_it: 'items based on it', feat_assignments: 'feat assignments', feat_choices: 'saved feat choices',
  lineage_feat_picks: 'lineage feat picks', class_feat_picks: 'Ability Score Improvement feat picks', backgrounds_granting: 'backgrounds grant it',
  seen_forms: 'Wild Shape forms known', form_favorites: 'form favourites', companions: 'companions', transformations: 'active transformations',
  active_encounter_snapshots: 'running or planned encounters', background_assignments: 'characters with this background',
  background_choices: 'saved background choices', lineage_assignments: 'characters with this lineage', lineage_choices: 'saved lineage choices',
  condition_assignments: 'applied conditions', pending_requests: 'submitted change requests', other_content: 'published content refers to it',
  completed_encounter_snapshots: 'completed encounters (history that blocks delete)', audit_references: 'audit history entries', earlier_assignments: 'earlier assignments (history)',
  request_history: 'draft or outdated change requests (history)', other_content_history: 'archived or draft content mentions it (history)',
  crafting_recipes: 'crafting recipes use it',
};
// history (20261112000100): kept and readable after a delete. Completed encounters are history too, but they still BLOCK the
// delete (a creature in one stays archived), so they are listed under "In use (blocks delete)", not under "History (kept)".
const HISTORY_KEYS = new Set(['inventory_history', 'audit_references', 'earlier_assignments', 'request_history', 'other_content_history']);
export const CLASSIFICATION = {
  safe_to_delete: ['Safe to delete', 'good'], delete_keeps_history: ['Deletable, history kept', 'good'], archive_recommended: ['Archive recommended', 'warn'],
  delete_blocked: ['Delete blocked', 'bad'], new_version_required: ['New version required', 'warn'],
};

function usageHTML(u) {
  const rows = Object.entries(u.counts || {}).filter(([, n]) => Number(n) > 0);
  const cur = rows.filter(([k]) => !HISTORY_KEYS.has(k));
  const hist = rows.filter(([k]) => HISTORY_KEYS.has(k));
  const list = (r, attr) => `<ul class="small ce-usage-list" ${attr}>${r.map(([k, n]) => `<li><strong>${esc(n)}</strong> ${esc(USAGE_LABEL[k] || k.replace(/_/g, ' '))}</li>`).join('')}</ul>`;
  const [label, tone] = CLASSIFICATION[u.classification] || [u.classification, ''];
  return `<p><span class="ce-chip ce-usage-${esc(tone)}" data-usage-class="${esc(u.classification)}">${esc(label)}</span>
      ${u.edit === 'new_version_required' ? `<span class="ce-chip ce-usage-warn" data-usage-edit>${esc(CLASSIFICATION.new_version_required[0])}</span>` : ''}</p>
    <p class="small">${esc(TYPE[u.content_type]?.label || u.content_type)} · version ${esc(u.version_no || 1)} · Campaign custom${u.archived ? ' · archived' : ''}</p>
    <p class="small"><strong>${Number(u.characters) || 0}</strong> character${Number(u.characters) === 1 ? '' : 's'} use it.</p>
    <div data-usage-counts>
      ${cur.length ? `<h4 class="small-h">In use (blocks delete)</h4>${list(cur, 'data-usage-current')}` : ''}
      ${hist.length ? `<h4 class="small-h">History (kept)</h4>${list(hist, 'data-usage-history')}` : ''}
      ${rows.length ? '' : '<p class="small muted">Nothing uses it and nothing refers to it.</p>'}
    </div>
    <p class="small" data-usage-advice>${esc(u.advice || '')}</p>
    <div data-usage-where></div>`;
}

// where it is used (get_dm_content_usage_detail): one line per place, with the next step
const qty = (p) => (p.quantity > 1 ? ` (×${p.quantity})` : '');
const PLACE = {
  character_inventory: (p) => [`${p.character_name}’s inventory${qty(p)}${p.equipped ? ', equipped' : ''}${p.attuned ? ', attuned' : ''}${p.in_container ? ', in a container' : ''}`,
    'Remove it from the inventory (or ask the player to drop it).', p.character_id && `#/c/${p.character_id}`],
  party_stash: (p) => [`Party stash “${p.inventory_name}”${qty(p)}`, 'Remove it from the party stash.'],
  npc_inventory: (p) => [`NPC inventory “${p.inventory_name}”${qty(p)}`, 'Remove it from the NPC inventory.'],
  shop: (p) => [`Shop “${p.inventory_name}”${qty(p)}`, 'Remove it from the shop.'],
  stash: (p) => [`Stash “${p.inventory_name}”${qty(p)}`, 'Remove it from the stash.'],
  character: (p) => [`${p.character_name}: ${p.use}${p.count > 1 ? ` (×${p.count})` : ''}`, 'Remove it from the character.', p.character_id && `#/c/${p.character_id}`],
  request: (p) => [`Change request “${p.title}” by ${p.character_name} (${String(p.status || '').replace(/_/g, ' ')})`, 'Approve, reject or return the request first.',
    p.request_id && `#/dm/approvals/${p.request_id}`],
  encounter: (p) => [`Encounter “${p.encounter_name}” (${p.status})`,
    p.status === 'completed' ? 'The encounter history keeps its stat block, so it stays archived.' : 'Finish the encounter or remove the creature from it.',
    p.encounter_id && `#/combat/e/${p.encounter_id}`],
  other_content: (p) => [`${TYPE[p.content_type]?.label || p.content_type} “${p.content_name}” (published)`, 'Publish a new version without the reference, or archive that content.'],
  crafting_recipe: (p) => [`Crafting recipe “${p.recipe_name}” (${p.recipe_status})`, 'Change the recipe to use another item (DM Space → Crafting).'],
};
function whereHTML(w) {
  const places = w?.places || [];
  if (!places.length && !w?.hidden_places) return '';
  return `<h4 class="small-h">Where it is used</h4><ul class="small ce-usage-list ce-usage-where" data-usage-places>${places.map((p) => {
    const [text, next, href] = (PLACE[p.kind] || ((x) => [x.kind, '']))(p);
    return `<li data-place-kind="${esc(p.kind)}">${href ? `<a href="${esc(href)}">${esc(text)}</a>` : esc(text)}${p.campaign_name ? ` <span class="muted">· ${esc(p.campaign_name)}</span>` : ''}
      ${next ? `<br><span class="muted">${esc(next)}</span>` : ''}</li>`;
  }).join('')}${w.truncated ? `<li class="muted">… and ${esc(w.total_places - places.length)} more</li>` : ''}${
    w.hidden_places ? `<li class="muted">${esc(w.hidden_places)} more in campaigns you do not run</li>` : ''}</ul>`;
}

/** The usage report: what blocks, what is only history, where it is used; Archive as the alternative, Delete when nothing uses it. */
export async function openUsage(content, { onChanged, onDeleted } = {}) {
  let u;
  try { u = await dm.getContentUsage(content.id); } catch (err) { toast(err.message, 'bad'); return; }
  const m = openModal({ title: `Usage: ${u.name}`, body: `<div data-usage>${usageHTML(u)}</div>`,
    footer: `<button type="button" class="btn" data-close>Close</button>
      ${u.can_archive ? '<button type="button" class="btn" data-u="archive">Archive instead</button>' : ''}
      ${u.can_delete ? '<button type="button" class="btn btn-bad" data-u="delete">Delete permanently…</button>' : ''}` });
  // the places (names) arrive after the counts; a failed read only leaves the counts
  dm.getContentUsageDetail(content.id).then((w) => { const box = $('[data-usage-where]', m.el); if (box) box.innerHTML = whereHTML(w); }).catch(() => {});
  m.el.addEventListener('click', async (e) => {
    if (e.target.closest('[data-usage-places] a')) { m.close(); return; }   // following a link leaves the dialog
    const a = e.target.closest('[data-u]')?.dataset.u;
    if (!a) return;
    if (a === 'archive') {
      if (!(await confirmDialog(`Archive “${u.name}”? It can no longer be assigned; everything that has it keeps working.`, { okLabel: 'Archive', danger: true }))) return;
      try { await dm.archiveContent(content.id); toast('Archived.'); m.close(); onChanged?.(); } catch (err) { toast(err.message, 'bad'); }
    }
    if (a === 'delete') { m.close(); if (await deleteContentFlow(u)) onDeleted?.(); }
  });
}

/** Typed-name permanent delete; the server re-checks every dependency in its own transaction. Resolves true when deleted. */
async function deleteContentFlow(u) {
  const kept = u.classification === 'delete_keeps_history';
  const typed = await askName(u.name, { what: TYPE[u.content_type]?.label.toLowerCase() || 'content',
    detail: `${TYPE[u.content_type]?.label || u.content_type} · version ${u.version_no || 1} · Campaign custom. ${kept
      ? 'Nothing uses it now. Its history (inventory events, audit lines, earlier assignments) stays readable under its name.'
      : 'Nothing uses it and nothing refers to it.'}
      Deleting removes the content, all its versions and their catalog entries for good.${u.archived ? '' : ' Archive keeps it readable instead.'}` });
  if (typed == null) return false;
  try {
    await dm.deleteUnusedContent(u.content_id, typed);
    toast(`${u.name} deleted.`);
    return true;
  } catch (err) {
    toast(err.code === 'TLUSE' ? `${err.message} Open its usage to see where it is used.` : err.message, 'bad', 7000);
    return false;
  }
}

// ---- duplicate official content as homebrew -------------------------------------------------------------------------------------
const OFFICIAL = {
  spell: { table: 'spell_versions', label: 'Spell', filter: (q) => q.is('content_version_id', null).eq('status', 'current') },
  item: { table: 'items', label: 'Item', filter: (q) => q.is('owner_id', null) },
  feat: { table: 'feat_versions', label: 'Feat', filter: (q) => q.is('content_version_id', null).is('owner_id', null) },
  creature: { table: 'creatures', label: 'Creature', filter: (q) => q.is('owner_id', null).is('content_version_id', null) },
  background: { table: 'background_versions', label: 'Background', filter: (q) => q.is('content_version_id', null).is('owner_id', null) },
  lineage: { table: 'lineage_versions', label: 'Lineage', filter: (q) => q.is('content_version_id', null).is('owner_id', null) },
};

/** Search an official catalog entry and copy it into a new campaign draft (the official row is never changed). */
export function openDuplicateOfficial({ campaignId, onCreated }) {
  const m = openModal({ title: 'Duplicate official content as homebrew', wide: true,
    body: `<p class="small muted">Official content is never edited or deleted. A duplicate is a new draft of this campaign with its own id; review it,
        validate and publish it like any other content.</p>
      <div class="dm-filters"><label class="field"><span>Type</span><select data-do-type>${Object.entries(OFFICIAL).map(([k, t]) => `<option value="${k}">${esc(t.label)}</option>`).join('')}</select></label>
      <label class="field"><span>Name</span><input type="search" data-do-q placeholder="At least 2 letters" autocomplete="off"></label></div>
      <ul class="dm-content-list" data-do-list aria-live="polite"></ul>`,
    footer: '<button type="button" class="btn" data-close>Close</button>' });
  let seq = 0;
  const search = async () => {
    const my = ++seq;
    const type = $('[data-do-type]', m.el).value;
    const q = $('[data-do-q]', m.el).value.trim();
    const list = $('[data-do-list]', m.el);
    if (q.length < 2) { list.innerHTML = ''; return; }
    const t = OFFICIAL[type];
    const { data, error } = await t.filter(supabase.from(t.table).select('id, name').ilike('name', `%${q.replace(/[%_]/g, '')}%`)).order('name').limit(20);
    if (my !== seq) return;
    list.innerHTML = error ? `<li class="warn small">${esc(error.message)}</li>` : (data || []).length ? data.map((x) => `<li class="dm-content-row">
      <span class="dm-content-name"><strong>${esc(x.name)}</strong><span class="small muted">${esc(x.id)}</span></span>
      <button type="button" class="btn btn-sm" data-do-copy="${esc(x.id)}" data-type="${esc(type)}">Duplicate as homebrew</button></li>`).join('')
      : '<li class="muted small">No official entry matches.</li>';
  };
  let timer = null;
  $('[data-do-q]', m.el).addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(search, 250); });
  $('[data-do-type]', m.el).addEventListener('change', search);
  m.el.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-do-copy]');
    if (!b) return;
    b.disabled = true;
    try {
      const c = await dm.duplicateOfficial(b.dataset.type, b.dataset.doCopy, campaignId);
      toast(`${c.name} created as a draft.`, 'good');
      m.close();
      onCreated?.(c);
    } catch (err) { b.disabled = false; toast(err.message, 'bad'); }
  });
  $('[data-do-q]', m.el).focus();
  return m;
}

// ---- the editor --------------------------------------------------------------------------------------------------------------
/** Typed-name confirmation for a permanent delete; resolves to the typed name or null. */
function askName(name, { what = 'item', detail = 'Nothing uses this item yet. Deleting removes every version for good and cannot be undone.' } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const m = openModal({
      title: `Delete ${name}?`,
      body: `<p>${esc(detail)}</p>
        <label class="field"><span>Type the ${esc(what)} name to confirm</span><input data-n autocomplete="off"></label>`,
      footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-bad" data-ok disabled>Delete for good</button>',
      onClose: () => { if (!done) resolve(null); },
    });
    const inp = $('[data-n]', m.el); const ok = $('[data-ok]', m.el);
    inp.addEventListener('input', () => { ok.disabled = inp.value.trim() !== name; });
    ok.addEventListener('click', () => { done = true; resolve(inp.value.trim()); m.close(); });
    inp.focus();
  });
}

/** Open the editor of one content item (or create a new one: content = {content_type, campaign_id}). */
export async function openContentEditor({ content, campaignId, onChanged, onAssign, focus = null }) {
  const ref = await dm.getEditorReference();
  let c = content?.id ? await dm.getContent(content.id) : null;
  const type = c?.content_type || content.content_type;
  const current = () => c?.versions?.find((v) => v.id === c.current_version_id) || { name: '', definition: {} };
  const m = openModal({ title: c ? `${TYPE[type].label}: ${c.name}` : `New ${TYPE[type].label.toLowerCase()}`, wide: true, body: '<div data-ce></div>', footer: '<div data-ce-actions class="ce-actions"></div>' });
  const editable = () => !c || ['draft', 'validation_failed', 'ready_for_review'].includes(current().status);
  let mgmt = null;   // get_dm_content_usage: whether Delete permanently is offered (the server decides; re-checked on delete)
  const refreshMgmt = async () => {
    if (!c?.id || !contentManagementEnabled()) { mgmt = null; return; }
    mgmt = await dm.getContentUsage(c.id).catch(() => null);
  };

  function draw() {
    const v = current();
    const model = formModel(type, v);
    // one source for the header: the usage report once it is loaded (it also counts stashes, requests, other content)
    const usage = mgmt ? { characters: Number(mgmt.characters) || 0, pending_requests: Number(mgmt.counts?.pending_requests) || 0 } : c?.usage;
    $('[data-ce]', m.el).innerHTML = `
      ${c ? `<div class="ce-status"><span class="ce-chip ce-${esc(c.status)}">${esc(STATUS[c.status] || c.status)}</span>
        <span class="small muted">Version ${esc(v.version_no || 1)}${c.published_version_id && c.published_version_id !== v.id ? ' (draft of a new version)' : ''}
        · ${c.scope === 'private' ? 'Your private library (copy it to a campaign to publish)' : `Campaign: ${esc(c.campaign_name || '')}`}</span>
        ${usage ? `<span class="small">Used by <strong>${usage.characters}</strong> character${usage.characters === 1 ? '' : 's'}${usage.pending_requests ? `, in ${usage.pending_requests} pending request(s)` : ''}</span>` : ''}</div>` : ''}
      ${!editable() ? '<p class="gov-banner">This version is published: its mechanics never change in place. Use “New version” to change them; characters keep the version they have.</p>' : ''}
      ${(v.validation?.errors || []).length ? `<div class="gov-error" role="alert"><strong>Fix before publishing:</strong><ul>${v.validation.errors.map((e) => `<li>${esc(e)}</li>`).join('')}</ul></div>` : ''}
      ${(v.validation?.warnings || []).length ? `<div class="gov-banner"><ul>${v.validation.warnings.map((e) => `<li>${esc(e)}</li>`).join('')}</ul></div>` : ''}
      <form class="ce-form" data-ce-form ${editable() ? '' : 'inert'}>
        <label class="field"><span>Name</span><input name="name" required maxlength="80" value="${esc(model.name || '')}"></label>
        ${schemaFor(type, ref).map((sec) => `<fieldset class="ce-section ${sec.dm ? 'dm-only-field' : ''}" ${sec.for ? `data-ce-for="${esc(sec.for)}"` : ''} ${sec.key ? `data-ce-section="${esc(sec.key)}"` : ''}><legend>${esc(sec.title)}</legend>
          <div class="ce-grid">${sec.fields.map((f) => fieldHTML(f, model)).join('')}</div></fieldset>`).join('')}
      </form>
      <section class="ce-preview" data-ce-preview hidden aria-live="polite"></section>`;
    const st = c?.status;
    $('[data-ce-actions]', m.el).innerHTML = `
      ${editable() ? '<button type="button" class="btn" data-ce-act="save">Save draft</button><button type="button" class="btn" data-ce-act="validate">Validate</button>' : ''}
      ${c ? '<button type="button" class="btn" data-ce-act="preview">Preview player view</button>' : ''}
      ${c && editable() && c.scope !== 'private' ? '<button type="button" class="btn btn-gold" data-ce-act="publish">Publish to campaign</button>' : ''}
      ${c && !editable() && st !== 'archived' ? '<button type="button" class="btn" data-ce-act="newversion">New version</button>' : ''}
      ${c && c.published_version_id && st !== 'archived' ? '<button type="button" class="btn btn-gold" data-ce-act="assign">Assign…</button>' : ''}
      ${c && c.scope === 'private' ? '<button type="button" class="btn" data-ce-act="copy">Copy to this campaign</button>' : ''}
      ${c ? '<button type="button" class="btn" data-ce-act="duplicate">Duplicate</button>' : ''}
      ${c && st === 'archived' ? '<button type="button" class="btn" data-ce-act="restore">Restore</button>' : ''}
      ${c && c.published_version_id && st !== 'archived' ? '<button type="button" class="btn btn-bad" data-ce-act="archive">Archive</button>' : ''}
      ${c && contentManagementEnabled() ? '<button type="button" class="btn" data-ce-act="usage">View usage…</button>' : ''}
      ${c && !contentManagementEnabled() && !c.published_version_id ? '<button type="button" class="btn btn-bad" data-ce-act="delete">Delete draft</button>' : ''}
      ${c && !contentManagementEnabled() && type === 'item' && c.published_version_id && !(usage?.characters) && !(usage?.stash_items) ? '<button type="button" class="btn btn-bad" data-ce-act="delete-unused">Delete (unused)…</button>' : ''}
      ${c && contentManagementEnabled() && (mgmt ? mgmt.can_delete : !c.published_version_id) ? '<button type="button" class="btn btn-bad" data-ce-act="delete-any">Delete permanently…</button>' : ''}
      <button type="button" class="btn btn-ghost" data-close>Close</button>`;
    $$('.multi-opts[data-max]', m.el).forEach(limitMulti);
    showTypeSections();
    // opened from DM Space for one section (e.g. 'identify'): show it, and how to change a published version
    const sec = focus && $(`[data-ce-section="${focus}"]`, m.el);
    if (sec) {
      if (!editable()) sec.insertAdjacentHTML('beforebegin', '<p class="gov-banner small" data-ce-focus-hint>To change how players identify it: “New version”, change “Identification by players”, then “Publish to campaign”. Copies players already hold follow the published settings.</p>');
      sec.scrollIntoView({ block: 'start' });
    }
  }
  // item: only the stats section of the chosen type (Weapon, Armor, Ammunition) is shown, and only it is sent (readForm)
  function showTypeSections() {
    const kind = $('[name="definition.item.kind_id"]', m.el)?.value;
    $$('[data-ce-for]', m.el).forEach((fs) => { fs.hidden = kind !== fs.dataset.ceFor; });
  }
  function limitMulti(g) {
    const max = Number(g.dataset.max);
    const boxes = $$('input', g);
    const n = boxes.filter((b) => b.checked).length;
    boxes.forEach((b) => { b.disabled = !b.checked && n >= max; });
  }
  async function save() {
    const fields = readForm($('[data-ce-form]', m.el), type, current());
    if (!fields.name?.trim()) throw new Error('Give it a name');
    c = c ? await dm.saveContent(c.id, fields, current().revision) : await dm.createContent(type, content.campaign_id ?? campaignId, fields);
    onChanged?.();
  }
  m.el.addEventListener('change', (e) => {
    const g = e.target.closest('.multi-opts[data-max]'); if (g) limitMulti(g);
    if (e.target.name === 'definition.item.kind_id') showTypeSections();
  });
  m.el.addEventListener('click', async (e) => {
    const add = e.target.closest('[data-add-row]');
    if (add) {
      const wrap = add.closest('[data-rows]');
      const spec = JSON.parse(wrap.dataset.rowSpec);
      const i = $$(':scope > .ce-row', wrap).length;
      add.insertAdjacentHTML('beforebegin', rowHTML(spec, {}, `${wrap.dataset.rows}.${i}.`));
      return;
    }
    const rm = e.target.closest('[data-remove-row]');
    if (rm) { rm.closest('.ce-row').remove(); return; }
    const act = e.target.closest('[data-ce-act]')?.dataset.ceAct;
    if (!act) return;
    const btn = e.target.closest('[data-ce-act]');
    btn.disabled = true;
    try {
      switch (act) {
        case 'save': await save(); toast('Draft saved.', 'good'); break;
        case 'validate': if (editable()) await save(); { const r = await dm.validateContent(c.id); c = r; toast(r.validation?.ok ? 'Ready to publish.' : 'Some things need fixing.', r.validation?.ok ? 'good' : 'bad'); } break;
        case 'preview': {
          if (editable()) await save();
          const p = await dm.previewContent(c.id);
          const box = $('[data-ce-preview]', m.el);
          box.hidden = false;
          box.innerHTML = `<h3 class="small-h">Players will see</h3>${p.ok ? previewHTML(type, p.preview, p.player_view, ref) : `<div class="gov-error">${esc((p.errors || []).join(' '))}</div>`}`;
          box.scrollIntoView({ block: 'nearest' });
          btn.disabled = false;
          return;
        }
        case 'publish':
          await save();
          if (!(await confirmDialog(`Publish “${current().name}” to the campaign? Players of the campaign will see it, and its mechanics can no longer be edited in place.`, { okLabel: 'Publish' }))) break;
          c = await dm.publishContent(c.id, c.current_version_id);
          toast('Published.', 'good'); onChanged?.(); break;
        case 'newversion': c = await dm.newContentVersion(c.id); toast('New draft version created.'); break;
        case 'assign': m.close(); onAssign?.(c); return;
        case 'copy': c = await dm.duplicateContent(c.id, campaignId); toast('Copied to the campaign as a draft.', 'good'); onChanged?.(); break;
        case 'duplicate': c = await dm.duplicateContent(c.id); toast('Duplicated as a new draft.', 'good'); onChanged?.(); break;
        case 'restore': c = await dm.restoreContent(c.id); toast('Restored.', 'good'); onChanged?.(); break;
        case 'archive': {
          const n = c.usage?.characters || 0;
          if (!(await confirmDialog(`Archive “${c.name}”? It can no longer be assigned.${n ? ` The ${n} character(s) that have it keep it.` : ''}`, { okLabel: 'Archive', danger: true }))) break;
          c = await dm.archiveContent(c.id); toast('Archived.'); onChanged?.(); break;
        }
        case 'usage': await openUsage(c, { onChanged: () => { onChanged?.(); m.close(); }, onDeleted: () => { onChanged?.(); m.close(); } }); btn.disabled = false; return;
        case 'delete-any': {
          await refreshMgmt();
          if (!mgmt?.can_delete) { toast('It is in use: open “View usage…” to see where.', 'bad', 6000); break; }
          if (await deleteContentFlow(mgmt)) { onChanged?.(); m.close(); return; }
          break;
        }
        case 'delete-unused': {
          const typed = await askName(c.name);
          if (typed == null) break;
          await dm.deleteUnusedItem(c.id, typed);
          toast('Item deleted.'); onChanged?.(); m.close(); return;
        }
        case 'delete':
          if (!(await confirmDialog('Delete this draft for good?', { okLabel: 'Delete', danger: true }))) break;
          await dm.deleteContent(c.id); toast('Draft deleted.'); onChanged?.(); m.close(); return;
        default:
      }
      await refreshMgmt();
      draw();
    } catch (err) {
      toast(err.message, 'bad', 6000);
    }
    btn.disabled = false;
  });
  draw();
  refreshMgmt().then(() => { if (mgmt) draw(); });
  return m;
}
