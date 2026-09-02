-- ============================================================================
-- Re-apply Row Level Security after a database migration.
--
-- Moving a Supabase project carries the tables and the data, but the RLS
-- ENABLED flags and the policies are easy to lose. Without them every table is
-- readable, editable and deletable by anyone holding the publishable key — and
-- that key is in a public repo, by design.
--
-- Run this on the NEW project. Safe to re-run. It works on whatever tables are
-- actually there, so it does not matter if the migration was partial.
-- ============================================================================

-- ---------- 1. every table in public: RLS on, staff-only policy ----------
do $$
declare t record; n int := 0;
begin
  for t in
    select tablename from pg_tables
     where schemaname = 'public'
     order by tablename
  loop
    execute format('alter table public.%I enable row level security', t.tablename);
    execute format('drop policy if exists staff_all on public.%I', t.tablename);
    execute format($f$create policy staff_all on public.%I
                      for all to authenticated using (true) with check (true)$f$, t.tablename);
    n := n + 1;
  end loop;
  raise notice 'RLS enabled with a staff-only policy on % tables', n;
end $$;

-- ---------- 2. views must not leak round the side ----------
-- A view runs as its owner unless told otherwise, so a view over a protected
-- table hands the data straight back out. security_invoker makes the view obey
-- the caller's RLS instead.
do $$
declare v record; n int := 0;
begin
  for v in
    select table_name from information_schema.views where table_schema = 'public'
  loop
    execute format('alter view public.%I set (security_invoker = true)', v.table_name);
    n := n + 1;
  end loop;
  raise notice 'security_invoker set on % views', n;
end $$;

-- ---------- 3. anon gets nothing directly ----------
-- The kiosk does not need table access: every kiosk function is SECURITY
-- DEFINER, so it keeps working with no grants at all.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

-- put back only the kiosk entry points, if they exist on this project
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'kiosk\_%'
  loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

-- ---------- 4. show the result ----------
select c.relname                                as table_name,
       c.relrowsecurity                         as rls_enabled,
       count(p.polname)                         as policies
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_policy p on p.polrelid = c.oid
 where n.nspname = 'public' and c.relkind = 'r'
 group by c.relname, c.relrowsecurity
 order by c.relrowsecurity, c.relname;
-- Every row should read rls_enabled = true with at least one policy.
