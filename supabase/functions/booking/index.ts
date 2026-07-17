// Edge Function: booking
// Riceve le richieste di prenotazione dal sito camerepse (statico/pubblico) e le
// salva in public.prenotazioni con status='in_attesa', source='sito'.
// La tabella prenotazioni è protetta da RLS (solo service_role): qui usiamo la
// service_role key LATO SERVER (mai esposta al browser). Deploy con verify_jwt=false
// così la pagina pubblica può chiamare l'endpoint senza credenziali.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });

const STRUTTURE = ["es-vedra", "via-romagna"];

function clean(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s ? s.slice(0, max) : null;
}
const isDate = (s: string | null) => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  // honeypot anti-spam: se il campo nascosto è pieno è un bot → fingi successo
  if (clean(body.company, 200)) return json({ ok: true });

  const struttura = clean(body.struttura, 40);
  const camera = clean(body.camera, 80);
  const guest_name = clean(body.guest_name, 120);
  const guest_phone = clean(body.guest_phone, 60);
  const guest_email = clean(body.guest_email, 160);
  let checkin = clean(body.checkin, 10);
  let checkout = clean(body.checkout, 10);
  const notes = clean(body.notes, 1000);
  const guestsNum = Number(body.guests);

  if (!struttura || !STRUTTURE.includes(struttura))
    return json({ error: "struttura_non_valida" }, 400);
  if (!guest_name) return json({ error: "nome_obbligatorio" }, 400);
  if (!guest_phone && !guest_email)
    return json({ error: "contatto_obbligatorio" }, 400);
  if (!isDate(checkin)) checkin = null;
  if (!isDate(checkout)) checkout = null;

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
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "content-type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(record),
  });

  if (!res.ok) {
    console.error("insert failed", res.status, await res.text());
    return json({ error: "db_error" }, 502);
  }

  return json({ ok: true });
});
