-- Teacher editing: admin reset/rename/disable, and teacher self-service password.
-- Run in the Supabase SQL editor after teachers.sql. Safe to re-run.

-- ADMIN: reset a teacher's password
create or replace function admin_set_teacher_password(p_user text, p_newpass text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'admin only'; end if;
  update teachers set pass_hash = crypt(p_newpass, gen_salt('bf')) where username = lower(p_user);
end $$;

-- TEACHER: change own password (must know the current one)
create or replace function teacher_change_password(p_user text, p_oldpass text, p_newpass text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if _teacher_ok(p_user, p_oldpass) is null then raise exception 'current password is wrong'; end if;
  update teachers set pass_hash = crypt(p_newpass, gen_salt('bf')) where username = lower(p_user);
end $$;

grant execute on function admin_set_teacher_password(text,text)        to authenticated;
grant execute on function teacher_change_password(text,text,text)      to anon, authenticated;
-- (renaming, enable/disable and delete are done by admins via the normal
--  table update/delete, already allowed by the admin_all RLS policy.)
