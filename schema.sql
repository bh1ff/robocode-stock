-- ============================================================================
-- ROBOCODE Kit Stock  —  schema v2 (kit-based)
--
-- v1 tracked every component through a movements ledger. This does not.
-- We track FINISHED KITS: how many we built, where they went, who owes money,
-- and what is still out on loan.
--
-- Run in the Supabase SQL editor. Destroys the v1 tables — see legacy/ for those.
-- ============================================================================

-- ---------- retire v1 ----------
-- Pure stock plumbing is dropped. Tables holding real-world data (franchises,
-- students, kits) are RENAMED to *_v1 and migrated below, so nothing is lost.
-- Once you are happy, drop the _v1 tables by hand.
drop view     if exists v_stock, v_open_loans, v_kit_cost cascade;
drop function if exists issue_kit(bigint,bigint,issue_type,date,numeric,text) cascade;
drop function if exists return_issue(bigint) cascade;
drop table    if exists movements, issues, kit_items, components cascade;

do $$ begin
  if to_regclass('public.kits')       is not null and to_regclass('public.kits_v1')       is null
    then alter table kits       rename to kits_v1;       end if;
  if to_regclass('public.students')   is not null and to_regclass('public.students_v1')   is null
    then alter table students   rename to students_v1;   end if;
  if to_regclass('public.franchises') is not null and to_regclass('public.franchises_v1') is null
    then alter table franchises rename to franchises_v1; end if;
end $$;

drop type if exists issue_type, issue_status, move_type cascade;

-- ---------- enums ----------
do $$ begin create type audience as enum ('older','younger'); exception when duplicate_object then null; end $$;
do $$ begin create type customer_type as enum ('franchise','centre','school','individual');
  exception when duplicate_object then null; end $$;
do $$ begin create type line_kind     as enum ('sale','loan');
  exception when duplicate_object then null; end $$;
do $$ begin create type line_status   as enum ('out','returned','lost');
  exception when duplicate_object then null; end $$;
do $$ begin create type kit_move_type as enum ('built','out','returned','written_off','adjustment');
  exception when duplicate_object then null; end $$;
do $$ begin create type request_status as enum ('pending','approved','rejected','done');
  exception when duplicate_object then null; end $$;

-- ---------- teachers: kiosk users, identified by a code ----------
-- There is exactly ONE real login (a Supabase Auth user = the superadmin).
-- Teachers never get a session. They type a code into the kiosk and can only
-- raise requests, through the SECURITY DEFINER functions in kiosk.sql.
--
-- v1/v2 teachers had username + password. Retire that shape if present.
do $$ begin
  if to_regclass('public.teachers') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='teachers' and column_name='pass_hash')
     and to_regclass('public.teachers_v1') is null
  then alter table teachers rename to teachers_v1; end if;
end $$;

create table if not exists teachers (
  id         bigint generated always as identity primary key,
  name       text not null,
  code_hash  text unique not null,      -- sha256(code + pepper); the code itself is never stored
  active     boolean default true,
  created_at timestamptz default now()
);

-- failed kiosk attempts, so abuse is visible
create table if not exists kiosk_attempts (
  id         bigint generated always as identity primary key,
  at         timestamptz default now(),
  note       text
);

-- ---------- who we deal with ----------
create table customers (
  id           bigint generated always as identity primary key,
  name         text not null,
  type         customer_type not null default 'franchise',
  contact_name text,
  email        text,
  phone        text,
  address      text,
  notes        text,
  active       boolean default true,
  created_at   timestamptz default now(),
  unique (name, type)
);

-- Proper address fields. Added after the fact, so this runs whether the table is
-- new or already live. The old single-line `address` is folded into address1.
alter table customers add column if not exists address1 text;
alter table customers add column if not exists address2 text;
alter table customers add column if not exists city     text;
alter table customers add column if not exists postcode text;
alter table customers add column if not exists country  text default 'United Kingdom';

