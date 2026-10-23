"""Icon audit (docs/ICON_ASSET_INVENTORY.md): every icon reference, every asset, visual checks and licence status.

- Registry: js/icon-registry.js (semantic key -> asset, label, fallback, category, licence group).
- References: string literals in js/*.js and index.html that name an icon (semantic key "ui.attack" or asset name
  "ui/attack"), plus the dynamic families the code builds (spell.school.<school>, spell.damage.<type>, class.<class>,
  condition.<condition>) enumerated from their known values.
- Visual checks per asset (Pillow): opens and decodes, size, transparency, how much of the canvas the subject fills, blank or
  solid-rectangle images, contrast of the subject against the card surface (#23232c).
Writes data/reports/icon_audit.json and docs/ICON_ASSET_INVENTORY.md. Exit code 1 when a referenced icon cannot resolve, an
asset is missing or corrupt, or a visual check fails.

Usage:  python scripts/local/icon_audit.py
"""
import json
import re
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ICONS = ROOT / 'assets' / 'icons'
FOLDERS = ['actions', 'classes', 'conditions', 'creatures', 'damage-types', 'dm', 'equipment-slots', 'items', 'movement',
           'portraits', 'potions', 'spell-schools', 'ui']
PREFIXES = ['action', 'class', 'condition', 'creature', 'spell.damage', 'spell.school', 'dm', 'slot', 'item', 'movement',
            'portrait', 'potion', 'ui', 'section', 'build', 'inventory', 'identity']
DYNAMIC = {   # families built at run time from data values (js/icons.js, js/spell-icons.js)
    'spell.school': ['abjuration', 'conjuration', 'divination', 'enchantment', 'evocation', 'illusion', 'necromancy', 'transmutation', 'generic'],
    # spell.damage.* is no longer built at run time: spell primary icons come from the school only (2026-10-22 correction);
    # damage types are text chips. The damage-type assets stay in place, reported as unused.
    'class': ['artificer', 'barbarian', 'bard', 'cleric', 'druid', 'fighter', 'monk', 'paladin', 'ranger', 'rogue', 'sorcerer', 'warlock', 'wizard'],
    'condition': ['blinded', 'charmed', 'frightened', 'grappled', 'invisible', 'paralyzed', 'petrified', 'poisoned', 'restrained', 'stunned',
                  'generic-effect'],
}
# Licence status of each asset group. All icon groups come from the user's own collection (../icons, curated in
# ../icons_curated); the originals carry no licence file and look like icon-marketplace downloads.
UNKNOWN = {'source': '../icons (user collection), curated in ../icons_curated', 'provider': 'unknown (icon marketplace style)',
           'license': 'unknown', 'attribution': 'unknown (marketplace free licences usually require it)', 'modification': 'unknown',
           'redistribution': 'unknown', 'status': 'unknown', 'deployment': 'private table use only; replace or verify before public deployment'}
LICENCE = {g: UNKNOWN for g in FOLDERS}
SURFACE = (0x23, 0x23, 0x2c)


def registry():
    text = (ROOT / 'js' / 'icon-registry.js').read_text(encoding='utf-8')
    return json.loads(text.split('/*json*/', 1)[1].split('/*end*/', 1)[0])


def lum(rgb):
    def ch(c):
        c = c / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def inspect(path):
    out = {'exists': path.is_file()}
    if not out['exists']:
        return out
    try:
        im = Image.open(path)
        im.load()
    except Exception as e:   # noqa: BLE001 - any decode error is a corrupt asset
        out.update(corrupt=True, error=str(e))
        return out
    im = im.convert('RGBA')
    w, h = im.size
    alpha = im.getchannel('A')
    opaque = sum(1 for a in alpha.get_flattened_data() if a > 40)
    bbox = alpha.point(lambda a: 255 if a > 40 else 0).getbbox()
    fill = 0.0 if not bbox else max(bbox[2] - bbox[0], bbox[3] - bbox[1]) / max(w, h)
    px = [p for p in im.get_flattened_data() if p[3] > 40]
    if px:
        mean = tuple(sum(p[i] for p in px) / len(px) for i in range(3))
        l1, l2 = lum(mean), lum(SURFACE)
        contrast = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        # the brightest tenth of the subject: illustrated icons read by their highlights, not their average
        bright = sorted(lum(p[:3]) for p in px)[int(len(px) * 0.9)]
        contrast_hi = (max(bright, l2) + 0.05) / (min(bright, l2) + 0.05)
    else:
        contrast = contrast_hi = 0
    out.update(corrupt=False, width=w, height=h, coverage=round(opaque / (w * h), 3), subject_extent=round(fill, 3),
               contrast=round(contrast, 2), contrast_highlights=round(contrast_hi, 2))
    issues = []
    if out['coverage'] < 0.03:
        issues.append('blank or nearly empty')
    if out['coverage'] > 0.97:
        issues.append('solid rectangle (no transparency)')
    if fill < 0.6:
        issues.append('subject is small inside the canvas')
    if contrast_hi < 3:
        issues.append('low contrast on the dark card surface')
    if (w, h) not in ((96, 96), (192, 192)):
        issues.append(f'unexpected size {w}x{h}')
    out['issues'] = issues
    return out


