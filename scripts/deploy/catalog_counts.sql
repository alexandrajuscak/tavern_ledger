-- Catalog counts after the one-time seed import (read only). Expected values: docs/DEPLOYMENT_PRODUCTION_SEEDS.md
select 'items' as catalog, count(*) as n, 1146 as expected from public.items
union all select 'spell_versions', count(*), 574 from public.spell_versions
union all select 'class_versions', count(*), 13 from public.class_versions
union all select 'subclass_versions', count(*), 118 from public.subclass_versions
union all select 'class_feature_versions', count(*), 246 from public.class_feature_versions
union all select 'creatures', count(*), 334 from public.creatures
union all select 'lineage_versions', count(*), 133 from public.lineage_versions
union all select 'feat_versions', count(*), 408 from public.feat_versions
union all select 'background_versions', count(*), 30 from public.background_versions
union all select 'source_books', count(*), 58 from public.source_books;