do $$ begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='customers' and column_name='address') then
    update customers set address1 = address
      where address is not null and btrim(address) <> '' and address1 is null;
    alter table customers drop column address;
  end if;
end $$;

-- students sit under a customer (a franchise, centre or school).
-- An individual customer buying one kit needs no student row.
create table students (
  id             bigint generated always as identity primary key,
  name           text not null,
  customer_id    bigint references customers(id) on delete set null,
  current_course text,
  parent_contact text,
  notes          text,
  active         boolean default true,
  created_at     timestamptz default now()
);
create index on students (customer_id);

-- ---------- what we sell ----------
create table kits (
  id            bigint generated always as identity primary key,
  code          text unique not null,          -- C1..C4, YB1..YB10
  name          text not null,
  audience      audience not null,
  sort_order    int default 0,
  unit_cost     numeric(10,2) default 0,       -- what a built kit costs us, landed
  price_trade   numeric(10,2) default 0,       -- price to a franchise
  price_retail  numeric(10,2) default 0,       -- price to an individual
  active        boolean default true,
  notes         text
);

-- ---------- orders ----------
create table orders (
  id           bigint generated always as identity primary key,
  ref          text unique,                    -- filled by trigger: RC-0001
  customer_id  bigint not null references customers(id),
  teacher_id   bigint references teachers(id), -- who requested it
  order_date   date not null default current_date,
  paid         boolean not null default false,
  paid_at      timestamptz,
  payment_ref  text,                           -- cheque no, transfer ref, "cash"
  notes        text,
  created_at   timestamptz default now()
);
create index on orders (customer_id);
create index on orders (paid);

create table order_lines (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references orders(id) on delete cascade,
  kit_id      bigint not null references kits(id),
  student_id  bigint references students(id),  -- named child, for single loans/sales
  kind        line_kind not null default 'sale',
  qty         int not null check (qty > 0),
  unit_price  numeric(10,2) not null default 0,
  due_date    date,                            -- loans: when it should come back
  status      line_status not null default 'out',
  returned_at timestamptz,
  notes       text
);
create index on order_lines (order_id);
create index on order_lines (kit_id);
create index on order_lines (status);

-- ---------- built-kit stock ledger ----------
-- Stock is DERIVED from this table. Never edit a stock number directly.
-- delta is signed: +30 built, -40 sent out, +1 returned.
create table kit_moves (
  id            bigint generated always as identity primary key,
  kit_id        bigint not null references kits(id),
  delta         int not null check (delta <> 0),
  type          kit_move_type not null,
  order_line_id bigint references order_lines(id) on delete cascade,
  teacher_id    bigint references teachers(id),
  note          text,
  occurred_at   timestamptz default now()
);
create index on kit_moves (kit_id);
create index on kit_moves (order_line_id);

-- ---------- replacement parts log (no stock counts, just a record) ----------
create table parts (
  id       bigint generated always as identity primary key,
  urn      text unique not null,
  name     text not null,
  unit_cost numeric(10,4) default 0,
  active   boolean default true
);

-- a teacher asking for a part: "Amir needs a new Arduino, his is dead"
create table item_requests (
  id          bigint generated always as identity primary key,
  part_id     bigint references parts(id),
  student_id  bigint references students(id),
  customer_id bigint references customers(id),
  teacher_id  bigint references teachers(id),
  qty         int not null default 1 check (qty > 0),
  reason      text,
  status      request_status not null default 'pending',
  handled_at  timestamptz,
  handled_note text,
  created_at  timestamptz default now()
);
create index on item_requests (status);
create index on item_requests (created_at);

