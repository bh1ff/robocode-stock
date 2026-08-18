# v1 (component-level) — retired August 2026

These are the original component-tracking files. They reference `components`,
`movements`, `kit_items`, `issues` and `v_stock`, none of which exist in v2.
**Do not run them.**

Kept only so the old logic can be read if a question comes up. Component
quantities now come from the BOM generator in `1 Kit Data/`; this app starts
where a finished kit does.

`SETUP-AI.md` describes the "Invoice → stock" Edge Function, which read a supplier
invoice and topped up **component** stock. v2 has no component stock, so the feature
is not carried over. The function itself still sits in `../supabase/functions/invoice/`
if you ever want it back.

`teachers.sql`, `teachers_v2.sql` and `teacher_admin.sql` are also retired. They
build the username + password teacher model and read `components`, which v2
drops. Teachers are now kiosk users identified by a code — `schema.sql` creates
that table itself, and the kiosk functions will live in `kiosk.sql`.
