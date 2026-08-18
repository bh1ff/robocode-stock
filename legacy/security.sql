-- Run this in the Supabase SQL editor after schema.sql.
-- Makes the views respect row-level security (so the public anon key
-- cannot read data unless a staff user is signed in).
alter view v_stock      set (security_invoker = on);
alter view v_open_loans set (security_invoker = on);
alter view v_kit_cost   set (security_invoker = on);
