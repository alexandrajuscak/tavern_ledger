# Deployment: production smoke test results (Phase H)

**Status: NOT STARTED** (production is not deployed).

Checklist (non-destructive; every synthetic artefact is removed afterwards):

- **Player:** sign in; Home; the imported character; derived HP and AC; six abilities; skills; Spells; Inventory; Build;
  export; sign out.
- **DM:** DM Space; campaign; Party; Approvals; Content; Hidden; Campaign rules; Audit.
- **Security:**
  - RLS active;
  - an unidentified item's true name is absent for the player;
  - a hidden condition is absent;
  - the player cannot open DM Space;
  - an outsider cannot open the character;
  - audit filtering works;
  - the session is cleared on sign-out.
- **Realtime:** HP between two sessions; a slot update; an approval; refresh after reconnect.
- **Network:** only the production Supabase host; no localhost, staging or jsDelivr request; no missing asset; no
  service-role value.