-- a teacher asking for a kit for a named child
create table kit_requests (
  id          bigint generated always as identity primary key,
  kit_id      bigint not null references kits(id),
  student_id  bigint references students(id),
  customer_id bigint references customers(id),
  teacher_id  bigint references teachers(id),
  qty         int not null default 1 check (qty > 0),
  kind        line_kind not null default 'loan',
  needed_by   date,
  reason      text,
  status      request_status not null default 'pending',
  order_id    bigint references orders(id) on delete set null,
  handled_at  timestamptz,
  handled_note text,
  created_at  timestamptz default now()
);
create index on kit_requests (status);
create index on kit_requests (created_at);

-- ============================================================================
-- triggers: keep the ledger honest
-- ============================================================================

-- human-readable order reference
create or replace function _set_order_ref() returns trigger language plpgsql as $$
begin
  if new.ref is null then new.ref := 'RC-' || lpad(new.id::text, 4, '0'); end if;
  return new;
end $$;
create trigger t_order_ref before insert on orders
  for each row execute function _set_order_ref();

-- a line going out removes kits from stock; deleting it puts them back
create or replace function _line_stock() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into kit_moves(kit_id, delta, type, order_line_id, note)
      values (new.kit_id, -new.qty, 'out', new.id, 'order line');

  elsif tg_op = 'UPDATE' then
    -- quantity or kit changed while still out: restate the movement
    if new.status = 'out' and old.status = 'out'
       and (new.qty <> old.qty or new.kit_id <> old.kit_id) then
      delete from kit_moves where order_line_id = new.id and type = 'out';
      insert into kit_moves(kit_id, delta, type, order_line_id, note)
        values (new.kit_id, -new.qty, 'out', new.id, 'order line (amended)');
    end if;
    -- loan came back
    if new.status = 'returned' and old.status <> 'returned' then
      insert into kit_moves(kit_id, delta, type, order_line_id, note)
        values (new.kit_id, new.qty, 'returned', new.id, 'loan returned');
      new.returned_at := coalesce(new.returned_at, now());
    end if;
    -- written off
    if new.status = 'lost' and old.status = 'returned' then
      insert into kit_moves(kit_id, delta, type, order_line_id, note)
        values (new.kit_id, -new.qty, 'written_off', new.id, 'marked lost after return');
    end if;
  end if;
  return new;
end $$;
create trigger t_line_stock_ins after insert on order_lines
  for each row execute function _line_stock();
create trigger t_line_stock_upd before update on order_lines
  for each row execute function _line_stock();

-- stamp paid_at whenever paid flips on
create or replace function _stamp_paid() returns trigger language plpgsql as $$
begin
  if new.paid and not coalesce(old.paid, false) then new.paid_at := coalesce(new.paid_at, now());
  elsif not new.paid then new.paid_at := null; end if;
  return new;
end $$;   -- OLD is null on INSERT, so coalesce() keeps this safe for both triggers
create trigger t_stamp_paid before update on orders
  for each row execute function _stamp_paid();
create trigger t_stamp_paid_ins before insert on orders
  for each row execute function _stamp_paid();

-- ============================================================================
-- views: what the app actually reads
-- ============================================================================

-- built / out / available per kit type
create view v_kit_stock as
select k.id, k.code, k.name, k.audience, k.sort_order,
       k.unit_cost, k.price_trade, k.price_retail,
  coalesce(sum(m.delta) filter (where m.type = 'built'),0)                as built,
  coalesce(sum(-m.delta) filter (where m.type = 'out'),0)                 as sent_out,
  coalesce(sum(m.delta) filter (where m.type = 'returned'),0)             as returned,
  coalesce(sum(-m.delta) filter (where m.type = 'written_off'),0)         as written_off,
  coalesce(sum(m.delta),0)                                                as available
from kits k left join kit_moves m on m.kit_id = k.id
where k.active
group by k.id;

