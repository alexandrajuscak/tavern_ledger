# ⚔ Tavern Ledger

A lightweight, mobile-first **D&D 5e character sheet** for a small private campaign.
It's plain HTML, CSS and JavaScript, uses Supabase for login and storage, and is hosted on GitHub Pages. There is no build step.

- Google and email login, with one account per player
- Every edit saves automatically to Supabase and syncs live to your other devices
- A sticky combat bar keeps HP, AC, initiative, speed and resources on screen
- Abilities, saves, skills (with expertise), hit dice and death saves
- Custom resource trackers: Ki, Rage, Sorcery Points, Bardic Inspiration, Wild Shape and any others you add
- Spell slots for levels 1–9 as tick boxes
- Inventory with quantity, weight and description, plus coins
- Features tab: racial, class, feats, custom and magic item abilities
- Notes: character notes, quest log and campaign notes
- **Level Up Wizard**: set the new level, HP gain, subclass, features, resource pools and spell slots in one flow
- **DM mode**: view and edit every character, run level ups and manage player roles
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

### 4. Become the DM

Sign in to the app once so your profile exists. Then run this in the SQL Editor:

```sql
update public.profiles set role = 'dm' where email = 'you@example.com';
```

Reload the app and you'll see a red **DM** badge. The **Players** page now lets you promote co-DMs and rename players.

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
| Player sees no characters after the DM created one | In the sheet's **Bio** tab, the DM picks the player under *Player (owner)*. |
