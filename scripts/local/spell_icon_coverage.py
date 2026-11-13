"""Spell icon coverage (docs/SPELL_ICON_COVERAGE.md): classify every spell version with the app's own resolver.

Reads the LOCAL database (docker exec into the local Supabase db container), loads js/spell-icons.js in a browser page served
by the local frontend (APP_URL, default http://127.0.0.1:5191/) and runs resolveSpellIcon() on two shapes of every spell:
  - the spellbook / details shape (effect rows), and
  - the catalog shape (damage-type links only), which the spell picker uses.
The primary icon comes from the school only, so both shapes must agree. Each icon file used is also loaded in the page and
checked for pixels (broken path / blank image). Damage relationships are counted for the chips (spellDamage()), not icons.
Writes data/reports/spell_icon_coverage.json and docs/SPELL_ICON_COVERAGE.md.

Usage (Playwright Python):  python scripts/local/spell_icon_coverage.py
"""
import json
import os
import subprocess
from collections import Counter
from datetime import date
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
APP = os.environ.get('APP_URL', 'http://127.0.0.1:5191/')
DB = os.environ.get('DB_CONTAINER', 'supabase_db_tavern_ledger')

SQL = """
select coalesce(jsonb_agg(x order by x->>'id'), '[]') from (
  select jsonb_build_object(
    'id', v.id, 'name', v.name, 'level', v.level, 'school_id', v.school_id, 'custom', v.id like 'cc-%',
    'effects', coalesce((select jsonb_agg(jsonb_build_object('category', e.category, 'damage_mode', e.damage_mode,
        'damage_types', coalesce((select jsonb_agg(d.damage_type_id order by d.damage_type_id) from public.spell_effect_damage_types d
                                  where d.version_id = e.version_id and d.seq = e.seq), '[]')) order by e.seq)
      from public.spell_effects e where e.version_id = v.id), '[]'),
    'links', coalesce((select jsonb_agg(jsonb_build_object('id', l.damage_type_id, 'relation', l.relation) order by l.damage_type_id)
      from public.spell_damage_type_links l where l.version_id = v.id), '[]')) x
  from public.spell_versions v) s;
"""


def load_spells():
    out = subprocess.run(['docker', 'exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1'],
                         input=SQL, capture_output=True, text=True, check=True, encoding='utf-8')
    return json.loads(out.stdout.strip())


def classify(spells):
    with sync_playwright() as p:
        br = p.chromium.launch(channel='msedge')
        pg = br.new_page()
        pg.goto(APP)
        res = pg.evaluate("""async (spells) => {
          const m = await import('./js/spell-icons.js?v=30');
          const reg = (await import('./js/icon-registry.js?v=30')).ICON_REGISTRY;
          const rows = spells.map((s) => {
            const shapeBook = { ...s, damage_types: s.links };                  // effect rows first (spellbook, details)
            // the catalog row: links only; campaign custom rows get their effect rows attached (spell-api.js withCustomEffects)
            const shapeCat = s.custom && !s.links.length ? s : { ...s, effects: [],
              damage_types: s.links.map((l) => l.id), damage_choice: s.links.some((l) => l.relation === 'choice') };
            const book = m.resolveSpellIcon(shapeBook);
            return { id: s.id, book, cat: m.resolveSpellIcon(shapeCat), damage: m.spellDamage(shapeBook), asset: reg[book.key]?.asset || null };
          });
          // every icon file used: loads (no broken path) and has visible pixels (not blank / fully transparent)
          const files = {};
          for (const a of [...new Set(rows.map((r) => r.asset).filter(Boolean))]) {
            const img = new Image();
            img.src = `assets/icons/${a}.webp`;
            const ok = await new Promise((r) => { img.onload = () => r(true); img.onerror = () => r(false); });
            let visible = 0;
            if (ok && img.naturalWidth) {
              const c = document.createElement('canvas'); c.width = 64; c.height = 64;
              const g = c.getContext('2d'); g.drawImage(img, 0, 0, 64, 64);
              const d = g.getImageData(0, 0, 64, 64).data;
              for (let i = 3; i < d.length; i += 4) if (d[i] > 16) visible += 1;
            }
            files[a] = { loads: ok && img.naturalWidth > 0, visible };
          }
          return { rows, files };
        }""", spells)
        br.close()
    return res


SCHOOLS = ['abjuration', 'conjuration', 'divination', 'enchantment', 'evocation', 'illusion', 'necromancy', 'transmutation']


