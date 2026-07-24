// Edge Function: beds24-push
// Spinge la disponibilità DA GZ Brain VERSO Beds24: per ogni prenotazione che
// non arriva dalle OTA (diretta, sito, whatsapp, telefono) crea su Beds24 un
// "blocco" sulle date occupate, così Booking e Airbnb smettono di vendere quella
// camera. È il verso opposto di beds24-sync, che invece importa dalle OTA.
//
// PERCHÉ SERVE: Beds24 conosce solo le prenotazioni delle OTA. Le dirette le
// registri in GZ Brain e il channel manager non ne sa nulla → continua a vendere
// camere già occupate (è successo con Olena/Ion e con Neat/Pier).
//
// PERCHÉ DUE BLOCCHI PER CAMERA: in Beds24 la stessa camera fisica esiste due
// volte — come stanza della property Booking (342179) e come property Airbnb
// dedicata (342175-78) — e le due NON sono collegate da dependencies. Finché
// restano scollegate va bloccata ciascuna delle due, altrimenti un canale
// continua a vedere libero. Se un domani configuri le dependencies, basterà
// lasciare il primo id di ogni coppia.
//
// NIENTE CICLO DI RITORNO: i blocchi sono creati con status "black", e
// beds24-sync scarta le "black" (statusFor → null), quindi non rientrano mai
// come prenotazioni.
//
// SICUREZZA: di default gira in SIMULAZIONE e non scrive niente su Beds24.
// Per applicare davvero: POST/GET con ?apply=1
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const B24 = "https://beds24.com/api/v2";

const dbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "content-type": "application/json",
};

// camera del reticolo Via Po → [room Booking (prop 342179), room Airbnb (prop 342175-78)]
// Le due sono lo stesso letto pubblicato su due canali.
const ROOMS: Record<string, number[]> = {
  "Stanza 1 · Camera Queen": [706852, 706843],
  "Stanza 2 · Standard": [706851, 706844],
  "Stanza 3 · Camera King": [706850, 706845],
  "Stanza 4 · Ampia Matrimoniale": [706849, 706846],
};

// Il criterio NON è la fonte ma «Beds24 la conosce?»: tutto ciò che non ha un
// ext_id "beds24:*" è invisibile al channel manager e va bloccato. Copre le
// dirette (contante/sito/whatsapp) e anche le prenotazioni OTA che per qualche
// motivo non sono mai entrate in Beds24 (es. Pio Affusto e Livia Gabbianelli,
// due Booking mai importate).
function ignotaABeds24(p: any): boolean {
  return !String(p.ext_id ?? "").startsWith("beds24:");
}

async function beds24Token(): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/integrations?select=value&key=eq.beds24_refresh_token`, { headers: dbHeaders });
  const rows = await r.json();
  const refresh = rows?.[0]?.value;
  if (!refresh) throw new Error("refresh token mancante in integrations");
  const t = await fetch(`${B24}/authentication/token`, { headers: { refreshToken: refresh } });
  const j = await t.json();
  if (!j.token) throw new Error("Beds24 token non ottenuto: " + JSON.stringify(j).slice(0, 200));
  return j.token;
}

async function beds24Post(path: string, token: string, body: unknown): Promise<any> {
  const r = await fetch(`${B24}${path}`, {
    method: "POST",
    headers: { token, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return await r.json();
}

// Estrae gli id creati/modificati dalla risposta bulk di Beds24, che a seconda
// dell'operazione li mette in `new`, `modified` o direttamente in `id`.
function idsFromResponse(res: any): string[] {
  const out: string[] = [];
  for (const r of Array.isArray(res) ? res : [res]) {
    const id = r?.new?.id ?? r?.modified?.id ?? r?.id;
    if (id) out.push(String(id));
  }
  return out;
}

Deno.serve(async (req) => {
  try {
    const apply = new URL(req.url).searchParams.get("apply") === "1";
    const oggi = new Date().toISOString().slice(0, 10);

    // Prenotazioni da coprire: Via Po (Via Romagna non esiste su Beds24), non
    // provenienti dalle OTA, ancora in corso o future.
    const qs = new URLSearchParams({
      select: "id,guest_name,camera,checkin,checkout,status,source,ext_id,beds24_block_id",
      struttura: "eq.via-po",
    });
    const r = await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni?${qs}`, { headers: dbHeaders });
    const tutte: any[] = await r.json();

    const rilevanti = tutte.filter((p) => ignotaABeds24(p) && p.checkin && p.checkout);

    const daBloccare = rilevanti.filter((p) => p.status !== "cancellata" && p.checkout > oggi && !p.beds24_block_id);
    const daSbloccare = rilevanti.filter((p) => (p.status === "cancellata" || p.checkout <= oggi) && p.beds24_block_id);

    const azioni: any[] = [];
    let creati = 0, rimossi = 0, saltati = 0;
    let token = "";
    if (apply && (daBloccare.length || daSbloccare.length)) token = await beds24Token();

    // ── crea i blocchi mancanti ────────────────────────────────────────────
    for (const p of daBloccare) {
      const rooms = ROOMS[p.camera ?? ""];
      if (!rooms) {
        saltati++;
        azioni.push({ azione: "salta", motivo: "camera non mappata", ospite: p.guest_name, camera: p.camera });
        continue;
      }
      const payload = rooms.map((roomId) => ({
        roomId,
        status: "black",
        arrival: p.checkin,
        departure: p.checkout,
        numAdult: 1,
        firstName: "GZ Brain",
        lastName: `blocco — ${p.guest_name}`,
        notes: `Blocco automatico da GZ Brain (prenotazione ${p.source}). Non cancellare a mano.`,
      }));
      azioni.push({
        azione: "blocca", ospite: p.guest_name, camera: p.camera,
        dal: p.checkin, al: p.checkout, rooms,
      });
      if (!apply) continue;

      const res = await beds24Post("/bookings", token, payload);
      const ids = idsFromResponse(res);
      if (ids.length) {
        await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni?id=eq.${p.id}`, {
          method: "PATCH",
          headers: { ...dbHeaders, Prefer: "return=minimal" },
          body: JSON.stringify({ beds24_block_id: ids.join(",") }),
        });
        creati++;
      } else {
        azioni.push({ azione: "errore", ospite: p.guest_name, dettaglio: JSON.stringify(res).slice(0, 300) });
      }
    }

    // ── rimuove i blocchi non più necessari (cancellate o già passate) ─────
    for (const p of daSbloccare) {
      const ids = String(p.beds24_block_id).split(",").filter(Boolean);
      azioni.push({ azione: "sblocca", ospite: p.guest_name, motivo: p.status === "cancellata" ? "cancellata" : "già passata", ids });
      if (!apply) continue;
      await beds24Post("/bookings", token, ids.map((id) => ({ id: Number(id), status: "cancelled" })));
      await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni?id=eq.${p.id}`, {
        method: "PATCH",
        headers: { ...dbHeaders, Prefer: "return=minimal" },
        body: JSON.stringify({ beds24_block_id: null }),
      });
      rimossi++;
    }

    return new Response(JSON.stringify({
      ok: true,
      modalita: apply ? "APPLICATO" : "SIMULAZIONE (nessuna scrittura su Beds24 — usa ?apply=1)",
      da_bloccare: daBloccare.length, da_sbloccare: daSbloccare.length,
      creati, rimossi, saltati, azioni,
    }, null, 1), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