-- one row per order with its money and its contents summarised
create view v_orders as
select o.id, o.ref, o.order_date, o.paid, o.paid_at, o.payment_ref, o.notes,
       c.id as customer_id, c.name as customer, c.type as customer_type,
       t.name as requested_by,
       coalesce(sum(l.qty) filter (where l.kind='sale'),0)                  as kits_sold,
       coalesce(sum(l.qty) filter (where l.kind='loan'),0)                  as kits_loaned,
       coalesce(sum(l.qty * l.unit_price) filter (where l.kind='sale'),0)   as total_due,
       count(l.id) filter (where l.kind='loan' and l.status='out')          as loans_open
from orders o
  join customers c on c.id = o.customer_id
  left join teachers t on t.id = o.teacher_id
  left join order_lines l on l.order_id = o.id
group by o.id, c.id, t.name;

-- money outstanding
create view v_money_owed as
select * from v_orders where total_due > 0 and not paid;

-- what is out on loan, and how late
create view v_open_loans as
select l.id as line_id, o.ref, o.order_date, o.id as order_id,
       c.name as customer, c.type as customer_type,
       s.name as student, k.code as kit_code, k.name as kit_name,
       l.qty, l.due_date, t.name as requested_by,
       case when l.due_date is null then null
            else (current_date - l.due_date) end                   as days_overdue
from order_lines l
  join orders o    on o.id = l.order_id
  join customers c on c.id = o.customer_id
  join kits k      on k.id = l.kit_id
  left join students s on s.id = l.student_id
  left join teachers t on t.id = o.teacher_id
where l.kind = 'loan' and l.status = 'out';

-- per-customer position
create view v_customer_balance as
select c.id, c.name, c.type,
  count(distinct o.id)                                            as orders,
  coalesce(sum(v.total_due) filter (where not v.paid),0)           as owed,
  coalesce(sum(v.total_due),0)                                     as lifetime_value,
  coalesce(sum(v.loans_open),0)                                    as loans_open
from customers c
  left join orders o on o.customer_id = c.id
  left join v_orders v on v.id = o.id
group by c.id;

-- what teachers have asked for, waiting on the superadmin
create view v_kit_requests as
select r.id, r.qty, r.kind, r.needed_by, r.reason, r.status, r.created_at,
       r.handled_at, r.handled_note, r.order_id,
       k.id as kit_id, k.code as kit_code, k.name as kit_name,
       s.id as student_id, s.name as student,
       c.id as customer_id, c.name as customer,
       t.name as teacher,
       st.available as kit_available
from kit_requests r
  join kits k on k.id = r.kit_id
  left join students s   on s.id = r.student_id
  left join customers c  on c.id = coalesce(r.customer_id, s.customer_id)
  left join teachers t   on t.id = r.teacher_id
  left join v_kit_stock st on st.id = r.kit_id;

create view v_item_requests as
select r.id, r.qty, r.reason, r.status, r.created_at, r.handled_at, r.handled_note,
       p.urn, p.name as part,
       s.name as student, c.name as customer, t.name as teacher
from item_requests r
  left join parts p     on p.id = r.part_id
  left join students s  on s.id = r.student_id
  left join customers c on c.id = coalesce(r.customer_id, s.customer_id)
  left join teachers t  on t.id = r.teacher_id;

-- ============================================================================
-- helper functions
-- ============================================================================

-- record a batch of kits as built
create or replace function build_kits(p_kit bigint, p_qty int, p_note text default null)
returns bigint language plpgsql security invoker as $$
declare v_id bigint;
begin
  if p_qty = 0 then raise exception 'quantity cannot be zero'; end if;
  insert into kit_moves(kit_id, delta, type, note)
    values (p_kit, p_qty, case when p_qty > 0 then 'built' else 'adjustment' end, p_note)
    returning id into v_id;
  return v_id;
end $$;

