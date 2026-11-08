"""Write js/icon-registry.js from the files in assets/icons (docs/UI_ICON_SYSTEM.md).

Every asset gets a semantic key (<category>.<name>); ALIASES add the semantic keys the app uses for meaning
(section.*, build.*, inventory.*). Run after adding or removing an icon file:  python scripts/local/build_icon_registry.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ICONS = ROOT / 'assets' / 'icons'

# folder -> (key prefix, label pattern, category fallback key)
FOLDERS = {
    'actions': ('action', '{}', 'generic'),
    'classes': ('class', '{}', 'ui.build'),
    'conditions': ('condition', '{}', 'condition.generic-effect'),
    'creatures': ('creature', '{}', 'dm.creature'),
    'damage-types': ('spell.damage', '{} damage', 'spell.damage.generic'),
    'dm': ('dm', '{}', 'generic'),
    'equipment-slots': ('slot', '{} slot', 'inventory.generic'),
    'items': ('item', '{}', 'inventory.generic'),
    'movement': ('movement', '{}', 'action.speed'),
    'portraits': ('portrait', '{}', 'identity.generic'),
    'plants': ('plant', '{}', 'item.mortar-pestle'),
    'potions': ('potion', '{} potion', 'item.consumables'),
    'spell-schools': ('spell.school', '{} school', 'spell.school.generic'),
    'ui': ('ui', '{}', 'generic'),
}
LABELS = {   # names that read badly when derived from the file name
    'spell.damage.multiple': 'Several damage types', 'spell.damage.choose': 'Choose a damage type',
    'spell.school.spells-tab': 'Spells', 'action.damage': 'Damage', 'condition.generic-effect': 'Effect',
    'ui.dm-secret': 'DM only', 'ui.temp-hp': 'Temporary hit points', 'ui.hit-dice': 'Hit dice', 'ui.custom-content': 'Custom content',
    'ui.bonus-action': 'Bonus action', 'ui.saving-throw': 'Saving throw', 'potion.generic': 'Potion', 'potion.empty': 'Empty bottle',
    'dm.dm-grant': 'DM grant', 'item.spell-scroll': 'Spell scroll', 'item.amulet-gem': 'Amulet', 'item.tome-sealed': 'Sealed tome',
    'item.ink-and-quill': 'Ink and quill', 'item.mortar-pestle': 'Mortar and pestle', 'slot.main-hand': 'Main hand slot',
    'slot.off-hand': 'Off hand slot',
    'potion.flask': 'Flask', 'potion.bottle': 'Bottle', 'plant.herb': 'Herb sprig', 'plant.wildflowers': 'Wildflowers',
    'plant.berry': 'Berries', 'plant.root': 'Root or thorny vine',
}
# semantic aliases: key -> (target key, label)
ALIASES = {
    'generic': ('item.crystal', 'Icon'),
    'identity.generic': ('ui.bio', 'Identity'),
    'inventory.generic': ('ui.inventory', 'Item'),
    'spell.school.generic': ('spell.school.spells-tab', 'Spell school'),
    'spell.damage.generic': ('action.damage', 'Damage'),
    'section.play': ('ui.play', 'Play'), 'section.abilities': ('ui.abilities', 'Abilities'),
    'section.ability-scores': ('ui.abilities', 'Ability scores'), 'section.saving-throws': ('ui.saving-throw', 'Saving throws'),
    'section.skills': ('ui.skills', 'Skills'), 'section.senses': ('ui.senses', 'Senses and movement'),
    'section.proficiencies': ('action.proficiency', 'Proficiencies'), 'section.hit-dice': ('ui.hit-dice', 'Hit dice'),
    'section.spells': ('spell.school.spells-tab', 'Spells'), 'section.spellbook': ('ui.spellbook', 'Your spells'),
    'section.spell-slots': ('action.inspiration', 'Spell slots'), 'section.inventory': ('ui.inventory', 'Inventory'),
    'section.equipped': ('slot.armor', 'Equipped'), 'section.attunement': ('ui.attunement', 'Attunement'),
    'section.quick-use': ('potion.healing', 'Quick use'), 'section.containers': ('item.containers', 'Containers'),
    'section.legacy': ('ui.incomplete', 'Old sheet items'), 'section.coins': ('item.coins', 'Coins'),
    'section.build': ('ui.build', 'Build'), 'section.bio': ('ui.bio', 'Bio'), 'section.notes': ('ui.notes', 'Notes'),
    'build.next': ('ui.build', 'Next steps'), 'build.class': ('ui.abilities', 'Classes'), 'build.class-features': ('ui.feat', 'Class features'),
    'build.lineage': ('ui.lineage', 'Lineage'), 'build.background': ('ui.background', 'Background'), 'build.feat': ('ui.feat', 'Feats'),
    'build.reminders': ('ui.notes', 'Reminders'), 'build.own-features': ('ui.custom-content', 'Your own features'),
    'inventory.herbs': ('plant.herb', 'Herbs & Plants'), 'inventory.potion': ('potion.generic', 'Potion'),
    'inventory.weapon': ('item.weapons', 'Weapon'), 'inventory.armor': ('item.armor', 'Armor'), 'inventory.shield': ('slot.shield', 'Shield'),
}
FALLBACK_OF = {'build.lineage': 'identity.generic', 'build.background': 'identity.generic'}


def title(name):
    return name.replace('-', ' ').strip().capitalize()


def main():
    reg = {}
    for folder, (prefix, pattern, fallback) in FOLDERS.items():
        for f in sorted((ICONS / folder).glob('*.webp')):
            key = f'{prefix}.{f.stem}'
            reg[key] = {'asset': f'{folder}/{f.stem}', 'label': LABELS.get(key, pattern.format(title(f.stem))),
                        'category': prefix, 'fallback': fallback, 'group': folder}
    for key, (target, label) in ALIASES.items():
        t = reg[target]
        reg[key] = {'asset': t['asset'], 'label': label, 'category': key.split('.')[0], 'fallback': 'generic',
                    'group': t['group'], 'alias_of': target}
    reg.update({k: {**reg[k], 'fallback': fb} for k, fb in FALLBACK_OF.items()})
    for k, v in reg.items():
        if v['fallback'] == k:
            v['fallback'] = 'generic'
    reg['generic']['fallback'] = None
    body = '{\n' + ',\n'.join(f' {json.dumps(k)}: {json.dumps(reg[k], sort_keys=True)}' for k in sorted(reg)) + '\n}'
    out = ROOT / 'js' / 'icon-registry.js'
    out.write_text('// GENERATED by scripts/local/build_icon_registry.py from assets/icons. Do not edit by hand; run the script.\n'
                   '// semantic key -> asset (path under assets/icons, no extension), label, category, fallback key, licence group.\n'
                   f'export const ICON_REGISTRY = /*json*/{body}/*end*/;\n', encoding='utf-8')
    print(f'{len(reg)} keys -> {out.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
