# Deployment: character export manifest (Phase C)

**Status: NOT STARTED.** No production character has been exported yet. Production access is needed first
(docs/DEPLOYMENT_CURRENT_SUPABASE.md).

## Where

`%USERPROFILE%\tavern-ledger-production-exports\2026-10-23-pre-v62-deployment\`

This is outside Git and outside OneDrive-synced repository folders. Layout:

```
original\      the files exactly as downloaded (never modified)
converted\     only if a file needs conversion (a copy plus conversion-report.md; the original stays)
manifest.json  manifest.md  SHA256SUMS.txt
```

## How to export (legacy app, as each character's owner or as the admin)

1. Open `https://alexandrajuscak.github.io/tavern_ledger/` and sign in.
2. For every character on the list: open it → the **Bio** tab → "⬇ Download JSON" (verified in the deployed code, `js/sheet.js` of `849d7f1`) → save it to `original\`.
3. Repeat until the number of files equals the `characters` count from the inventory query
   (docs/DEPLOYMENT_EXISTING_DATA_INVENTORY.md). An admin sees every character; a player sees only their own.

Each download is a read-only action: the legacy app does not write when it exports.

## Validation (on this machine; nothing is uploaded)

```
python scripts/local/serve_frontend.py . 5191          # in a separate terminal
APP_URL=http://127.0.0.1:5191/ <playwright-python> scripts/deploy/validate_exports.py "<export dir>\original"
```

`scripts/deploy/validate_exports.py` checks each file:

- it parses as JSON;
- the **current V6.2 import parser** accepts it (`parseCharacterJson`, run in a browser; no database involved, hosted
  requests blocked);
- the required sections are present;
- **no hidden DM data**;
- the derived values (HP max, AC) are recorded only as information, because they are recalculated on import;
- SHA-256.

It writes `manifest.json` / `manifest.md`. Per file, the manifest records the display name, the legacy id, the export
time, the schema version, class / classes, level, the lineage reference or race text, the background, feats, spells,
catalog spells, inventory, custom-item references and the validation result.

**Dry run (2026-10-23)** on copies of the 12 legacy files in `examples\` (6 characters × level 1 and 2):
**12 / 12 valid**. A full import of the six level-2 files is documented in docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md.

## Gate

The production switch (Phase F) is blocked until:

- every production character has a file;
- every file is valid in the manifest;
- `SHA256SUMS.txt` verifies;
- the manifest count equals the inventory count.

Owner and campaign are recorded by hand from the legacy character list, because the legacy export does not contain them.

| Production characters (inventory) | Files | Valid | Invalid | Converted |
|---|---|---|---|---|
| – | – | – | – | – |
