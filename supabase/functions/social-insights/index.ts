// Edge Function: social-insights
// Genera i testi del modulo Social di NCREATIVE leggendo le metriche già
// raccolte in nc_social_daily / nc_social_posts / nc_ads_daily:
//   - mode="suggestions" → una scheda al giorno per cliente (cosa ha funzionato
//     ieri, cosa provare oggi), scritta in nc_insights con kind='suggestion'
//   - mode="audit"       → report mensile per cliente, kind='audit'
// Il testo lo scrive l'API di Claude; i numeri restano quelli del database —
// il prompt vieta esplicitamente di inventarne.
//
// Chiamata (POST, service_role o cron):
//   {"mode":"suggestions"}                        → ieri, tutti i clienti attivi
//   {"mode":"suggestions","date":"2026-07-21"}    → un giorno preciso
//   {"mode":"audit","period":"2026-07"}           → audit del mese
//   {"client_id":"...", "force":true}             → un solo cliente, riscrive
//
// Serve il secret ANTHROPIC_API_KEY (Supabase → Edge Functions → Secrets).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

// Supabase inietta sia le variabili storiche (SUPABASE_SERVICE_ROLE_KEY, una
// stringa) sia quelle nuove (SUPABASE_SECRET_KEYS, un JSON per nome chiave).
// Si prende la nuova se c'è, altrimenti la vecchia: così la funzione attraversa
// la rotazione senza modifiche.
function chiaveSegreta(): string {
  const nuove = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (nuove) {
    try {
      const k = JSON.parse(nuove)["default"];
      if (k) return k;
    } catch { /* formato inatteso: si ricade sulla legacy */ }
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const SERVICE_KEY = chiaveSegreta();
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");

// Le chiavi `sb_secret_...` non sono JWT: su Authorization verrebbero rifiutate.
// Vanno sempre su `apikey`; Authorization si aggiunge solo per le legacy.
const dbHeaders: Record<string, string> = {
  apikey: SERVICE_KEY,
  "content-type": "application/json",
  ...(SERVICE_KEY.startsWith("eyJ") ? { Authorization: `Bearer ${SERVICE_KEY}` } : {}),
};

async function db<T>(path: string): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: dbHeaders });
  if (!r.ok) throw new Error(`DB ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return await r.json() as T;
}
async function dbInsert(table: string, row: unknown): Promise<void> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
    method: "POST",
    headers: { ...dbHeaders, Prefer: "return=minimal" },
    body: JSON.stringify(row),
  });
  if (!r.ok) throw new Error(`INSERT ${r.status}: ${(await r.text()).slice(0, 300)}`);
}
async function dbDelete(pathAndQuery: string): Promise<void> {
  await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method: "DELETE",
    headers: dbHeaders,
  });
}

// ── Date ───────────────────────────────────────────────────────────────────
const day = (d: Date) => d.toISOString().slice(0, 10);
function shiftDays(iso: string, n: number): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return day(d);
}
function monthBounds(period: string): { from: string; to: string } {
  const [y, m] = period.split("-").map(Number);
  const from = `${period}-01`;
  const to = day(new Date(Date.UTC(y, m, 0)));   // giorno 0 del mese dopo = ultimo del mese
  return { from, to };
}

// ── Tipi (specchio delle tabelle nc_) ──────────────────────────────────────
type Client = { id: string; name: string; status: string; services: string[]; notes: string | null };
type Account = {
  id: string; client_id: string | null; role: string; platform: string; handle: string;
};
type Daily = {
  account_id: string; date: string; followers: number | null; likes: number;
  comments: number; messages: number; reach: number | null; impressions: number | null;
};
type Post = {
  account_id: string; published_at: string | null; format: string | null; caption: string | null;
  likes: number; comments: number; saves: number; shares: number; reach: number | null; is_ad: boolean;
};
type Ads = {
  client_id: string | null; date: string; campaign: string | null; spend_cents: number;
  impressions: number; clicks: number; results: number; likes: number; comments: number; messages: number;
};

const euro = (cents: number) => `€${(cents / 100).toFixed(2)}`;

// ── Riassunto numerico dato in pasto al modello ─────────────────────────────
// Compatto ma completo: il modello deve poter citare cifre esatte senza stimare.
function buildMetricsBlock(
  client: Client,
  accounts: Account[],
  daily: Daily[],
  posts: Post[],
  ads: Ads[],
  from: string,
  to: string,
): string {
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const own = accounts.filter((a) => a.role === "own");
  const comps = accounts.filter((a) => a.role === "competitor");

  const lines: string[] = [];
  lines.push(`CLIENT: ${client.name}`);
  if (client.services?.length) lines.push(`SERVICES: ${client.services.join(", ")}`);
  if (client.notes) lines.push(`NOTES: ${client.notes}`);
  lines.push(`WINDOW: ${from} → ${to}`);

  const rowsFor = (accId: string) =>
    daily.filter((d) => d.account_id === accId).sort((a, b) => a.date.localeCompare(b.date));

  const renderAccount = (a: Account, label: string) => {
    const rows = rowsFor(a.id);
    if (!rows.length) {
      lines.push(`\n${label} @${a.handle} (${a.platform}): no data logged in this window`);
      return;
    }
    const sum = rows.reduce(
      (s, r) => ({
        likes: s.likes + r.likes,
        comments: s.comments + r.comments,
        messages: s.messages + r.messages,
      }),
      { likes: 0, comments: 0, messages: 0 },
    );
    const first = rows[0], last = rows[rows.length - 1];
    const growth = last.followers != null && first.followers != null
      ? last.followers - first.followers
      : null;
    lines.push(`\n${label} @${a.handle} (${a.platform})`);
    lines.push(
      `  totals: likes ${sum.likes} · comments ${sum.comments} · messages ${sum.messages}` +
        (last.followers != null ? ` · followers ${last.followers}` : "") +
        (growth != null ? ` (${growth >= 0 ? "+" : ""}${growth} in window)` : ""),
    );
    lines.push(`  daily rows (date | followers | likes | comments | messages | reach):`);
    for (const r of rows) {
      lines.push(
        `    ${r.date} | ${r.followers ?? "-"} | ${r.likes} | ${r.comments} | ${r.messages} | ${r.reach ?? "-"}`,
      );
    }
  };

  own.forEach((a) => renderAccount(a, "OWN ACCOUNT"));
  comps.forEach((a) => renderAccount(a, "COMPETITOR"));

  const ownPosts = posts
    .filter((p) => byId.get(p.account_id)?.role === "own")
    .sort((a, b) => (b.likes + b.comments) - (a.likes + a.comments))
    .slice(0, 12);
  if (ownPosts.length) {
    lines.push(`\nTOP POSTS (own accounts, by likes+comments):`);
    for (const p of ownPosts) {
      const cap = (p.caption ?? "").replace(/\s+/g, " ").slice(0, 120);
      lines.push(
        `  ${p.published_at?.slice(0, 10) ?? "-"} | ${p.format ?? "-"}${p.is_ad ? " (ad)" : ""} | ` +
          `likes ${p.likes} · comments ${p.comments} · saves ${p.saves} · shares ${p.shares}` +
          (p.reach != null ? ` · reach ${p.reach}` : "") + (cap ? ` | "${cap}"` : ""),
      );
    }
  }

  if (ads.length) {
    const spend = ads.reduce((s, a) => s + a.spend_cents, 0);
    const results = ads.reduce((s, a) => s + a.results, 0);
    const clicks = ads.reduce((s, a) => s + a.clicks, 0);
    lines.push(`\nPAID CAMPAIGNS: spend ${euro(spend)} · clicks ${clicks} · results ${results}`);
    for (const a of ads.slice(0, 30)) {
      lines.push(
        `  ${a.date} | ${a.campaign ?? "-"} | spend ${euro(a.spend_cents)} · impressions ${a.impressions} · ` +
          `clicks ${a.clicks} · results ${a.results} · likes ${a.likes} · comments ${a.comments} · messages ${a.messages}`,
      );
    }
  } else {
    lines.push(`\nPAID CAMPAIGNS: none logged in this window`);
  }

  return lines.join("\n");
}

// ── Claude ─────────────────────────────────────────────────────────────────
const INSIGHT_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string", description: "Headline of max 60 characters." },
    body: { type: "string", description: "The analysis itself, in markdown." },
  },
  required: ["title", "body"],
  additionalProperties: false,
};

const SYSTEM = `You are the senior social media strategist at NCREATIVE, a social media marketing agency.
You write for the person who manages these accounts every day, so be concrete and skip the filler.

Hard rules:
- Use ONLY the numbers given to you. Never invent, estimate, or extrapolate a metric.
- If the data is too thin to support a claim, say so plainly instead of guessing.
- Quote the figure whenever you make a point about performance.
- Compare against the client's own recent days and against the competitors listed, nothing else.
- Write in English. No emoji. No preamble like "Here is your report".`;

async function generate(anthropic: Anthropic, prompt: string): Promise<{ title: string; body: string }> {
  const res = await anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 8000,
    thinking: { type: "adaptive" },
    output_config: {
      effort: "medium",
      format: { type: "json_schema", schema: INSIGHT_SCHEMA },
    },
    system: SYSTEM,
    messages: [{ role: "user", content: prompt }],
  });

  if (res.stop_reason === "refusal") throw new Error("model refused the request");
  if (res.stop_reason === "max_tokens") throw new Error("output truncated — raise max_tokens");

  const text = res.content.find((b) => b.type === "text");
  if (!text || text.type !== "text") throw new Error("no text block in response");
  return JSON.parse(text.text) as { title: string; body: string };
}

// ── Prompt per modalità ─────────────────────────────────────────────────────
function suggestionPrompt(metrics: string, target: string): string {
  return `Below are the logged social metrics for one client. Today's briefing covers ${target}.

${metrics}

Write the daily briefing, in markdown, with exactly these three short sections:

**How it went** — two or three sentences on ${target} versus the client's own recent days. Cite the actual numbers.
**Versus competitors** — one or two sentences. If no competitor data is logged, say that in one line and move on.
**Do today** — two or three bullets, each a concrete action (a format, a topic, a posting time, a reply to chase). Tie each bullet to something visible in the data.

Keep the whole thing under 200 words. The title should name the single most useful takeaway.`;
}

function auditPrompt(metrics: string, period: string): string {
  return `Below are the logged social metrics for one client for the month ${period}.

${metrics}

Write the monthly audit a senior social media manager would hand to this client, in markdown:

## Headline — what the month amounted to, in two or three sentences with the key figures.
## What worked — the formats, topics, or campaigns that actually performed, each backed by its numbers.
## What did not — be direct about what underperformed and what it cost.
## Competitive position — where the client stands against the competitors logged. If none are logged, say so and skip the rest of this section.
## Paid performance — spend against results. Skip this section entirely if no spend is logged.
## Next month — three or four prioritised recommendations, most valuable first, each justified by something in this month's data.

Aim for 400-600 words. The title should read like a report heading, e.g. "July 2026 — reach up, engagement flat".`;
}

// ── Handler ─────────────────────────────────────────────────────────────────
// Finché la funzione gira con verify_jwt=true è la piattaforma a filtrare le
// chiamate. Ma quel controllo capisce solo le chiavi legacy (JWT): quando si
// passa a una chiave `sb_secret_...` va spento, e allora l'autorizzazione deve
// stare qui. Questo controllo vale in entrambi i mondi, quindi si può
// aggiungere prima della rotazione senza rompere niente.
function autorizzata(req: Request): boolean {
  const presentata = req.headers.get("apikey") ??
    req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!presentata || !SERVICE_KEY) return false;
  // confronto a lunghezza costante: non deve far trapelare quanti caratteri tornano
  if (presentata.length !== SERVICE_KEY.length) return false;
  let diff = 0;
  for (let i = 0; i < presentata.length; i++) {
    diff |= presentata.charCodeAt(i) ^ SERVICE_KEY.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!autorizzata(req)) return new Response("non autorizzata", { status: 401 });
  if (!ANTHROPIC_API_KEY) {
    return Response.json({ error: "ANTHROPIC_API_KEY secret is not set" }, { status: 500 });
  }

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corpo vuoto = default */ }

  const mode = (body.mode as string) ?? "suggestions";
  const force = body.force === true;
  const onlyClient = (body.client_id as string) ?? null;

  // finestra: i suggerimenti guardano 14 giorni per avere un termine di paragone,
  // l'audit esattamente il mese richiesto
  const target = (body.date as string) ?? shiftDays(day(new Date()), -1);
  const period = (body.period as string) ?? target.slice(0, 7);
  const { from, to } = mode === "audit"
    ? monthBounds(period)
    : { from: shiftDays(target, -13), to: target };

  const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

  try {
    let clients = await db<Client[]>(
      "nc_clients?select=id,name,status,services,notes&status=eq.active&order=name.asc",
    );
    if (onlyClient) clients = clients.filter((c) => c.id === onlyClient);
    if (!clients.length) return Response.json({ ok: true, generated: 0, note: "no active clients" });

    const accounts = await db<Account[]>(
      "nc_social_accounts?select=id,client_id,role,platform,handle&active=eq.true",
    );
    const daily = await db<Daily[]>(
      `nc_social_daily?select=account_id,date,followers,likes,comments,messages,reach,impressions&date=gte.${from}&date=lte.${to}`,
    );
    const posts = await db<Post[]>(
      `nc_social_posts?select=account_id,published_at,format,caption,likes,comments,saves,shares,reach,is_ad&published_at=gte.${from}&limit=500`,
    );
    const ads = await db<Ads[]>(
      `nc_ads_daily?select=client_id,date,campaign,spend_cents,impressions,clicks,results,likes,comments,messages&date=gte.${from}&date=lte.${to}`,
    );

    const done: string[] = [];
    const skipped: string[] = [];
    const failed: { client: string; error: string }[] = [];

    for (const c of clients) {
      const accs = accounts.filter((a) => a.client_id === c.id);
      const ids = new Set(accs.map((a) => a.id));
      const cDaily = daily.filter((d) => ids.has(d.account_id));
      const cAds = ads.filter((a) => a.client_id === c.id);

      // niente dati = niente scheda: meglio il vuoto di un testo inventato
      if (!cDaily.length && !cAds.length) { skipped.push(`${c.name} (no data)`); continue; }

      const match = mode === "audit"
        ? `kind=eq.audit&period=eq.${period}`
        : `kind=eq.suggestion&date=eq.${target}`;
      const existing = await db<{ id: string }[]>(
        `nc_insights?select=id&client_id=eq.${c.id}&${match}&limit=1`,
      );
      if (existing.length && !force) { skipped.push(`${c.name} (already generated)`); continue; }

      const metrics = buildMetricsBlock(
        c, accs, cDaily,
        posts.filter((p) => ids.has(p.account_id)),
        cAds, from, to,
      );

      try {
        const out = await generate(
          anthropic,
          mode === "audit" ? auditPrompt(metrics, period) : suggestionPrompt(metrics, target),
        );
        if (existing.length) await dbDelete(`nc_insights?client_id=eq.${c.id}&${match}`);
        await dbInsert("nc_insights", {
          client_id: c.id,
          kind: mode === "audit" ? "audit" : "suggestion",
          period: mode === "audit" ? period : null,
          date: mode === "audit" ? null : target,
          title: out.title,
          body: out.body,
        });
        done.push(c.name);
      } catch (e) {
        // un cliente che fallisce non deve fermare gli altri
        failed.push({ client: c.name, error: String(e) });
      }
    }

    return Response.json({ ok: true, mode, window: { from, to }, generated: done, skipped, failed });
  } catch (e) {
    return Response.json({ ok: false, error: String(e) }, { status: 500 });
  }
});
