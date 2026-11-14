// Internal icon gallery for custom items (docs/CUSTOM_ITEM_ICONS.md). Only registered icons can be chosen: the database
// stores the registry key (items.icon_key, checked by items_icon_key_check), never a URL, SVG or HTML. No uploads here: the
// DM's own uploaded icons are a separate per-campaign override (js/custom-icons.js, docs/CUSTOM_ICONS.md).
// Resolution when shown: the item's own key -> its category default -> the generic icon (icons.js fallback chain).
import { esc } from './utils.js?v=33';
import { icon } from './icons.js?v=33';
import { ICON_REGISTRY } from './icon-registry.js?v=33';

export const ITEM_ICON_GALLERY = [
  ['potion.generic', 'Potion'], ['potion.healing', 'Healing potion'], ['potion.mana', 'Blue potion'], ['potion.poison', 'Poison'],
  ['potion.acid', 'Acid'], ['potion.fire', 'Fire potion'], ['potion.love', 'Pink potion'], ['potion.flask', 'Flask'], ['potion.bottle', 'Bottle'],
  ['potion.empty', 'Empty bottle'], ['plant.herb', 'Herb sprig'], ['plant.leaf', 'Leaf / grass'], ['plant.flower', 'Flower'],
  ['plant.wildflowers', 'Wildflowers'], ['plant.mushroom', 'Mushroom'], ['plant.root', 'Root / thorny vine'], ['plant.seed', 'Seed head'],
  ['plant.berry', 'Berries'], ['item.crystal', 'Crystal / resin'], ['item.gem', 'Gem'], ['item.mortar-pestle', 'Ingredient (mortar)'],
  ['item.cauldron', 'Cauldron'], ['item.weapons', 'Weapon'], ['item.tools', 'Tool'], ['item.armor', 'Armor'], ['item.magic', 'Magic'],
  ['item.scroll', 'Scroll'], ['item.wand', 'Wand'], ['item.amulet-gem', 'Amulet'], ['item.bandage', 'Bandage'], ['item.candle', 'Candle'],
  ['item.containers', 'Container'], ['item.treasure', 'Treasure'], ['item.key', 'Key'], ['item.book', 'Book'],
].filter(([k]) => ICON_REGISTRY[k]);

const KNOWN = new Set(ITEM_ICON_GALLERY.map(([k]) => k));
/** A stored key the browser can show; anything else (an unknown or removed key) falls back to the category icon. */
export const galleryIcon = (key) => (key && KNOWN.has(key) ? key : null);

/** Radio grid (keyboard: arrow keys move between options; each option has a text label). */
export function iconPickerHTML(name, value, { legend = 'Icon', categoryDefault = '' } = {}) {
  const v = galleryIcon(value) || '';
  return `<fieldset class="icon-picker" data-icon-picker><legend>${esc(legend)} <span class="muted small">(optional: otherwise the category icon${categoryDefault ? ` ${icon(categoryDefault, { size: 16 })}` : ''})</span></legend>
    <div class="icon-picker-grid" role="radiogroup" aria-label="${esc(legend)}">
      <label class="icon-opt"><input type="radio" name="${esc(name)}" value="" ${v ? '' : 'checked'}><span class="icon-opt-none" aria-hidden="true">—</span><span class="icon-opt-label">Category default</span></label>
      ${ITEM_ICON_GALLERY.map(([k, l]) => `<label class="icon-opt" title="${esc(l)}"><input type="radio" name="${esc(name)}" value="${esc(k)}" ${v === k ? 'checked' : ''}>
        ${icon(k, { size: 32 })}<span class="icon-opt-label">${esc(l)}</span></label>`).join('')}
    </div></fieldset>`;
}