def references(reg):
    refs = defaultdict(set)
    asset_names = {v['asset'] for v in reg.values()}
    path_re = re.compile(r"""['"`]((?:%s)/[a-z0-9-]+)['"`]""" % '|'.join(map(re.escape, FOLDERS)))
    key_re = re.compile(r"""['"`]((?:%s|generic)(?:\.[a-z0-9-]+)*)['"`]""" % '|'.join(map(re.escape, PREFIXES)))
    files = sorted((ROOT / 'js').glob('*.js')) + [ROOT / 'index.html']
    for f in files:
        if f.name == 'icon-registry.js':
            continue
        text = f.read_text(encoding='utf-8')
        rel = f.relative_to(ROOT).as_posix()
        for m in path_re.finditer(text):
            refs[m.group(1)].add(rel)
        for m in key_re.finditer(text):
            k = m.group(1)
            if k in reg or '.' in k and k.split('.')[0] in ('section', 'build', 'inventory', 'identity', 'spell', 'ui', 'action'):
                refs[k].add(rel)
        for m in re.finditer(r'assets/icons/([a-z0-9-]+/[a-z0-9-]+)\.webp', text):
            refs[m.group(1)].add(rel)
    for fam, names in DYNAMIC.items():
        for n in names:
            refs[f'{fam}.{n}'].add('(dynamic family)')
    return refs, asset_names


def main():
    reg = registry()
    by_asset = {}
    for k, v in reg.items():
        if not v.get('alias_of'):
            by_asset.setdefault(v['asset'], k)
    refs, _ = references(reg)
    # resolve every reference the way js/icons.js does
    resolved = {}
    for name, where in sorted(refs.items()):
        key = name if name in reg else by_asset.get(name)
        resolved[name] = {'referenced_by': sorted(where), 'key': key, 'match': 'direct' if key else 'fallback',
                          'resolves_to': key or 'generic'}
    files = {f'{p.parent.name}/{p.stem}': p for p in ICONS.glob('*/*.webp')}
    assets = {a: inspect(files.get(a, ICONS / f'{a}.webp')) for a in sorted(set(files) | {v['asset'] for v in reg.values()})}
    used_assets = {reg[r['resolves_to']]['asset'] for r in resolved.values()}
    used_assets |= {reg[v['fallback']]['asset'] for v in reg.values() if v.get('fallback') in reg}
    keys = []
    for k, v in sorted(reg.items()):
        a = assets[v['asset']]
        keys.append({'key': k, **v, 'asset_exists': a.get('exists', False), 'size': f"{a.get('width')}x{a.get('height')}",
                     'issues': a.get('issues', []), 'referenced_by': sorted(refs.get(k, set()) | refs.get(v['asset'], set()) if not v.get('alias_of') else refs.get(k, set())),
                     'licence': LICENCE.get(v['group'], UNKNOWN)['status']})
    report = {
        'generated': date.today().isoformat(),
        'semantic_keys': len(reg), 'alias_keys': sum(1 for v in reg.values() if v.get('alias_of')),
        'asset_files': len(files), 'references': len(resolved),
        'direct_matches': sum(1 for r in resolved.values() if r['match'] == 'direct'),
        'fallbacks': sum(1 for r in resolved.values() if r['match'] == 'fallback'),
        'missing_assets': sorted(a for a, i in assets.items() if not i.get('exists')),
        'corrupt_assets': sorted(a for a, i in assets.items() if i.get('corrupt')),
        'visual_issues': {a: i['issues'] for a, i in assets.items() if i.get('issues')},
        'missing_labels': sorted(k for k, v in reg.items() if not v.get('label')),
        'unused_assets': sorted(a for a in files if a not in used_assets),
        'unknown_licence_assets': sorted(a for a in files if LICENCE.get(a.split('/')[0], UNKNOWN)['status'] != 'approved'),
        'licence_groups': LICENCE,
        'unresolved_references': {n: r for n, r in resolved.items() if r['match'] == 'fallback'},
        'references_detail': resolved, 'assets_detail': assets, 'keys': keys,
    }
    (ROOT / 'data' / 'reports' / 'icon_audit.json').write_text(json.dumps(report, indent=1) + '\n', encoding='utf-8')
    write_doc(report)
    summary = {k: (len(v) if isinstance(v, (list, dict)) else v) for k, v in report.items()
               if k not in ('references_detail', 'assets_detail', 'keys', 'licence_groups')}
    print(json.dumps(summary, indent=1))
    bad = report['missing_assets'] or report['corrupt_assets'] or report['unresolved_references'] or report['missing_labels'] \
        or any(i for a, i in report['visual_issues'].items() if a in {k['asset'] for k in keys})
    sys.exit(1 if bad else 0)


