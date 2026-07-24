// Edge Function: booking
// Riceve le richieste di prenotazione dal sito camerepse (statico/pubblico) e le
// salva in public.prenotazioni con status='in_attesa', source='sito'.
// La tabella prenotazioni è protetta da RLS (solo service_role): qui usiamo la
// service_role key LATO SERVER (mai esposta al browser). Deploy con verify_jwt=false
// così la pagina pubblica può chiamare l'endpoint senza credenziali.
//
// Essendo aperto, l'endpoint è anche la porta più comoda per riempire il
// calendario di prenotazioni finte — e ogni riga finta si porta dietro le
// pulizie e le colazioni che `sync_camere_pse()` genera in automatico. Da qui
// il limite per IP e i controlli sulle date.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const dbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "content-type": "application/json",
};

// Il sito è servito da camerepse.it. Un `*` lascerebbe che qualunque pagina
// altrui chiami l'endpoint dal browser dei suoi visitatori.
const ORIGINI = [
  "https://camerepse.it",
  "https://www.camerepse.it",
  "http://localhost:3000",
];

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINI.includes(origin) ? origin : ORIGINI[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    Vary: "Origin",
  };
}

const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(req), "content-type": "application/json" },
  });

const STRUTTURE = ["via-po", "via-romagna"];
// "es-vedra" è il vecchio slug di Via Po. Il sito è un export statico: un browser
// con il JS ancora in cache può continuare a inviarlo per un po', quindi lo
// accettiamo e lo normalizziamo invece di rifiutare la prenotazione.
const LEGACY_SLUG: Record<string, string> = { "es-vedra": "via-po" };

const MAX_PER_ORA = 5;
const MAX_NOTTI = 120;

function clean(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s ? s.slice(0, max) : null;
}
const isDate = (s: string | null) => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);
const isEmail = (s: string) => /^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$/.test(s);

const giorni = (a: string, b: string) =>
  Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);

/// L'IP non si salva mai in chiaro: serve per contare, non per schedare.
async function hashIP(req: Request): Promise<string | null> {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  if (!ip) return null;
  const bytes = new TextEncoder().encode(`gz-brain|${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// true = si può procedere. In caso di dubbio (DB irraggiungibile) lascia
/// passare: meglio una prenotazione di troppo che il form rotto.
async function sottoLimite(ipHash: string): Promise<boolean> {
  const da = new Date(Date.now() - 3_600_000).toISOString();
  const url = `${SUPABASE_URL}/rest/v1/web_rate_limit` +
    `?select=id&scope=eq.booking&ip_hash=eq.${ipHash}&created_at=gt.${da}` +
    `&limit=${MAX_PER_ORA}`;
  try {
    const res = await fetch(url, { headers: dbHeaders });
    if (!res.ok) return true;
    return ((await res.json()) as unknown[]).length < MAX_PER_ORA;
  } catch {
    return true;
  }
}

async function segnaTentativo(ipHash: string): Promise<void> {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/web_rate_limit`, {
      method: "POST",
      headers: { ...dbHeaders, Prefer: "return=minimal" },
      body: JSON.stringify({ scope: "booking", ip_hash: ipHash }),
    });
  } catch {
    // Il contatore non deve mai far fallire una prenotazione vera.
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(req, { error: "invalid_json" }, 400);
  }

  // honeypot anti-spam: se il campo nascosto è pieno è un bot → fingi successo
  if (clean(body.company, 200)) return json(req, { ok: true });

  // Si controlla il limite subito, ma lo si CONSUMA solo a prenotazione
  // andata a buon fine (in fondo): altrimenti cinque email sbagliate di fila
  // chiuderebbero fuori un cliente vero per un'ora.
  const ipHash = await hashIP(req);
  if (ipHash && !(await sottoLimite(ipHash))) {
    return json(req, { error: "troppe_richieste" }, 429);
  }

  let struttura = clean(body.struttura, 40);
  if (struttura && LEGACY_SLUG[struttura]) struttura = LEGACY_SLUG[struttura];
  const camera = clean(body.camera, 80);
  const guest_name = clean(body.guest_name, 120);
  const guest_phone = clean(body.guest_phone, 60);
  const guest_email = clean(body.guest_email, 160);
  let checkin = clean(body.checkin, 10);
  let checkout = clean(body.checkout, 10);
  const notes = clean(body.notes, 1000);
  const guestsNum = Number(body.guests);

  if (!struttura || !STRUTTURE.includes(struttura))
    return json(req, { error: "struttura_non_valida" }, 400);
  if (!guest_name) return json(req, { error: "nome_obbligatorio" }, 400);
  if (!guest_phone && !guest_email)
    return json(req, { error: "contatto_obbligatorio" }, 400);
  if (guest_email && !isEmail(guest_email))
    return json(req, { error: "email_non_valida" }, 400);
  if (!isDate(checkin)) checkin = null;
  if (!isDate(checkout)) checkout = null;

  // Date coerenti: niente soggiorni al contrario, nel passato remoto o lunghi
  // un anno. Erano il modo più rapido per sporcare il calendario.
  if (checkin && checkout) {
    const notti = giorni(checkin, checkout);
    if (notti <= 0) return json(req, { error: "date_invertite" }, 400);
    if (notti > MAX_NOTTI) return json(req, { error: "soggiorno_troppo_lungo" }, 400);
  }
  if (checkin) {
    const daOggi = giorni(new Date().toISOString().slice(0, 10), checkin);
    if (daOggi < -365 || daOggi > 730)
      return json(req, { error: "data_fuori_intervallo" }, 400);
  }

  const record = {
    struttura,
    camera,
    guest_name,
    guest_phone,
    guest_email,
    checkin,
    checkout,
    guests:
      Number.isFinite(guestsNum) && guestsNum > 0
        ? Math.min(Math.floor(guestsNum), 99)
        : null,
    notes,
    status: "in_attesa",
    source: "sito",
  };

  const res = await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni`, {
    method: "POST",
    headers: { ...dbHeaders, Prefer: "return=minimal" },
    body: JSON.stringify(record),
  });

  if (!res.ok) {
    console.error("insert failed", res.status, await res.text());
    return json(req, { error: "db_error" }, 502);
  }

  if (ipHash) await segnaTentativo(ipHash);

  return json(req, { ok: true });
});
