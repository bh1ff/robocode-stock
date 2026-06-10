-- ROBOCODE Stock Management — Supabase schema (run in Supabase SQL editor)
-- Model: every component is in one of three states (storage / held / gone).
-- Every event is a row in `movements`. Stock levels are derived, never edited directly.

-- ---------- enums ----------
create type audience      as enum ('older','younger');
create type issue_type    as enum ('rent','buy');           -- rent = free loan, buy = paid
create type issue_status  as enum ('held','returned','sold','lost');
create type move_type     as enum ('purchase_in','issue_rent','issue_buy','return','loss','replacement','adjustment');

-- ---------- reference data ----------
create table franchises (
  id    serial primary key,
  name  text unique not null                                -- 'Shirley', 'Leicester'
);

create table components (
  id            bigint generated always as identity primary key,
  urn           text unique not null,                       -- B-001, S-006, younger codes...
  name          text not null,
  subgroup      text,                                       -- Boards / Sensors / ...
  audience      audience not null default 'older',
  unit_cost     numeric(10,2) default 0,                    -- what it costs us
  url_ali       text,
  url_amz       text,
  reorder_level int default 0,                              -- low-stock threshold
  notes         text,
  created_at    timestamptz default now()
);

create table kits (
  id           bigint generated always as identity primary key,
  code         text unique not null,                        -- C1..C4, YB-OPERATION, YB-ARDUINO...
  name         text not null,
  audience     audience not null,
  course_level int,
  buy_price    numeric(10,2) default 0,                     -- price to customer if bought
  rent_price   numeric(10,2) default 0,                     -- 0 = free loan
  notes        text
);

create table kit_items (                                    -- the bill of materials
  id           bigint generated always as identity primary key,
  kit_id       bigint references kits(id) on delete cascade,
  component_id bigint references components(id),
  qty          int not null check (qty > 0),
  unique (kit_id, component_id)
);

create table students (
  id             bigint generated always as identity primary key,
  name           text not null,
  franchise_id   int references franchises(id),
  current_course text,
  parent_contact text,
  notes          text,
  created_at     timestamptz default now()
);

-- ---------- transactional core ----------
create table issues (                                       -- one row per kit handed out
  id           bigint generated always as identity primary key,
  student_id   bigint references students(id),
  kit_id       bigint references kits(id),
  franchise_id int references franchises(id),
  type         issue_type not null,
  status       issue_status not null default 'held',
  issued_at    timestamptz default now(),
  due_at       date,                                        -- expected back (rent)
  returned_at  timestamptz,
  price        numeric(10,2) default 0,                     -- charged (buy); 0 for free rent
  notes        text
);

create table movements (                                    -- the ledger; stock derives from this
  id           bigint generated always as identity primary key,
  component_id bigint references components(id),
  qty          int not null check (qty > 0),
  type         move_type not null,
  issue_id     bigint references issues(id) on delete set null,
  student_id   bigint references students(id),
  staff        text,                                        -- teacher who issued (lost/extra log)
  class_label  text,                                        -- class / session
  reason       text,
  occurred_at  timestamptz default now()
);
create index on movements (component_id);
create index on movements (issue_id);

-- ---------- derived stock view ----------
-- storage = on shelf, held = out on loan, gone = sold/lost
create view v_stock as
select c.id, c.urn, c.name, c.subgroup, c.audience, c.unit_cost, c.reorder_level,
  coalesce(sum(case m.type
     when 'purchase_in' then m.qty when 'return' then m.qty when 'adjustment' then m.qty
     when 'issue_rent' then -m.qty when 'issue_buy' then -m.qty when 'replacement' then -m.qty
     else 0 end),0)                                              as in_storage,
  coalesce(sum(case m.type
     when 'issue_rent' then m.qty when 'return' then -m.qty when 'loss' then -m.qty
     else 0 end),0)                                              as on_loan,
  coalesce(sum(case m.type
     when 'issue_buy' then m.qty when 'loss' then m.qty when 'replacement' then m.qty
     else 0 end),0)                                              as gone
from components c left join movements m on m.component_id = c.id
group by c.id;

-- kits currently out on loan (the "monthly holders" report)
create view v_open_loans as
select i.*, s.name as student, k.name as kit_name, f.name as franchise
from issues i
  join students s on s.id = i.student_id
  join kits k     on k.id = i.kit_id
  left join franchises f on f.id = i.franchise_id
where i.type = 'rent' and i.status = 'held';

-- course / kit cost = sum of component cost across the BOM
create view v_kit_cost as
select k.id, k.code, k.name, k.audience, k.buy_price, k.rent_price,
  coalesce(sum(ki.qty * c.unit_cost),0)            as kit_cost,
  k.buy_price - coalesce(sum(ki.qty * c.unit_cost),0) as buy_margin
from kits k
  left join kit_items ki on ki.kit_id = k.id
  left join components c  on c.id = ki.component_id
group by k.id;

-- ---------- functions: keep stock consistent ----------
-- issue a whole kit: makes the issue row + one movement per BOM line
create or replace function issue_kit(p_student bigint, p_kit bigint, p_type issue_type,
                                     p_due date default null, p_price numeric default 0,
                                     p_staff text default null)
returns bigint language plpgsql as $$
declare v_issue bigint; v_fr int; r record;
begin
  select franchise_id into v_fr from students where id = p_student;
  insert into issues(student_id, kit_id, franchise_id, type, status, due_at, price)
    values (p_student, p_kit, v_fr, p_type, case when p_type='buy' then 'sold' else 'held' end, p_due, p_price)
    returning id into v_issue;
  for r in select component_id, qty from kit_items where kit_id = p_kit loop
    insert into movements(component_id, qty, type, issue_id, student_id, staff, reason)
      values (r.component_id, r.qty,
              case when p_type='buy' then 'issue_buy' else 'issue_rent' end,
              v_issue, p_student, p_staff, 'kit '||p_type);
  end loop;
  return v_issue;
end $$;

-- return a rented kit: mirrors its issue_rent rows back into storage
create or replace function return_issue(p_issue bigint)
returns void language plpgsql as $$
declare r record;
begin
  update issues set status='returned', returned_at=now() where id=p_issue and type='rent';
  for r in select component_id, qty from movements where issue_id=p_issue and type='issue_rent' loop
    insert into movements(component_id, qty, type, issue_id, reason)
      values (r.component_id, r.qty, 'return', p_issue, 'kit return');
  end loop;
end $$;

-- ---------- security: internal staff only ----------
alter table franchises enable row level security;
alter table components enable row level security;
alter table kits       enable row level security;
alter table kit_items  enable row level security;
alter table students   enable row level security;
alter table issues     enable row level security;
alter table movements  enable row level security;
-- any signed-in staff member can read/write everything
create policy staff_all on franchises for all to authenticated using (true) with check (true);
create policy staff_all on components for all to authenticated using (true) with check (true);
create policy staff_all on kits       for all to authenticated using (true) with check (true);
create policy staff_all on kit_items  for all to authenticated using (true) with check (true);
create policy staff_all on students   for all to authenticated using (true) with check (true);
create policy staff_all on issues     for all to authenticated using (true) with check (true);
create policy staff_all on movements  for all to authenticated using (true) with check (true);

-- seed franchises (Shirley first)
insert into franchises(name) values ('Shirley'), ('Leicester');
