-- Younger as a planned-stock category. Each kit can have a planned_qty (how many
-- to keep ready); required stock = students-per-course (older) + planned_qty (younger).
-- Run in the Supabase SQL editor after buffer.sql. Safe to re-run.

alter table kits add column if not exists planned_qty int default 0;
update kits set planned_qty = 20 where audience = 'younger';

-- required demand per kit = students assigned to its course + its planned_qty
create or replace view v_required as
select c.id, c.urn, c.name, c.subgroup,
  coalesce(sum(ki.qty * kd.demand),0)::int as required
from components c
  left join kit_items ki on ki.component_id = c.id
  left join (
    select k.id as kit_id, coalesce(sc.n,0) + coalesce(k.planned_qty,0) as demand
    from kits k
      left join (select current_course as course, count(*) n from students group by current_course) sc
        on sc.course = k.course
    group by k.id, sc.n
  ) kd on kd.kit_id = ki.kit_id
group by c.id;

alter view v_required set (security_invoker = on);
