-- ============================================================================
-- Teacher-facing functions, rewired for the v2 kit schema.
-- Run AFTER teachers.sql and schema.sql.
--
-- v1 wrote to `movements` and picked from `components`, neither of which exists
-- now. Teachers log replacement parts into `replacements` and pick from `parts`.
--
-- Teachers have no Supabase session. They authenticate by username+password
-- through these SECURITY DEFINER functions and get no other read access.
-- ============================================================================

-- pickers a teacher needs: student names and part names, nothing else
create or replace function teacher_lists(p_user text, p_pass text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if _teacher_ok(p_user,p_pass) is null then raise exception 'bad credentials'; end if;
  return json_build_object(
    'students', (select coalesce(json_agg(json_build_object('id',id,'name',name) order by name),'[]')
                   from students where active),
    'parts',    (select coalesce(json_agg(json_build_object('id',id,'urn',urn,'name',name) order by urn),'[]')
                   from parts where active));
end $$;

-- log a replacement part handed to a child
create or replace function teacher_log_part(p_user text, p_pass text, p_student bigint,
  p_part bigint, p_qty int, p_reason text)
returns bigint language plpgsql security definer set search_path=public,extensions as $$
declare v_id bigint; v_teacher bigint; v_cust bigint;
begin
  v_teacher := _teacher_ok(p_user,p_pass);
  if v_teacher is null then raise exception 'bad credentials'; end if;
  select customer_id into v_cust from students where id = p_student;
  insert into replacements(part_id, student_id, customer_id, teacher_id, qty, reason)
    values (p_part, p_student, v_cust, v_teacher, greatest(coalesce(p_qty,1),1), p_reason)
    returning id into v_id;
  return v_id;
end $$;

-- a teacher's own recent entries
create or replace function teacher_recent(p_user text, p_pass text)
returns json language plpgsql security definer set search_path=public,extensions as $$
declare v_teacher bigint;
begin
  v_teacher := _teacher_ok(p_user,p_pass);
  if v_teacher is null then raise exception 'bad credentials'; end if;
  return (select coalesce(json_agg(row_to_json(x) order by x.occurred_at desc),'[]') from (
    select r.occurred_at, r.qty, r.reason, p.urn, p.name as part, s.name as student
      from replacements r
      left join parts p    on p.id = r.part_id
      left join students s on s.id = r.student_id
     where r.teacher_id = v_teacher
     order by r.occurred_at desc limit 25) x);
end $$;

-- the v1 logger wrote to a table that no longer exists
drop function if exists teacher_log(text,text,bigint,bigint,int,text,text,text);

grant execute on function teacher_lists(text,text)                          to anon, authenticated;
grant execute on function teacher_log_part(text,text,bigint,bigint,int,text) to anon, authenticated;
grant execute on function teacher_recent(text,text)                         to anon, authenticated;
