-- Course enum (ORB 1..5) + parked C5 kit + required-stock view + removable students.
-- Run in the Supabase SQL editor after the earlier files. Safe to re-run.

-- 1) course enum
do $$ begin
  if not exists (select 1 from pg_type where typname='course') then
    create type course as enum ('ORB 1','ORB 2','ORB 3','ORB 4','ORB 5');
  end if;
end $$;

-- 2) tag kits with their course, add a parked C5 kit
alter table kits add column if not exists course course;
update kits set course='ORB 1' where code='C1';
update kits set course='ORB 2' where code='C2';
update kits set course='ORB 3' where code='C3';
update kits set course='ORB 4' where code='C4';
insert into kits(code,name,audience,course_level,course)
  values ('C5','Course 5','older',5,'ORB 5')
  on conflict (code) do update set course=excluded.course;

-- 3) students.current_course -> enum (null out anything that isn't a valid label)
update students set current_course=null
  where current_course is not null and current_course not in ('ORB 1','ORB 2','ORB 3','ORB 4','ORB 5');
alter table students alter column current_course type course using current_course::course;

-- 4) make students removable: keep history, null the link on delete
alter table issues    drop constraint if exists issues_student_id_fkey;
alter table issues    add  constraint issues_student_id_fkey
  foreign key (student_id) references students(id) on delete set null;
alter table movements drop constraint if exists movements_student_id_fkey;
alter table movements add  constraint movements_student_id_fkey
  foreign key (student_id) references students(id) on delete set null;

-- 5) required stock = students per course x that course's kit BOM
create or replace view v_required as
select c.id, c.urn, c.name, c.subgroup,
  coalesce(sum(ki.qty * cc.n),0)::int as required
from components c
  left join kit_items ki on ki.component_id = c.id
  left join (select k.id kit_id, count(s.id) n
             from kits k left join students s on s.current_course = k.course
             group by k.id) cc on cc.kit_id = ki.kit_id
group by c.id;

create or replace view v_requirements as
select r.id, r.urn, r.name, r.subgroup, r.required,
  s.in_storage, greatest(r.required - s.in_storage,0)::int as shortfall
from v_required r join v_stock s on s.id = r.id;

alter view v_required     set (security_invoker = on);
alter view v_requirements set (security_invoker = on);
