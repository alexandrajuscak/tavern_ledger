# Your own item icons (DM)

Since `?v=30` (migration `20261114000200_custom_item_icons`) a DM can give any item of their campaign their own picture.
It replaces the item's icon for everyone in that campaign who **knows** the item: inventory list, weapon cards on the Play
tab and DM Space. The built-in icon gallery (`docs/CUSTOM_ITEM_ICONS.md`) is unchanged and stays the default.

## Upload or replace an icon

1. DM Space → **Content** → **Item icons…** (or, in the Content editor of a published item, **Item icon…**).
2. Find the item (search box). The list holds your campaign's own items (DM Content, campaign homebrew) and every item
   somebody in the campaign holds, official ones included.
3. **Upload…** (or **Replace…**) and choose an image (PNG, JPEG, WebP or GIF). Your browser shrinks it to 128 px on the
   longest side and saves it as WebP (PNG where the browser cannot write WebP), usually 5-10 KB.
4. Players see the new icon the next time their inventory loads (open the Inventory tab again or reopen the sheet).

A DM Content item keeps one icon across its versions: setting it on one version sets it on all of them, and a version you
publish later gets it too.

## Remove an icon

**Remove** in the same list. The item shows its default icon again. The uploaded file itself is kept (nothing you upload is
ever deleted); it is no longer linked and nobody can list it.

## Hidden and unidentified items

Your icon never gives an item away. A player who holds a hidden, unidentified or only partly identified copy (also a herb
shown with its decoy description) sees the default icon on that copy, exactly like the decoy name. Once you reveal the item
to that character (fully identified), their copy shows your icon. You, as DM, see the default icon on a disguised copy in a
player's sheet (it matches the decoy you see there) and your icon everywhere else.

## Limits

- At most 64 KB per file, only WebP or PNG are stored (the browser converts other formats). The server refuses anything else.
- Only the campaign's DM can upload, replace or remove icons. Players and DMs of other campaigns cannot.
- The icon belongs to one campaign: the same official item can have a different icon in another campaign.
- Not live: an open player sheet keeps the old icon until its inventory is read again.

## Technical notes

- Storage bucket `item-icons` (public, `file_size_limit` 64 KB, `allowed_mime_types` image/webp + image/png). Object names
  are `<campaign id>/<random uuid>.webp`: they contain no item id or name and cannot be guessed. Only the campaign's DMs can
  upload into the campaign folder or list it; there is no update or delete policy.
- `campaign_item_icons (campaign_id, item_id, object_path)` stores only the short path, never image bytes. Writes only through
  `dm_set_item_icon`; the DM's list is `get_campaign_item_icons`.
- The app gives a player the path only as `v_inventory_detail.custom_icon`, which is NULL whenever that copy is masked for
  them (the same rule that hides its `item_id`). This works for the fluent bundle and the `?fluent=0` read alike, with no
  extra request: the icon is one cached image request per distinct icon, like any other icon. Measured locally (45 rows):
  the view costs the same as before (player 14.0 ms, DM 21.4-21.8 ms, best of 30, before and after).
- Per user, not per copy, outside the app: the table's read policy lets a campaign member read the mapping row of an item
  whose catalog row they can already read (items RLS). So a player whose OTHER character knows the item (or who sees an
  identified copy in the party stash) can fetch that item's icon path with a hand-written REST query, even for a copy that
  is disguised on this character. This is the same per-user boundary that already applies to the item's name and
  description (catalog row); it never opens anything a player could not read before.
- Why public and not private with signed URLs: a private bucket needs one extra Storage request per sheet open to sign the
  URLs, and the signed URLs change, so the browser cannot cache the images. The secret is the path, and only a viewer who
  knows the item ever receives it. Residual: someone who once received an icon URL (because they knew the item) can still
  open that URL after the DM hides the item again or replaces the icon.
- Rollback `supabase/rollback/rollback_custom_item_icons.sql` drops the table, functions, trigger and policies and restores the
  views, but keeps the bucket and all uploaded files (harmless: unreferenced and unlisted).
- Tests: `supabase/tests/classes/custom_item_icons_tests.sql`, `supabase/tests/browser/custom_icons_ui_test.py`.
