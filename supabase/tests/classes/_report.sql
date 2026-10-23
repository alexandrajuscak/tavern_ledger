-- ---- report (shared footer of the per-class SQL tests) ----------------------------------------------------------------------------
\o
select case when ok then 'PASSED' else 'FAILED' end || '  ' || name || case when ok then '' else '   <-- ' || coalesce(detail, '') end
from tl_test.results order by n;
select format('%s passed, %s failed', count(*) filter (where ok), count(*) filter (where not ok)) from tl_test.results;
select 1 / (count(*) filter (where not ok) = 0)::int as all_checks_passed from tl_test.results;
rollback;