def main():
    spells = load_spells()
    out = classify(spells)
    res, files = {r['id']: r for r in out['rows']}, out['files']
    icons = ROOT / 'assets' / 'icons'
    rows = []
    for s in spells:
        r = res[s['id']]
        b, c, d = r['book'], r['cat'], r['damage']
        f = files.get(r['asset'] or '', {})
        rows.append({
            'id': s['id'], 'name': s['name'], 'level': s['level'], 'school': s['school_id'], 'custom': s['custom'],
            'icon': b['key'], 'requested_icon': b['requested'], 'icon_school': b['school'], 'label': b['label'], 'coverage': b['coverage'],
            'asset': r['asset'], 'asset_exists': bool(r['asset']) and (icons / f"{r['asset']}.webp").is_file(),
            'asset_loads': bool(f.get('loads')), 'asset_blank': bool(f.get('loads')) and f.get('visible', 0) < 20,
            'damage_types': d['types'], 'damage_relation': d['relation'],
            'catalog_icon': c['key'], 'views_agree': b['key'] == c['key'],
        })
    rel = Counter(r['damage_relation'] for r in rows)
    by_school = Counter(r['icon'] for r in rows)
    report = {
        'generated': date.today().isoformat(), 'rule': 'spell school -> one primary icon; damage types are chips',
        'total_spell_versions': len(rows),
        'by_school': {k: by_school.get(f'spell.school.{k}', 0) for k in SCHOOLS},
        'unresolved_school': sum(1 for r in rows if not r['icon_school']),
        'generic_fallback': sum(1 for r in rows if r['coverage'] != 'direct'),
        'icon_not_from_school': sum(1 for r in rows if r['icon_school'] and r['icon'] != f"spell.school.{r['icon_school']}"),
        'missing_asset': sum(1 for r in rows if not r['asset_exists']),
        'broken_path': sum(1 for r in rows if not r['asset_loads']),
        'blank_asset': sum(1 for r in rows if r['asset_blank']),
        'missing_label': sum(1 for r in rows if not r['label']),
        'catalog_and_spellbook_disagree': sum(1 for r in rows if not r['views_agree']),
        'custom_spells': sum(1 for r in rows if r['custom']),
        'damage_chips': {'single': rel['single'], 'dealt_together': rel['multiple'], 'choose_one': rel['choose'],
                         'separate_effects': rel['ambiguous'], 'no_damage': rel['none']},
        'icons_used': dict(sorted(by_school.items())),
        'spells': rows,
    }
    out = ROOT / 'data' / 'reports' / 'spell_icon_coverage.json'
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    write_doc(report)
    print({k: v for k, v in report.items() if k not in ('spells', 'icons_used')})


def write_doc(r):
    rows = r['spells']
    examples = ['fireball-phb', 'cure-wounds-phb', 'shield-phb', 'detect-magic-phb', 'misty-step-phb', 'hold-person-phb',
                'chill-touch-phb', 'minor-illusion-phb', 'polymorph-phb', 'ice-storm-phb', 'chromatic-orb-phb']
    by_id = {x['id']: x for x in rows}
    ex = '\n'.join(f"| {by_id[i]['name']} | {by_id[i]['school']} | `{by_id[i]['icon']}` | {by_id[i]['label']} | {', '.join(by_id[i]['damage_types']) or '—'} |"
                   for i in examples if i in by_id)
    custom = '\n'.join(f"| {x['name']} | `{x['id']}` | {x['school'] or '—'} | `{x['icon']}` | `{x['catalog_icon']}` | {', '.join(x['damage_types']) or '—'} |"
                       for x in rows if x['custom']) or '| none | | | | | |'
    schools = '\n'.join(f"| {k.title()} | `spell.school.{k}` | {v} |" for k, v in r['by_school'].items())
    unresolved = '\n'.join(f"| {x['name']} | `{x['id']}` | {x['school'] or '—'} |" for x in rows if not x['icon_school']) or '| none | | |'
    dc = r['damage_chips']
    doc = f"""# Spell icon coverage

Generated {r['generated']} by `scripts/local/spell_icon_coverage.py` from the local database, using the app's own resolver
(`js/spell-icons.js`). Machine-readable: `data/reports/spell_icon_coverage.json`.

## The rule

**Spell school → one primary spell icon.** Every spell view (spellbook cards, details dialog, catalog picker, DM custom spell
preview, published and assigned campaign spells, mobile cards) uses `resolveSpellIcon()`:

| Spell data | Primary icon |
|---|---|
| school is one of the eight schools | that school's icon (`spell.school.<school>`) |
| school missing or not recognised | the generic spell icon (`spell.school.generic`); the badge says "School not resolved" |
| school icon not registered / file fails to load | the generic spell icon (registry fallback, then the load-error fallback) |

Damage type, healing, temporary hit points, control, movement, summoning, the spell name, class lists and automation status
never choose the primary icon. Damage types stay visible as colored text chips (Fire orange, Necrotic deep green, "+" for
types dealt together, "Choose one … or …" for a choice); the school badge, school colour and card edge stay on every card.
A spell without damage is not "unrepresented": its school icon represents it.

## Totals

| Measure | Count |
|---|---|
| Spell versions | {r['total_spell_versions']} |
| Unresolved school | {r['unresolved_school']} |
| Generic fallback icon | {r['generic_fallback']} |
| Icon not taken from the school | {r['icon_not_from_school']} |
| Missing asset file | {r['missing_asset']} |
| Broken path (file does not load) | {r['broken_path']} |
| Blank asset (no visible pixels) | {r['blank_asset']} |
| Missing accessible label | {r['missing_label']} |
| Catalog picker and spellbook show different icons | {r['catalog_and_spellbook_disagree']} |
| Campaign custom spells | {r['custom_spells']} |

## Count by school

| School | Icon key | Spell versions |
|---|---|---|
{schools}

## Damage chips (not icons)

| Damage data | Spell versions |
|---|---|
| one damage type | {dc['single']} |
| several types dealt together ("+") | {dc['dealt_together']} |
| choose one type ("Choose one … or …") | {dc['choose_one']} |
| several types in separate effects (listed with commas) | {dc['separate_effects']} |
| no damage | {dc['no_damage']} |

## Examples

| Spell | School | Primary icon | Accessible label | Damage chips |
|---|---|---|---|---|
{ex}

## Unresolved schools

| Spell | Version | Stored school |
|---|---|---|
{unresolved}

## Campaign custom spells

| Spell | Version | School | Spellbook icon | Catalog icon | Damage chips |
|---|---|---|---|---|---|
{custom}
"""
    (ROOT / 'docs' / 'SPELL_ICON_COVERAGE.md').write_text(doc, encoding='utf-8')


if __name__ == '__main__':
    main()