-- approve a kit request and raise the order for it in one step
create or replace function fulfil_kit_request(p_req bigint, p_note text default null)
returns bigint language plpgsql security invoker as $$
declare r record; v_cust bigint; v_order bigint; v_price numeric;
begin
  select * into r from kit_requests where id = p_req;
  if r is null then raise exception 'request % not found', p_req; end if;
  if r.status = 'done' then raise exception 'request % already fulfilled', p_req; end if;

  v_cust := coalesce(r.customer_id, (select customer_id from students where id = r.student_id));
  if v_cust is null then
    raise exception 'no customer on the request or the student - set one before fulfilling';
  end if;

  select case when c.type = 'individual' then k.price_retail else k.price_trade end
    into v_price from kits k, customers c where k.id = r.kit_id and c.id = v_cust;

  insert into orders (customer_id, teacher_id, notes)
    values (v_cust, r.teacher_id, coalesce(p_note, 'from kit request #' || p_req))
    returning id into v_order;

  insert into order_lines (order_id, kit_id, student_id, kind, qty, unit_price, due_date)
    values (v_order, r.kit_id, r.student_id, r.kind, r.qty,
            case when r.kind = 'sale' then coalesce(v_price,0) else 0 end,
            case when r.kind = 'loan' then coalesce(r.needed_by, current_date + 90) end);

  update kit_requests
     set status = 'done', order_id = v_order, handled_at = now(), handled_note = p_note
   where id = p_req;
  return v_order;
end $$;

-- mark a whole order's loans returned in one go
create or replace function return_order(p_order bigint)
returns int language plpgsql security invoker as $$
declare n int;
begin
  update order_lines set status = 'returned'
    where order_id = p_order and kind = 'loan' and status = 'out';
  get diagnostics n = row_count;
  return n;
end $$;

-- ============================================================================
-- migrate what v1 knew: franchises -> customers, students -> students
-- Safe to re-run; nothing is duplicated.
-- ============================================================================
do $$ begin
  if to_regclass('public.franchises_v1') is not null then
    insert into customers (name, type)
      select f.name, 'franchise'::customer_type from franchises_v1 f
      on conflict (name, type) do nothing;
  end if;

  if to_regclass('public.students_v1') is not null then
    insert into students (name, customer_id, current_course, parent_contact, notes)
      select v.name,
             (select c.id from customers c
                join franchises_v1 f on f.name = c.name
               where f.id = v.franchise_id and c.type = 'franchise'),
             v.current_course, v.parent_contact, v.notes
        from students_v1 v
       where not exists (select 1 from students s where s.name = v.name);
  end if;
end $$;

-- ============================================================================
-- security: signed-in staff can do everything
-- ============================================================================
alter table customers    enable row level security;
alter table students     enable row level security;
alter table kits         enable row level security;
alter table orders       enable row level security;
alter table order_lines  enable row level security;
alter table kit_moves    enable row level security;
alter table parts        enable row level security;
alter table item_requests enable row level security;
alter table kit_requests  enable row level security;
alter table teachers      enable row level security;

drop policy if exists staff_all on customers;
create policy staff_all on customers    for all to authenticated using (true) with check (true);
drop policy if exists staff_all on students;
create policy staff_all on students     for all to authenticated using (true) with check (true);
drop policy if exists staff_all on kits;
create policy staff_all on kits         for all to authenticated using (true) with check (true);
drop policy if exists staff_all on orders;
create policy staff_all on orders       for all to authenticated using (true) with check (true);
drop policy if exists staff_all on order_lines;
create policy staff_all on order_lines  for all to authenticated using (true) with check (true);
drop policy if exists staff_all on kit_moves;
create policy staff_all on kit_moves    for all to authenticated using (true) with check (true);
drop policy if exists staff_all on parts;
create policy staff_all on parts        for all to authenticated using (true) with check (true);
drop policy if exists staff_all on item_requests;
create policy staff_all on item_requests for all to authenticated using (true) with check (true);
drop policy if exists staff_all on kit_requests;
create policy staff_all on kit_requests  for all to authenticated using (true) with check (true);
drop policy if exists admin_all on teachers;
create policy admin_all on teachers      for all to authenticated using (true) with check (true);
