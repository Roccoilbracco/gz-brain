// Edge Function: bank-sync
// Collega i conti dell'agenzia via GoCardless Bank Account Data (ex Nordigen,
// PSD2) e scarica i movimenti in public.nc_bank_tx.
//
// Perché un aggregatore: le credenziali bancarie non passano mai da qui né
// dall'app — la banca autentica l'utente sul proprio sito e noi leggiamo solo
// le transazioni tramite l'API dell'aggregatore.
//
// Azioni (POST):
//   {"action":"institutions","country":"es"}        → elenco banche disponibili
//   {"action":"link","institution_id":"...",
//    "redirect":"https://..."}                      → restituisce il link da aprire
//                                                     in browser per autorizzare
//   {"action":"accounts","requisition_id":"..."}    → registra i conti autorizzati
//                                                     in nc_bank_accounts
//   {"action":"sync","days":90}                     → scarica i movimenti (default 90 gg)
//
// Secrets: GOCARDLESS_SECRET_ID, GOCARDLESS_SECRET_KEY.
// Nota PSD2: il consenso scade ogni 90 giorni — quando "sync" risponde 401/403
// per un conto, va rifatto il giro "link" per quella banca.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GC_SECRET_ID = Deno.env.get("GOCARDLESS_SECRET_ID");
const GC_SECRET_KEY = Deno.env.get("GOCARDLESS_SECRET_KEY");
const GC = "https://bankaccountdata.gocardless.com/api/v2";

const dbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "content-type": "application/json",
};

async function db<T>(path: string): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: dbHeaders });
  if (!r.ok) throw new Error(`DB ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return await r.json() as T;
}
async function dbWrite(pathAndQuery: string, method: string, body?: unknown, prefer = "return=minimal") {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers: { ...dbHeaders, Prefer: prefer },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`DB ${method} ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r;
}

