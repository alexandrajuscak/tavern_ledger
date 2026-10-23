-- Synthetic data that exists BEFORE the inventory migrations (shape of the live project's data).
-- Character 1: one equipped weapon, an equipped shield, equipped items that cannot be migrated, quantity-0 rows.
-- Character 2: two equipped weapons (main/off hand unknown).
insert into auth.users (id, email) values ('f0000000-0000-0000-0000-000000000001', 'legacy@test.invalid.invalid');
insert into public.characters (id, owner_id, name) values
  ('f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-000000000001', 'Legacy Hero'),
  ('f0000000-0000-0000-0000-0000000000c2', 'f0000000-0000-0000-0000-000000000001', 'Legacy Twin Blades');
insert into public.inventory_items (character_id, name, quantity, weight, description, equipped, sort_order) values
  ('f0000000-0000-0000-0000-0000000000c1', 'Quarterstaff',  1, 4,    'worn smooth', true,  0),   -- -> main_hand
  ('f0000000-0000-0000-0000-0000000000c1', 'Shield',        1, 6,    '',            true,  1),   -- -> shield
  ('f0000000-0000-0000-0000-0000000000c1', 'Leather Armor', 1, 10,   '',            true,  2),   -- name is not exact ('Leather'): manual
  ('f0000000-0000-0000-0000-0000000000c1', 'Darts',         10, 0.25, '',           true,  3),   -- not linkable ('Dart'): manual
  ('f0000000-0000-0000-0000-0000000000c1', 'Herbalism Kit', 1, 3,    '',            false, 4),   -- linked, not equipped
  ('f0000000-0000-0000-0000-0000000000c1', 'Spent torch',   0, 1,    '',            false, 5),   -- qty0_manual
  ('f0000000-0000-0000-0000-0000000000c1', 'New item',      0, 0,    '',            false, 6),   -- qty0_empty_placeholder
  ('f0000000-0000-0000-0000-0000000000c1', '',              0, 0,    'mystery',     false, 7),   -- qty0_corrupted
  ('f0000000-0000-0000-0000-0000000000c1', 'Rope',          0, 10,   '',            true,  8),   -- qty0_convertible (+ equipped manual)
  ('f0000000-0000-0000-0000-0000000000c2', 'Longsword',     1, 3,    '',            true,  0),
  ('f0000000-0000-0000-0000-0000000000c2', 'Dagger',        1, 1,    '',            true,  1);