def write_doc(r):
    groups = defaultdict(list)
    for k in r['keys']:
        groups[k['category']].append(k)
    sections = []
    for cat, ks in sorted(groups.items()):
        rows = '\n'.join(
            f"| `{k['key']}` | `{k['asset']}` | {'yes' if k['asset_exists'] else '**no**'} | {k['size']} | "
            f"{'; '.join(k['issues']) or 'ok'} | {k['label']} | `{k['fallback']}` | {', '.join(x.replace('js/', '') for x in k['referenced_by']) or 'unused'} |"
            for k in ks)
        sections.append(f"### {cat}\n\n| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |\n"
                        f"|---|---|---|---|---|---|---|---|\n{rows}\n")
    lic = '\n'.join(f"| {g} | {v['source']} | {v['provider']} | {v['license']} | {v['attribution']} | {v['modification']} | "
                    f"{v['redistribution']} | **{v['status']}**: {v['deployment']} |" for g, v in r['licence_groups'].items())
    vis = '\n'.join(f"| `{a}` | {'; '.join(i)} |" for a, i in r['visual_issues'].items()) or '| none | |'
    unused = ', '.join(f'`{a}`' for a in r['unused_assets']) or 'none'
    doc = f"""# Icon asset inventory

Generated {r['generated']} by `scripts/local/icon_audit.py`; machine-readable report: `data/reports/icon_audit.json`.
Registry: `js/icon-registry.js` (generated from `assets/icons` by `scripts/local/build_icon_registry.py`). Rules:
`docs/UI_ICON_SYSTEM.md`.

## Summary

| Measure | Count |
|---|---|
| Semantic keys | {r['semantic_keys']} ({r['alias_keys']} semantic aliases such as `section.skills`) |
| Asset files | {r['asset_files']} |
| Icon references in code (incl. dynamic families) | {r['references']} |
| Direct matches | {r['direct_matches']} |
| Fallbacks (reference not in the registry) | {r['fallbacks']} |
| Missing asset files | {len(r['missing_assets'])} |
| Corrupt assets | {len(r['corrupt_assets'])} |
| Assets with a visual-check note | {len(r['visual_issues'])} |
| Keys without an accessible label | {len(r['missing_labels'])} |
| Assets not referenced by the app (kept for later use) | {len(r['unused_assets'])} |
| Assets with unknown licence | {len(r['unknown_licence_assets'])} |

Fallback chain (js/icons.js): specific key → the key's `fallback` (category icon) → `generic`. A file that fails to load is
swapped for its fallback at the same size, then for the generic icon.

## Visual check notes

Thresholds: subject fills at least 60% of the canvas, 3–97% of the pixels are opaque, the brightest tenth of the subject
reaches 3:1 against the card surface, 96 px (192 px portraits).

| Asset | Note |
|---|---|
{vis}

## Licensing

| Group | Source | Author / provider | Licence | Attribution | Modification | Redistribution | Status |
|---|---|---|---|---|---|---|---|
{lic}
| fonts (Inter, Alegreya) | Google Fonts / GitHub | Rasmus Andersson; Juan Pablo del Peral (Huerta Tipográfica) | SIL OFL 1.1 | licence text shipped (`fonts/OFL-*.txt`) | allowed | allowed | **approved** |

Every icon group is **unknown**: fine for private table use, but each one must be verified (and attributed if the licence
asks for it) or replaced before the app is shared publicly or deployed. Two icons were added in this task from the same
collection (`damage-types/multiple` from `storm (1).png`, `damage-types/choose` from `tarot-card.png`); they inherit the
same status. Since the school-only spell icon correction (2026-10-22) no view draws a damage-type icon; those assets are kept
(unused) in case a later feature needs them.

## Unused assets

{unused}

## Keys

{chr(10).join(sections)}"""
    (ROOT / 'docs' / 'ICON_ASSET_INVENTORY.md').write_text(doc, encoding='utf-8')


if __name__ == '__main__':
    main()
