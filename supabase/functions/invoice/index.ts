// Supabase Edge Function: invoice -> stock suggestions via Claude.
// The Anthropic API key lives ONLY here, as a secret (never in the browser).
// Secrets to set:  ANTHROPIC_API_KEY, INVOICE_PIN  (optional: ANTHROPIC_MODEL)
// Deploy:  supabase functions deploy invoice --project-ref dtggdbcortsnhqepfyem

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), { status, headers: { ...cors, "content-type": "application/json" } });

  try {
    const { file_base64, media_type, catalog, pin } = await req.json();

    if (pin !== Deno.env.get("INVOICE_PIN")) return json({ error: "Wrong PIN." }, 401);
    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ error: "ANTHROPIC_API_KEY secret is not set." }, 500);
    if (!file_base64) return json({ error: "No file received." }, 400);

    const model = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-4-6";
    const isPdf = String(media_type || "").includes("pdf");
    const fileBlock = isPdf
      ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: file_base64 } }
      : { type: "image", source: { type: "base64", media_type: media_type || "image/jpeg", data: file_base64 } };

    const cat = (catalog || []).map((c: any) => `${c.urn}\t${c.name}`).join("\n");
    const prompt =
`You are reading a supplier invoice or receipt for an electronics education company.
Extract every purchased line item and match each to our component catalogue when there is a clear match.

Catalogue (URN<TAB>name):
${cat}

Return ONLY a JSON array (no prose, no markdown fences). Each element:
{"urn": "<catalogue URN, or null if no good match>", "name": "<catalogue name if matched, else the invoice description>", "qty": <integer total units received>, "unit_price": <number in GBP per unit, or null>, "raw": "<the original invoice line text>"}

Rules: quantities are UNITS (multiply out packs, e.g. "2 x pack of 10" = 20). If unsure of a match, set urn to null. Ignore shipping, tax and totals lines.`;

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model,
        max_tokens: 4000,
        messages: [{ role: "user", content: [fileBlock, { type: "text", text: prompt }] }],
      }),
    });
    const data = await r.json();
    if (!r.ok) return json({ error: data?.error?.message || "Claude API error", detail: data }, 502);

    const txt = (data.content || []).map((b: any) => b.text || "").join("\n");
    const match = txt.match(/\[[\s\S]*\]/);
    let items: unknown[] = [];
    try { items = match ? JSON.parse(match[0]) : []; } catch { return json({ error: "Could not parse AI response", txt }, 502); }
    return json({ items });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
