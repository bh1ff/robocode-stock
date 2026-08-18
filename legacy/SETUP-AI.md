# Invoice → stock (AI) setup

The "Invoice → stock" tab uploads a PDF/photo, Claude extracts the line items and
matches them to your components, you edit, then confirm to add `purchase_in` stock.
The Anthropic API key lives only in the Edge Function (server-side), never in the app.

## 1. Rotate your key
Your previous key was shared in chat. At console.anthropic.com → API keys, delete it
and create a new one. Use the new key below.

## 2. Set the secrets (Supabase)
Dashboard → Project Settings → Edge Functions → Secrets (or CLI):

```
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... --project-ref dtggdbcortsnhqepfyem
supabase secrets set INVOICE_PIN=244331 --project-ref dtggdbcortsnhqepfyem
# optional, defaults to claude-sonnet-4-6:
supabase secrets set ANTHROPIC_MODEL=claude-sonnet-4-6 --project-ref dtggdbcortsnhqepfyem
```

## 3. Deploy the function
Install the CLI once (`brew install supabase/tap/supabase`), then:

```
supabase login                 # opens browser for an access token
supabase functions deploy invoice --project-ref dtggdbcortsnhqepfyem
```

(Or in the dashboard: Edge Functions → Create function → name it `invoice` → paste
`supabase/functions/invoice/index.ts`.)

## 4. Use it
Open the app → Invoice → stock → choose a file → enter PIN 244331 → Analyse →
edit the suggested rows → Confirm. Confirmed rows become received stock and update
unit cost.

## Cost
Each analysis is one Claude call (sonnet) on the invoice image/PDF — pennies per invoice.
The PIN gates the function so only people who know it can spend on the key.
