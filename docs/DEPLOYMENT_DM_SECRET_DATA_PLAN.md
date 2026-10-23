# Deployment: hidden and DM-only data (2026-10-23)

## Current production

Production runs the legacy schema (HEAD `849d7f1`). That schema has **no** hidden-data features: no DM notes, hidden
conditions, curses, unidentified items, unrevealed properties, DM-only audit or secret custom content. Everything in a
legacy character is visible to its owner and was exported with it.

| Hidden-data kind | Exists in production? | Decision |
|---|---|---|
| Hidden notes / DM notes | no (legacy `notes` are the player's own: character, session, campaign) | nothing to preserve |
| Hidden conditions | no (legacy `conditions` are a visible list) | – |
| Curses, unrevealed properties, unidentified true names | no | – |
| DM-only audit | no audit tables | – |
| Secret custom content | no custom-content tables | – |

**To confirm with the DM:** whether secrets were kept *outside* the app (e.g. in the DM's own notes) that should become
hidden data in the new DM Space. If so, the DM recreates them after deployment (DM Space → Hidden / Content). Nothing is
merged into player export files.

## If a DM-only export is ever needed (not needed now)

- It is a separate file, labelled `DM-ONLY`, stored outside Git (for example
  `tavern-ledger-production-exports\…\dm-only\`), encrypted at rest (BitLocker / 7-Zip AES) where possible, with its
  SHA-256 in the manifest.
- In V6.2 it is produced only by DM Space → Campaign rules → "Download DM backup", which is refused for players (SEC5 /
  SEC6). It is never produced with a privileged key unless that is explicitly authorised.