// ── Token GoCardless ────────────────────────────────────────────────────────
// L'access token dura 24h: lo teniamo in nc_integrations invece di rifarlo a
// ogni chiamata (l'endpoint /token/new/ è rate-limited).
async function accessToken(): Promise<string> {
  const rows = await db<{ id: string; access_token: string | null; expires_at: string | null }[]>(
    "nc_integrations?select=id,access_token,expires_at&provider=eq.gocardless&limit=1",
  );
  const cached = rows[0];
  if (cached?.access_token && cached.expires_at && new Date(cached.expires_at) > new Date(Date.now() + 60_000)) {
    return cached.access_token;
  }

  const r = await fetch(`${GC}/token/new/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ secret_id: GC_SECRET_ID, secret_key: GC_SECRET_KEY }),
  });
  if (!r.ok) throw new Error(`GoCardless token ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const t = await r.json() as { access: string; access_expires: number };
  const expires = new Date(Date.now() + t.access_expires * 1000).toISOString();

  if (cached) {
    await dbWrite(`nc_integrations?id=eq.${cached.id}`, "PATCH", {
      access_token: t.access, expires_at: expires, updated_at: new Date().toISOString(),
    });
  } else {
    await dbWrite("nc_integrations", "POST", {
      provider: "gocardless", label: "default", access_token: t.access, expires_at: expires,
    });
  }
  return t.access;
}

async function gc<T>(path: string, token: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${GC}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "content-type": "application/json", ...(init?.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`GoCardless ${path} ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return await r.json() as T;
}

// ── Tipi GoCardless (solo i campi usati) ────────────────────────────────────
type Institution = { id: string; name: string; bic?: string; transaction_total_days?: string };
type Requisition = { id: string; link: string; accounts: string[] };
type AccountDetail = { iban?: string; institution_id?: string; owner_name?: string; currency?: string };
type Balance = { balanceAmount: { amount: string; currency: string }; balanceType: string };
type Tx = {
  transactionId?: string;
  internalTransactionId?: string;
  bookingDate?: string;
  valueDate?: string;
  transactionAmount: { amount: string; currency: string };
  creditorName?: string;
  debtorName?: string;
  remittanceInformationUnstructured?: string;
  remittanceInformationUnstructuredArray?: string[];
};

const cents = (amount: string) => Math.round(parseFloat(amount) * 100);

function describe(t: Tx): string | null {
  const parts = [
    t.remittanceInformationUnstructured,
    ...(t.remittanceInformationUnstructuredArray ?? []),
  ].filter(Boolean);
  const s = parts.join(" ").replace(/\s+/g, " ").trim();
  return s || null;
}
function counterparty(t: Tx): string | null {
  // l'uscita ha un creditore, l'entrata un debitore: prendiamo quello che c'è
  return t.creditorName ?? t.debtorName ?? null;
}

// Categoria di primo taglio: risparmia lavoro manuale, resta correggibile in app.
function guessCategory(text: string): string | null {
  const s = text.toLowerCase();
  if (/\b(meta|facebook|instagram|google ads|tiktok ads|linkedin ads)\b/.test(s)) return "ads";
  if (/\b(canva|adobe|figma|notion|slack|openai|anthropic|hosting|domain|aws|vercel)\b/.test(s)) return "tools";
  if (/\b(freelance|autonomo|invoice|factura)\b/.test(s)) return "freelance";
  if (/\b(nomina|payroll|salary|sueldo)\b/.test(s)) return "salary";
  if (/\b(alquiler|rent|office|coworking)\b/.test(s)) return "office";
  return null;
}

// ── Handler ─────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!GC_SECRET_ID || !GC_SECRET_KEY) {
    return Response.json(
      { error: "GOCARDLESS_SECRET_ID / GOCARDLESS_SECRET_KEY secrets are not set" },
      { status: 500 },
    );
  }

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corpo vuoto = sync */ }
  const action = (body.action as string) ?? "sync";

  try {
    const token = await accessToken();

    // 1. elenco banche del paese
    if (action === "institutions") {
      const country = ((body.country as string) ?? "es").toLowerCase();
      const list = await gc<Institution[]>(`/institutions/?country=${country}`, token);
      return Response.json({
        ok: true,
        institutions: list.map((i) => ({ id: i.id, name: i.name, history_days: i.transaction_total_days })),
      });
    }

    // 2. crea la richiesta di consenso e restituisce il link da aprire in banca
    if (action === "link") {
      const institution_id = body.institution_id as string;
      if (!institution_id) return Response.json({ error: "institution_id required" }, { status: 400 });
      const requisition = await gc<Requisition>("/requisitions/", token, {
        method: "POST",
        body: JSON.stringify({
          institution_id,
          redirect: (body.redirect as string) ?? "https://ncreative.local/bank-linked",
          reference: `ncreative-${Date.now()}`,
          user_language: (body.language as string) ?? "ES",
        }),
      });
      return Response.json({
        ok: true,
        requisition_id: requisition.id,
        link: requisition.link,
        next: "Apri il link, autorizza in banca, poi richiama con action=accounts e questo requisition_id.",
      });
    }

    // 3. registra i conti autorizzati
    if (action === "accounts") {
      const requisition_id = body.requisition_id as string;
      if (!requisition_id) return Response.json({ error: "requisition_id required" }, { status: 400 });
      const requisition = await gc<Requisition>(`/requisitions/${requisition_id}/`, token);
      if (!requisition.accounts?.length) {
        return Response.json({ ok: false, error: "nessun conto autorizzato: il consenso non è completo" });
      }

      const registered: string[] = [];
      for (const accId of requisition.accounts) {
        const detail = await gc<{ account: AccountDetail }>(`/accounts/${accId}/details/`, token);
        const a = detail.account ?? {};
        const existing = await db<{ id: string }[]>(
          `nc_bank_accounts?select=id&external_id=eq.${accId}&limit=1`,
        );
        const row = {
          name: a.owner_name ?? a.iban ?? accId,
          bank: a.institution_id ?? null,
          iban_last4: a.iban ? a.iban.slice(-4) : null,
          provider: "gocardless",
          external_id: accId,
          currency: a.currency ?? "EUR",
        };
        if (existing.length) await dbWrite(`nc_bank_accounts?id=eq.${existing[0].id}`, "PATCH", row);
        else await dbWrite("nc_bank_accounts", "POST", row);
        registered.push(row.name);
      }
      return Response.json({ ok: true, registered });
    }

    // 4. scarica i movimenti di tutti i conti attivi
    if (action === "sync") {
      const days = (body.days as number) ?? 90;
      const from = new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10);
      const accounts = await db<{ id: string; name: string; external_id: string | null }[]>(
        "nc_bank_accounts?select=id,name,external_id&active=eq.true&provider=eq.gocardless",
      );
      if (!accounts.length) return Response.json({ ok: true, note: "nessun conto collegato" });

      const summary: { account: string; imported: number; error?: string }[] = [];
      for (const acc of accounts) {
        if (!acc.external_id) continue;
        try {
          const res = await gc<{ transactions: { booked: Tx[] } }>(
            `/accounts/${acc.external_id}/transactions/?date_from=${from}`, token,
          );
          const booked = res.transactions?.booked ?? [];

          // upsert su external_id: risincronizzare lo stesso periodo non duplica
          const rows = booked.map((t) => {
            const desc = describe(t);
            const who = counterparty(t);
            return {
              account_id: acc.id,
              date: t.bookingDate ?? t.valueDate ?? from,
              description: desc,
              counterparty: who,
              amount_cents: cents(t.transactionAmount.amount),
              category: guessCategory([desc, who].filter(Boolean).join(" ")),
              external_id: `gc:${t.transactionId ?? t.internalTransactionId ?? `${acc.external_id}:${t.bookingDate}:${t.transactionAmount.amount}`}`,
              source: "gocardless",
            };
          });
          if (rows.length) {
            await dbWrite(
              "nc_bank_tx?on_conflict=external_id", "POST", rows,
              "resolution=merge-duplicates,return=minimal",
            );
          }

          // saldo corrente, se la banca lo espone
          try {
            const bal = await gc<{ balances: Balance[] }>(`/accounts/${acc.external_id}/balances/`, token);
            const b = bal.balances?.find((x) => /closingBooked|interimAvailable/i.test(x.balanceType))
              ?? bal.balances?.[0];
            if (b) {
              await dbWrite(`nc_bank_accounts?id=eq.${acc.id}`, "PATCH", {
                balance_cents: cents(b.balanceAmount.amount),
                synced_at: new Date().toISOString(),
              });
            }
          } catch { /* il saldo è un extra: se manca, i movimenti restano validi */ }

          summary.push({ account: acc.name, imported: rows.length });
        } catch (e) {
          // 401/403 qui = consenso PSD2 scaduto per quella banca
          summary.push({ account: acc.name, imported: 0, error: String(e) });
        }
      }
      return Response.json({ ok: true, from, accounts: summary });
    }

    return Response.json({ error: `azione sconosciuta: ${action}` }, { status: 400 });
  } catch (e) {
    return Response.json({ ok: false, error: String(e) }, { status: 500 });
  }
});
