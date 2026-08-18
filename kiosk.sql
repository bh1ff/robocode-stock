-- ============================================================================
-- ROBOCODE Kit Stock — teacher kiosk
-- Run AFTER schema.sql. Safe to re-run.
--
-- There is exactly ONE real login: the Supabase Auth user (the superadmin).
-- Teachers have no account and no session. They type a code into kiosk.html and
-- can only do two things: ask for a kit for a child, or ask for a part.
--
-- Everything below is SECURITY DEFINER, so the kiosk needs no table access at
-- all. RLS keeps the anon key locked out of every table; these functions are
-- the only way in, and they return the bare minimum.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- Codes are never stored. We keep sha256(code + pepper).
-- Change the pepper and every existing code stops working.
create or replace function _kiosk_hash(p_code text)
returns text language sql immutable security definer set search_path=public,extensions as $$
  select encode(digest(upper(trim(p_code)) || '::robocode-kiosk-v3', 'sha256'), 'hex');
$$;
revoke execute on function _kiosk_hash(text) from anon, authenticated;

-- Resolve a code to a teacher, with a crude brake on scripted guessing.
-- A teacher fat-fingering their code a few times is unaffected.
create or replace function _kiosk_who(p_code text)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint; v_recent int;
begin
  select count(*) into v_recent from kiosk_attempts where at > now() - interval '10 minutes';
  if v_recent >= 25 then
    raise exception 'Too many failed attempts. Try again in a few minutes.';
  end if;

  select id into v_id from teachers where active and code_hash = _kiosk_hash(p_code);

  if v_id is null then
    insert into kiosk_attempts(note) values ('bad code, length ' || length(coalesce(p_code,'')));
    return null;
  end if;
  return v_id;
end $$;
revoke execute on function _kiosk_who(text) from anon, authenticated;

-- ---------------------------------------------------------------- kiosk
-- sign in: returns the teacher's name, nothing else
create or replace function kiosk_login(p_code text)
returns table(id bigint, name text)
language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint;
begin
  v_id := _kiosk_who(p_code);
  if v_id is null then return; end if;
  return query select t.id, t.name from teachers t where t.id = v_id;
end $$;

-- the pickers a teacher needs. Names only - no contact details, no prices.
create or replace function kiosk_lists(p_code text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if _kiosk_who(p_code) is null then raise exception 'Not a valid code'; end if;
  return json_build_object(
    'students', (select coalesce(json_agg(json_build_object('id',id,'name',name) order by name),'[]')
                   from students where active),
    'kits',     (select coalesce(json_agg(json_build_object('id',id,'code',code,'name',name)
                                          order by sort_order),'[]')
                   from kits where active),
    'parts',    (select coalesce(json_agg(json_build_object('id',id,'urn',urn,'name',name) order by urn),'[]')
                   from parts where active));
end $$;

-- ask for a kit for a named child
create or replace function kiosk_request_kit(p_code text, p_kit bigint, p_student bigint,
  p_qty int default 1, p_kind text default 'loan', p_needed_by date default null,
  p_reason text default null)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_t bigint; v_id bigint; v_cust bigint;
begin
  v_t := _kiosk_who(p_code);
  if v_t is null then raise exception 'Not a valid code'; end if;
  if p_kit is null then raise exception 'Choose a kit'; end if;
  if p_kind not in ('sale','loan') then raise exception 'kind must be sale or loan'; end if;
  select customer_id into v_cust from students where id = p_student;
  insert into kit_requests(kit_id, student_id, customer_id, teacher_id, qty, kind, needed_by, reason)
    values (p_kit, p_student, v_cust, v_t, greatest(coalesce(p_qty,1),1),
            p_kind::line_kind, p_needed_by, p_reason)
    returning id into v_id;
  return v_id;
end $$;

-- ask for a part, with a reason
create or replace function kiosk_request_item(p_code text, p_part bigint, p_student bigint default null,
  p_qty int default 1, p_reason text default null)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_t bigint; v_id bigint; v_cust bigint;
begin
  v_t := _kiosk_who(p_code);
  if v_t is null then raise exception 'Not a valid code'; end if;
  if p_part is null then raise exception 'Choose a part'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Please give a reason'; end if;
  select customer_id into v_cust from students where id = p_student;
  insert into item_requests(part_id, student_id, customer_id, teacher_id, qty, reason)
    values (p_part, p_student, v_cust, v_t, greatest(coalesce(p_qty,1),1), p_reason)
    returning id into v_id;
  return v_id;
end $$;

-- a teacher's own recent requests, so they can see what happened to them
create or replace function kiosk_my_requests(p_code text)
returns json language plpgsql security definer set search_path=public,extensions as $$
declare v_t bigint;
begin
  v_t := _kiosk_who(p_code);
  if v_t is null then raise exception 'Not a valid code'; end if;
  return json_build_object(
    'kits', (select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]') from (
       select r.created_at, r.qty, r.kind, r.status, r.needed_by, r.reason,
              k.code as kit_code, k.name as kit_name, s.name as student
         from kit_requests r join kits k on k.id = r.kit_id
         left join students s on s.id = r.student_id
        where r.teacher_id = v_t order by r.created_at desc limit 20) x),
    'items', (select coalesce(json_agg(row_to_json(y) order by y.created_at desc),'[]') from (
       select r.created_at, r.qty, r.status, r.reason, p.urn, p.name as part, s.name as student
         from item_requests r left join parts p on p.id = r.part_id
         left join students s on s.id = r.student_id
        where r.teacher_id = v_t order by r.created_at desc limit 20) y));
end $$;

-- ---------------------------------------------------------------- admin
-- superadmin creates a teacher and is shown the code once
create or replace function create_teacher(p_name text, p_code text)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint;
begin
  if auth.role() <> 'authenticated' then raise exception 'admin only'; end if;
  if coalesce(btrim(p_name),'') = '' then raise exception 'Name required'; end if;
  if length(btrim(p_code)) < 5 then raise exception 'Code must be at least 5 characters'; end if;
  insert into teachers(name, code_hash) values (btrim(p_name), _kiosk_hash(p_code))
    returning id into v_id;
  return v_id;
end $$;

create or replace function set_teacher_code(p_id bigint, p_code text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'admin only'; end if;
  if length(btrim(p_code)) < 5 then raise exception 'Code must be at least 5 characters'; end if;
  update teachers set code_hash = _kiosk_hash(p_code) where id = p_id;
end $$;

-- v1/v2 signatures are gone
drop function if exists create_teacher(text,text,text);
drop function if exists teacher_login(text,text);
drop function if exists teacher_lists(text,text);
drop function if exists teacher_recent(text,text);
drop function if exists teacher_log(text,text,bigint,bigint,int,text,text,text);
drop function if exists teacher_log_part(text,text,bigint,bigint,int,text);
drop function if exists _teacher_ok(text,text);

-- ---------------------------------------------------------------- grants
-- the kiosk calls these with the publishable key and no session
grant execute on function kiosk_login(text)                                              to anon, authenticated;
grant execute on function kiosk_lists(text)                                              to anon, authenticated;
grant execute on function kiosk_request_kit(text,bigint,bigint,int,text,date,text)        to anon, authenticated;
grant execute on function kiosk_request_item(text,bigint,bigint,int,text)                 to anon, authenticated;
grant execute on function kiosk_my_requests(text)                                        to anon, authenticated;
grant execute on function create_teacher(text,text)                                      to authenticated;
grant execute on function set_teacher_code(bigint,text)                                  to authenticated;
