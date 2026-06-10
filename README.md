# ROBOCODE Stock

Kit and component stock management for ROBOCODE robotics courses. Tracks every part across three states (in storage, on loan, sold/lost), kit issue/return (rent = free loan, buy = paid), a lost/extra-parts log, low-stock alerts, and per-course kit cost and margin.

## Stack
- **Supabase** (Postgres + Auth + auto REST API, free tier) — system of record
- **Static web app** (`index.html`, plain JS + `supabase-js` from CDN) — no build step. Open the file locally or host on GitHub Pages / Vercel / Netlify.

## Setup
1. In the Supabase SQL editor, run `schema.sql` then `security.sql`.
2. In `index.html`, confirm `SUPABASE_URL` and `SUPABASE_ANON` point at your project (the anon key is public by design; row-level security protects the data).
3. Create a staff login: Supabase dashboard → Authentication → Users → Add user (set a password, mark email confirmed). Or use "Create account" in the app if email confirmation is off.
4. Open `index.html` (or deploy it) and sign in.

## Data model
Every event is a row in `movements`; stock levels are **derived**, never edited directly.

- `components` — parts (URN, cost, supplier links, reorder level)
- `kits` / `kit_items` — the bill of materials per course
- `students`, `issues` (one per kit handed out), `movements` (the ledger)
- Views: `v_stock`, `v_open_loans` (who holds what), `v_kit_cost`
- Functions: `issue_kit()`, `return_issue()`

## Security
- Only the **anon public key** lives in this repo (safe under RLS). Never commit the service-role key or DB password.
- Seeding was done with a service-role key; rotate it in the Supabase dashboard if it was ever shared.
