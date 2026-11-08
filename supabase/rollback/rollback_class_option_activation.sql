-- Rollback of 20261107000400_class_option_activation.sql: removes the two keys it added (activation, play) from
-- class_feature_choice_options.data. Before that migration no option had either key (checked 2026-11-07: 0 rows), so removing
-- them restores the previous data exactly. The catalog trigger bumps the global read-cache revision. No character data changes.
-- The new frontend then simply shows selected options on the Build page only (as before).
begin;
update public.class_feature_choice_options set data = data - 'activation' - 'play' where data ? 'activation' or data ? 'play';
commit;
