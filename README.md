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
| 1 | `schema.sql` | retires v1, creates the kit model, migrates franchises + students |
| 2 | `seed.sql` | the 14 kit types, their costs and the flat £30 / £40 prices |
| 3 | `kiosk.sql` | teacher kiosk functions and teacher admin |

All three are safe to re-run.

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

## Two pages, two kinds of user

**`index.html` — the superadmin.** One Supabase Auth login, full access.
Tabs: `Stock` · `New order` · `Orders` · `Money owed` · `On loan` ·
`Customers` · `Requests` · `Admin`.

**`kiosk.html` — teachers.** No account, no session, no password. A teacher
types their code and can do exactly two things: request a kit for a named child,
or ask for a part with a reason. That is the whole surface.

### How teacher codes work
Admin → Teachers → type a name, press **Generate**, then **Add teacher**. The
code is shown **once**. It is stored as a salted hash, so nobody — including
you — can look it up later. If a teacher forgets it, press **New code**; the old
one dies immediately.

Codes are six characters from an alphabet with no 0/O/1/I, so they survive being
written on a card. Everything the kiosk does goes through SECURITY DEFINER
functions, so the kiosk needs no table access at all and can only ever see
student, kit and part *names*. Failed attempts are recorded in `kiosk_attempts`
and 25 failures in ten minutes locks the door for a while.

### Requests
Teacher requests land on the admin **Requests** tab with a count badge.
A kit request shows current stock and warns if there is not enough. **Make
order** turns it into a real order in one step — right customer, right price,
right due date — and links the two. Part requests are marked *given* or
*rejected* with a note.

## Prices
**Flat: every younger kit £30, every older kit £40** — same to a franchise or an
individual. Set in `PRICE` at the top of `1 Kit Data/build_stock_seed.py`.

Cost per kit is generated from the real BOM and supplier quote by the same
script. Note that `seed.sql` now **overwrites prices** on every run, so if you
edit a price in Admin and later re-seed, your edit is replaced. Change `PRICE`
and regenerate instead.

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

## Bulk-adding customers

Customers tab → **Download Excel template** → fill it in → upload it back.

`templates/customers.xlsx` has the headers, a dropdown on `type`, and a second
sheet of worked examples that is never imported. Only **name** and **type** are
required; type must be franchise, centre, school or individual.

The app previews every row before anything is written, flagging bad types,
names already on the list, and duplicates inside the file itself. Because
`customers` is unique on (name, type) and the import upserts with
`ignoreDuplicates`, re-uploading a corrected file cannot create doubles.

`.csv` works too, if you would rather save it out of Excel.

The template is generated by `1 Kit Data/build_import_template.py` so its
headers cannot drift from the importer. Re-run that if you change the columns.

## Hosting and password recovery

The app is served by GitHub Pages at **https://bh1ff.github.io/robocode-stock/**
(branch `main`, root). Pushing to `main` republishes it.

Password reset emails must come back to that address, not localhost. Set it in
**Supabase → Authentication → URL Configuration**:

| Field | Value |
|---|---|
| Site URL | `https://bh1ff.github.io/robocode-stock/` |
| Redirect URLs | `https://bh1ff.github.io/robocode-stock/**` |

The same address is `SITE_URL` at the top of `index.html`. Change both together
if the app ever moves.

## Security
Only the **anon public key** is in this repo; row-level security protects the
data and every table requires a signed-in staff user. Never commit the
service-role key or the database password.
