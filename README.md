# ROBOCODE Kit Stock

Tracks **finished kits**, not components: how many we built, who they went to,
who has paid, and what is still out on loan.

v1 tracked every individual part through a movements ledger. That was more
bookkeeping than it was worth — component quantities now come from the BOM
generator in `1 Kit Data/`, and this app starts at the point a kit is built.

## Stack
- **Supabase** (Postgres + Auth + auto REST API) — system of record
- **`index.html`** — one file, plain JS, `supabase-js` from CDN, no build step

## Setup

Run in the Supabase SQL editor, in this order:

| Order | File | What it does |
|---|---|---|
| 1 | `teachers.sql` | teacher logins (skip if already run) |
| 2 | `schema.sql` | retires v1, creates the kit model, migrates franchises + students |
| 3 | `seed.sql` | the 14 kit types with real landed costs and suggested prices |
| 4 | `teachers_v2.sql` | re-points the teacher functions at the new tables |
| 5 | `teacher_admin.sql` | optional: password reset / deactivate helpers |

`teachers_v2.sql` matters: v1's `teacher_log` wrote to the `movements` table,
which no longer exists. It is replaced by `teacher_log_part`, which writes to
the replacements log.

`schema.sql` is safe to re-run. It **renames** v1's `kits`, `students` and
`franchises` to `*_v1` rather than dropping them, and copies the franchises and
students across. Drop the `_v1` tables by hand once you are happy.

Then open `index.html` and sign in with a Supabase user
(Dashboard → Authentication → Users → Add user, email confirmed).

## How it works

**Stock is derived, never typed.** Every change is a row in `kit_moves` with a
signed delta. Building 30 kits is `+30`; an order line going out is `-30`; a loan
coming back is `+1`. `v_kit_stock` adds them up. Triggers write those rows, so
stock cannot drift from the orders.

**An order** has one customer, one requesting teacher, and any number of lines.
Each line is a **sale** or a **loan**, for a quantity of one kit type, optionally
against a named student. Loans carry a due date and are chased on the *On loan* tab.

**Payment is per order** — paid or unpaid, with a reference. The order total is
the sale lines only; loans are free and do not appear in money owed.

**Spares log** records replacement parts handed to a child. It is a record only
and does not touch kit stock.

## Tabs
`Stock` build kits, see availability · `New order` · `Orders` ·
`Money owed` · `On loan` overdue in red · `Customers` · `Spares log` ·
`Admin` kit prices, teachers

## Prices
Cost per kit is generated from the real BOM and supplier quote by
`1 Kit Data/build_stock_seed.py`. Re-running `seed.sql` **updates cost but never
overwrites your prices** — set those once in Admin and they stick.

## Database migration (Supabase CLI)

This folder has **no git remote** — nothing pushes anywhere. Run the CLI here:

```
brew install supabase/tap/supabase     # once
supabase login
supabase init                          # keeps the existing supabase/functions/
supabase link --project-ref dtggdbcortsnhqepfyem
```

`supabase link` asks for the database password. Type it at the prompt — never
paste it into a file, a chat, or this repo.

To capture the current live database as a migration:

```
supabase db pull                       # existing schema -> supabase/migrations/
supabase db push                       # apply local migrations to the project
```

If you would rather start clean, put `schema.sql`, `kiosk.sql` and `seed.sql`
into `supabase/migrations/` with timestamp prefixes and `db push` them.

## Security
Only the **anon public key** is in this repo; row-level security protects the
data and every table requires a signed-in staff user. Never commit the
service-role key or the database password.
