# ⚔ Tavern Ledger

A lightweight, mobile-first **D&D 5e character sheet** for a small private campaign.
It's plain HTML, CSS and JavaScript, uses Supabase for login and storage, and is hosted on GitHub Pages. There is no build step.

- Google and email login, with one account per player
- Every edit saves automatically to Supabase and syncs live to your other devices
- A sticky combat bar keeps HP, AC, initiative, speed, conditions and resources on screen
- **Source-of-truth data only**: skill, save, passive, initiative and attack bonuses are always calculated, never stored (see `docs/DATA_MODEL.md`)
- Abilities, saves, skills (with expertise), hit dice and death saves
- Custom resource trackers: Ki, Rage, Sorcery Points, Bardic Inspiration, Wild Shape and any others you add
- **Combat tab** (the default screen): a "how your turn works" guide, weapon cards with big “To hit” and “Damage” numbers, then everything you can do grouped as **Actions, Bonus Actions and Reactions** (features and spells together), with Passive Features folded away
- **Spells**: grouped as Cantrips / Level 1–9, each card shows casting time, range, duration, components, concentration/ritual, spell attack or save DC, and damage or healing
- Spell slots for levels 1–9 as tick boxes
- Inventory with quantity, weight and description, plus coins
- Features tab: each feature has a **type** (Action, Bonus Action, Reaction, Passive) that decides where it appears in combat, and a source (racial, class, background, feat, custom, magic item)
- **Conditions**: Prone, Grappled, Restrained, Poisoned, Blessed, Concentrating and the rest, plus custom ones; tap a condition to read what it does
- Notes: character notes, session notes and campaign notes
- **Portraits**: upload an image (resized automatically) or paste an image URL
- **JSON import / export** of whole characters (`docs/character.schema.json`). Keep real character files in `examples/`, which git ignores so they stay off GitHub
- **Level Up Wizard**: set the new level, HP gain, subclass, features, resource pools and spell slots in one flow
- **Campaigns**: an admin creates campaigns and adds people as **DMs** or **players**. A campaign's DMs see and edit every character in it (level ups, owners); players see their own characters
- Short and long rest buttons that restore the right resources

---

## Project structure

```
.
├── index.html            App shell
├── .nojekyll             Tells GitHub Pages to serve files as-is
├── css/
│   └── styles.css        Theme and responsive layout
├── js/
│   ├── config.js         ← your Supabase URL + publishable key go here
│   ├── supabase.js       Supabase client (loaded from CDN, no npm)
│   ├── app.js            Boot, auth, routing, character list, DM players page
│   ├── store.js          Data access, auto-save queue, realtime subscriptions
│   ├── sheet.js          Character sheet UI
│   ├── levelup.js        Level Up Wizard
│   ├── dnd.js            5e reference data (skills, XP table, presets…)
│   ├── transfer.js       Character JSON import / export
│   └── utils.js          DOM helpers, modals, toasts, cache
└── supabase/
    └── schema.sql        Tables, RLS policies, triggers, realtime setup
```

### Data model

| Table              | Purpose                                                                    |
|--------------------|----------------------------------------------------------------------------|
| `profiles`         | One per auth user: display name and role (`player` / `dm`)                 |
| `characters`       | Identity, combat stats, abilities, proficiencies, coins. Owned by a profile |
| `inventory_items`  | Items per character                                                        |
| `notes`            | One row per kind: `character`, `quest`, `campaign`, `spells`, `attacks`    |
| `spell_slots`      | One row per spell level 1–9 (`total`, `used`)                              |
| `feature_trackers` | Resource pools (`current`, `max`, `reset_on`)                              |
| `features`         | Free-text features grouped by category                                     |
| `attacks`          | Weapons & attacks: ability, proficiency, magic bonus, damage dice and type |
| `spells`           | Spells by level with casting details, attack/save and damage              |

New characters get their `notes` and `spell_slots` rows from a database trigger. Row Level Security limits each player to their own characters, and lets the DM see and edit all of them.

---

## Setup

### 1. Create a Supabase project

1. Sign up at <https://supabase.com> and create a new project. The free tier is plenty.
2. Open **SQL Editor → New query**, paste the full contents of `supabase/schema.sql` and click **Run**.
   The script is idempotent, so you can run it again later without breaking anything.

### 2. Configure authentication

In **Authentication → URL Configuration**:

- **Site URL**: your GitHub Pages URL, e.g. `https://<user>.github.io/<repo>/`
- **Redirect URLs**: add the same URL, plus `http://localhost:8000/` for local testing.

