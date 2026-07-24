// Edge Function: beds24-sync
// Importa le prenotazioni da Beds24 (Airbnb/Booking) in public.prenotazioni.
// - refresh token Beds24 letto da public.integrations (solo service_role)
// - mapping struttura dal nome proprietà, camera dal nome stanza Beds24
// - dedup su ext_id ("beds24:<id>"): nuove → INSERT; esistenti → PATCH dei soli
//   campi "di competenza" Beds24 (date, ospite, importo, camera). NON tocca
//   status/paid_cents delle righe già presenti (li gestisci tu in app), tranne
//   propagare le CANCELLAZIONI. Così i check-in/out e i pagamenti locali restano.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const B24 = "https://beds24.com/api/v2";

const dbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "content-type": "application/json",
};

function decodeEntities(s: string): string {
  return s
    .replace(/&#39;/g, "'").replace(/&#x27;/gi, "'")
    .replace(/&quot;/g, '"').replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ").trim();
}
const clean = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s ? s : null;
};
function strutturaFor(propName: string): string {
  return /romagna/i.test(propName) ? "via-romagna" : "via-po";
}
// nomi camera OTA → nomi reali del reticolo gestionale (Via Po)
// Booking usa i nomi commerciali (Queen/Standard/King/Large), Airbnb pubblica
// una property per stanza ("Affittacamere Es Vedrà , Stanza N ..."): stesso letto,
// due nomi diversi, entrambi devono cadere sulla stessa casella del planning.
const RETICOLO_VIA_PO = [
  "Stanza 1 · Camera Queen",
  "Stanza 2 · Standard",
  "Stanza 3 · Camera King",
  "Stanza 4 · Ampia Matrimoniale",
];
function normalizeRoom(name: string | null): string | null {
  if (!name) return name;
  const n = name.toLowerCase();
  if (n.includes("queen")) return RETICOLO_VIA_PO[0];
  if (n.includes("standard")) return RETICOLO_VIA_PO[1];
  if (n.includes("king")) return RETICOLO_VIA_PO[2];
  if (n.includes("large")) return RETICOLO_VIA_PO[3];
  const m = n.match(/stanza\s*([1-4])/); // Airbnb: "... , Stanza 3"
  if (m) return RETICOLO_VIA_PO[Number(m[1]) - 1];
  return name;
}
function sourceFor(channel: string, referer: string): string {
  const c = (channel || "").toLowerCase();
  const r = (referer || "").toLowerCase();
  if (c.includes("airbnb") || r.includes("airbnb")) return "airbnb";
  if (c.includes("booking") || r.includes("booking")) return "booking";
  return c || r || "ota";
}
// stato Beds24 → stato prenotazioni; null = da ignorare (blocco proprietario)
function statusFor(s: string): string | null {
  switch ((s || "").toLowerCase()) {
    case "confirmed":
    case "new": return "confermata";
    case "request":
    case "inquiry": return "in_attesa";
    case "cancelled": return "cancellata";
    case "black":
    case "blocked": return null;
    default: return "confermata";
  }
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

async function beds24Get(path: string, token: string): Promise<any> {
  const r = await fetch(`${B24}${path}`, { headers: { token } });
  return await r.json();
}

Deno.serve(async () => {
  try {
    const token = await beds24Token();

    // mappe proprietà/stanze: id → nome
    const props = await beds24Get("/properties?includeAllRooms=true", token);
    const propName: Record<number, string> = {};
    const roomName: Record<number, string> = {};
    for (const p of props.data ?? []) {
      propName[p.id] = p.name ?? "";
      for (const rt of p.roomTypes ?? p.rooms ?? []) roomName[rt.id] = rt.name ?? "";
    }

    // tutte le prenotazioni (paginazione).
    // NB: /bookings senza filtri restituisce solo i soggiorni non ancora conclusi
    // (Beds24 taglia i partiti), quindi modifiche e cancellazioni tardive su una
    // prenotazione già passata non arriverebbero mai. arrivalFrom tiene lo storico.
    const arrivalFrom = "2025-01-01";
    async function fetchAll(qs: string): Promise<any[]> {
      const out: any[] = [];
      let page = 1;
      while (true) {
        const res = await beds24Get(`/bookings?${qs}&page=${page}`, token);
        out.push(...(res.data ?? []));
        if (!res.pages?.nextPageExists) break;
        page++;
        if (page > 50) break; // guardia
      }
      return out;
    }
    // ⚠️ Beds24 NON restituisce le prenotazioni cancellate nel fetch normale:
    // vanno chieste esplicitamente con status=cancelled. Senza questa seconda
    // chiamata una cancellazione non arriverebbe MAI in app, la camera
    // resterebbe occupata e si rischia di rivenderla → overbooking.
    const bookings = await fetchAll(`arrivalFrom=${arrivalFrom}`);
    const cancellate = await fetchAll(`arrivalFrom=${arrivalFrom}&status=cancelled`);
    const visti = new Set(bookings.map((b) => b.id));
    for (const c of cancellate) if (!visti.has(c.id)) bookings.push(c);

    // righe già presenti (per ext_id)
    const exRes = await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni?select=id,ext_id&ext_id=not.is.null`, { headers: dbHeaders });
    const existing: { id: string; ext_id: string }[] = await exRes.json();
    const byExt = new Map(existing.map((e) => [e.ext_id, e.id]));

    const toInsert: any[] = [];
    let inserted = 0, updated = 0, skipped = 0;

    for (const b of bookings) {
      const st = statusFor(b.status);
      const extId = `beds24:${b.id}`;
      if (st === null) { skipped++; continue; } // blocco proprietario

      const pName = propName[b.propertyId] ?? "";
      const base: Record<string, unknown> = {
        struttura: strutturaFor(pName),
        camera: normalizeRoom(clean(roomName[b.roomId])) ?? (b.roomId ? `Camera ${b.roomId}` : null),
        guest_name: decodeEntities(`${b.firstName ?? ""} ${b.lastName ?? ""}`) || "Ospite OTA",
        guest_phone: clean(b.phone) ?? clean(b.mobile),
        guest_email: clean(b.email),
        checkin: clean(b.arrival),
        checkout: clean(b.departure),
        guests: (Number(b.numAdult) || 0) + (Number(b.numChild) || 0) || null,
        amount_cents: Math.round((Number(b.price) || 0) * 100),
        source: sourceFor(b.channel, b.referer),
        conto_id: "massimo", // i soldi delle OTA vanno sul conto Massimo Affittacamere
        notes: clean(b.referer) ? `${b.referer}${b.apiReference ? ` · rif. ${b.apiReference}` : ""}` : null,
        ext_id: extId,
      };

      const existingId = byExt.get(extId);
      if (!existingId) {
        // Cancellata che non abbiamo mai importato: non c'è niente da annullare,
        // inserirla creerebbe solo rumore nel planning.
        if (st === "cancellata") { skipped++; continue; }
        toInsert.push({ ...base, status: st });
      } else {
        // aggiorna solo i campi di competenza Beds24; propaga solo le cancellazioni
        const patch: Record<string, unknown> = { ...base };
        if (st === "cancellata") patch.status = "cancellata";
        const pr = await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni?id=eq.${existingId}`, {
          method: "PATCH",
          headers: { ...dbHeaders, Prefer: "return=minimal" },
          body: JSON.stringify(patch),
        });
        if (pr.ok) updated++;
      }
    }

    if (toInsert.length) {
      const ir = await fetch(`${SUPABASE_URL}/rest/v1/prenotazioni`, {
        method: "POST",
        headers: { ...dbHeaders, Prefer: "return=minimal" },
        body: JSON.stringify(toInsert),
      });
      if (ir.ok) inserted = toInsert.length;
      else return new Response(JSON.stringify({ error: "insert_failed", detail: (await ir.text()).slice(0, 300) }), { status: 502, headers: { "content-type": "application/json" } });
    }

    return new Response(JSON.stringify({ ok: true, fetched: bookings.length, cancellate: cancellate.length, inserted, updated, skipped }), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
