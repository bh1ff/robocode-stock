-- Teacher accounts (username + password, no email, no Supabase auth).
-- Teachers act ONLY through the SECURITY DEFINER functions below: they can log
-- a component taking/loss and see their own recent log + the student/component
-- name pickers. They get no other read access.
-- Run in the Supabase SQL editor after schema.sql + security.sql.

create extension if not exists pgcrypto with schema extensions;

create table teachers (
  id         bigint generated always as identity primary key,
  username   text unique not null,
  name       text,
  pass_hash  text not null,
  active     boolean default true,
  created_at timestamptz default now()
);
alter table teachers enable row level security;
-- only signed-in admins can see/manage the teacher table directly
create policy admin_all on teachers for all to authenticated using (true) with check (true);

-- helper: verify a teacher's credentials
create or replace function _teacher_ok(p_user text, p_pass text)
returns bigint language sql security definer set search_path=public,extensions as $$
  select id from teachers
  where username = lower(p_user) and active and pass_hash = crypt(p_pass, pass_hash);
$$;

-- ADMIN: create a teacher (only callable by a signed-in admin)
create or replace function create_teacher(p_user text, p_pass text, p_name text)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint;
begin
  if auth.role() <> 'authenticated' then raise exception 'admin only'; end if;
  insert into teachers(username, name, pass_hash)
    values (lower(p_user), p_name, crypt(p_pass, gen_salt('bf')))
    returning id into v_id;
  return v_id;
end $$;

-- TEACHER: log in (returns name if ok, else nothing)
create or replace function teacher_login(p_user text, p_pass text)
returns table(name text) language plpgsql security definer set search_path=public,extensions as $$
begin
  if _teacher_ok(p_user,p_pass) is null then return; end if;
  return query select t.name from teachers t where t.username = lower(p_user);
end $$;

-- TEACHER: the name pickers they need to log (names only, nothing else)
create or replace function teacher_lists(p_user text, p_pass text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if _teacher_ok(p_user,p_pass) is null then raise exception 'bad credentials'; end if;
  return json_build_object(
    'students',   (select coalesce(json_agg(json_build_object('id',id,'name',name) order by name),'[]') from students),
    'components', (select coalesce(json_agg(json_build_object('id',id,'urn',urn,'name',name) order by urn),'[]') from components));
end $$;

-- TEACHER: log a component taking / loss
create or replace function teacher_log(p_user text, p_pass text, p_student bigint,
  p_component bigint, p_qty int, p_type text, p_class text, p_reason text)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint;
begin
  if _teacher_ok(p_user,p_pass) is null then raise exception 'bad credentials'; end if;
  if p_type not in ('replacement','loss') then raise exception 'teachers can only log replacement/loss'; end if;
  insert into movements(component_id, qty, type, student_id, staff, class_label, reason)
    values (p_component, greatest(p_qty,1), p_type::move_type, p_student, lower(p_user), p_class, p_reason)
    returning id into v_id;
  return v_id;
end $$;

-- TEACHER: their own recent log (own entries only)
create or replace function teacher_recent(p_user text, p_pass text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if _teacher_ok(p_user,p_pass) is null then raise exception 'bad credentials'; end if;
  return (select coalesce(json_agg(row_to_json(x) order by x.occurred_at desc),'[]') from (
    select m.occurred_at, m.qty, m.type, m.class_label, m.reason,
           c.urn, c.name as component, s.name as student
    from movements m
      left join components c on c.id = m.component_id
      left join students s   on s.id = m.student_id
    where m.staff = lower(p_user)
    order by m.occurred_at desc limit 25) x);
end $$;

-- grants: teachers call these without a Supabase session (anon role)
grant execute on function teacher_login(text,text)                                   to anon, authenticated;
grant execute on function teacher_lists(text,text)                                   to anon, authenticated;
grant execute on function teacher_log(text,text,bigint,bigint,int,text,text,text)    to anon, authenticated;
grant execute on function teacher_recent(text,text)                                  to anon, authenticated;
grant execute on function create_teacher(text,text,text)                             to authenticated;
revoke execute on function _teacher_ok(text,text) from anon;
