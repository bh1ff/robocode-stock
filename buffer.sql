-- Per-component buffer = reserved stock you keep above the required amount
-- (e.g. extra Arduinos for heavy use). Target = required + buffer.
-- Run in the Supabase SQL editor after students_courses.sql. Safe to re-run.

alter table components add column if not exists buffer int default 0;

drop view if exists v_requirements;
create view v_requirements as
select r.id, r.urn, r.name, r.subgroup, r.required,
  coalesce(c.buffer,0)                                            as buffer,
  (r.required + coalesce(c.buffer,0))                            as target,
  s.in_storage,
  greatest(r.required + coalesce(c.buffer,0) - s.in_storage,0)::int as shortfall
from v_required r
  join v_stock s    on s.id = r.id
  join components c on c.id = r.id;

alter view v_requirements set (security_invoker = on);