**Email login** is on by default under **Authentication → Providers → Email**.
For a private group you can turn off *Confirm email* so new accounts work straight away.

**Google login**:

1. In [Google Cloud Console](https://console.cloud.google.com/), go to **APIs & Services → Credentials → Create credentials → OAuth client ID** and choose *Web application*.
2. Under **Authorized redirect URIs**, add the callback URL that Supabase shows in **Authentication → Providers → Google**. It looks like `https://<project-ref>.supabase.co/auth/v1/callback`.
3. Copy the Client ID and Client Secret into Supabase's Google provider settings and enable it.
4. If Google asks you to configure the OAuth consent screen, set it to *External* and add your players as test users, or publish it.

### 3. Add your keys

Open `js/config.js` and paste the Project URL and the **publishable** key from **Project Settings → API Keys**:

```js
export const SUPABASE_URL = 'https://abcdefghijkl.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_...';
```

The publishable key is meant to be public and safe to commit. Row Level Security is what protects the data. Never put the secret key (`sb_secret_...`) in this file.

### 4. Become the admin

Sign in to the app once so your profile exists. Then run this in the SQL Editor:

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

Reload the app and you'll see a red **ADMIN** badge. Use **⚙ Manage** to create campaigns, add players and co-DMs to them, and rename people. New players appear on the Manage page after their first sign-in.

### 5. Run locally (optional)

ES modules don't load from `file://`, so serve the folder over HTTP:

```bash
python -m http.server 8000
# open http://localhost:8000/
```

---

## Deploy to GitHub Pages

```bash
git init
git add .
git commit -m "Tavern Ledger"
git branch -M main
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```

1. On GitHub, open the repo's **Settings → Pages**.
2. Under **Build and deployment**, choose **Source: Deploy from a branch**, **Branch: `main` / `(root)`**, then **Save**.
3. Wait about a minute. The site goes live at `https://<user>.github.io/<repo>/`.
4. Make sure that exact URL is in Supabase's **Site URL** and **Redirect URLs** (step 2 above).

There's no build step: every push to `main` redeploys.

---

## How it works

**Auto-save.** Each edit updates the screen right away and goes into a save queue. Changes to the same row are merged and written about 0.6 s after you stop typing. If a write fails, it's retried with backoff. The top bar shows *Editing… / Saving… / Saved ✓ / Offline — will sync*. If you try to close the tab with unsaved changes, the browser warns you.

**Sync between devices.** The sheet subscribes to Supabase Realtime for the open character. Changes made on another device or by the DM appear live. A field you are editing at that moment is never overwritten.

**LocalStorage.** This is only a cache, used for the last character list, the last sheet (shown greyed out while fresh data loads), the selected tab and the combat-bar collapse state. Supabase is always the source of truth.

**Level Up Wizard.** The wizard helps with editing. It doesn't enforce class rules. It suggests average HP (hit die average + CON modifier), and you can switch to a rolled value or a custom number. You can also set a subclass, add features, raise resource maximums, add new resource pools and adjust spell slots. Nothing is saved until you press **Apply level up** on the review step.

**Rests.**
- *Short rest* restores trackers set to "Short rest".
- *Long rest* restores HP and all short- and long-rest trackers, clears spell slots, temp HP and death saves, and recovers half your hit dice.

**Phone tips.** Tap the small ▴ tab under the combat bar to collapse it to a single line. In the damage box, Enter applies damage and Shift+Enter heals.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Almost there" screen | `js/config.js` still has placeholder values. |
| "Could not load your profile" | `supabase/schema.sql` hasn't been run, or it failed. Run it again. |
| Google login returns to the wrong page | The GitHub Pages URL is missing from Supabase **Redirect URLs**. |
| Changes don't show live on another device | Check **Database → Publications → supabase_realtime** includes the tables. The schema adds them. |
| Player sees no characters after the DM created one | Check that the player is a member of the campaign (**⚙ Manage**) and is set as the owner in the sheet's **Bio** tab. |

---

## Updating an existing installation

When a new version changes the database, re-run `supabase/schema.sql` in the SQL Editor **before** pushing the new code. The script is idempotent: it adds new tables and columns and leaves your data alone.

### Making sure players get the new version

Browsers cache the app's files. Every script and stylesheet link carries a version tag (`?v=7`). When you change the code, bump the number everywhere so phones and tablets load the new files straight away:

```bash
sed -i "s/?v=7/?v=8/g" index.html js/*.js
```
