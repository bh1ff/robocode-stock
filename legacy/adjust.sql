-- Allow manual storage corrections (stocktake): adjustment movements may be
-- negative as well as positive. Run in the Supabase SQL editor. Safe to re-run.
alter table movements drop constraint if exists movements_qty_check;
alter table movements add  constraint movements_qty_check check (qty <> 0);
