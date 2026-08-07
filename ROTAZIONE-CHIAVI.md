# Rotazione delle chiavi Supabase

Stato: **preparata, non ancora eseguita.** Tutto il codice regge già entrambi i
formati di chiave, quindi la rotazione si può fare in qualunque momento senza
finestra di manutenzione. Manca solo la parte da dashboard, che nessuno script
può fare al posto tuo.

## Perché

La chiave attuale è una `service_role` legacy in formato JWT (`eyJhbGciOi…`).
Le chiavi legacy **non si revocano singolarmente**: per invalidarne una bisogna
ruotare il JWT secret del progetto, e questo invalida anche la `anon`. Oggi, se
quella chiave finisse dove non deve, per chiuderla dovresti far cadere insieme
camerepse.it, l'app iOS, le edge function e i cron.

Le chiavi nuove (`sb_secret_…`) si creano, si nominano e si revocano una alla
volta. Le legacy funzionano fino a fine 2026.

## Cosa è già stato fatto

- La chiave non è più in chiaro nei comandi `cron.job`: sta nel Vault come
  secret `service_role_key`, letta al volo da `public.chiama_edge()`.
- I due cron Beds24 (integrazione dismessa) sono stati rimossi: erano inattivi
  e si portavano dietro la chiave in chiaro.
- Tutti i client mandano la chiave su `apikey` e aggiungono
  `Authorization: Bearer` **solo** se la chiave comincia per `eyJ`:
  - `Sources/HubProto/SupabaseClient.swift` → `firmaLaRichiesta()`
  - `supabase/functions/booking/index.ts`
  - `supabase/functions/social-insights/index.ts`
  - `gz-mcp/src/db.js`
  - `public.chiama_edge()` (in database)
- Le due edge function attive leggono `SUPABASE_SECRET_KEYS['default']` se
  esiste, altrimenti ricadono su `SUPABASE_SERVICE_ROLE_KEY`.
- `social-insights` ora autorizza le chiamate **nel proprio codice**, perché il
  controllo `verify_jwt` della piattaforma capisce solo le chiavi legacy e va
  spento. **Non** confronta la chiave con una variabile d'ambiente: la verifica
  **usandola**, con una lettura su `movimenti` (RLS senza policy → solo una
  chiave di servizio la legge). Se il database accetta la chiave, chi chiama ha
  davvero i privilegi.

  > Perché così e non con un confronto: il primo tentativo (2026-08-06)
  > confrontava con `SUPABASE_SECRET_KEYS` / `SUPABASE_SERVICE_ROLE_KEY`. In
  > questo runtime **nessuna delle due risulta popolata**, quindi la lista delle
  > chiavi valide era vuota e la funzione ha risposto **401 a tutti per due
  > giorni** — cron compreso. Legare l'autorizzazione a una variabile che la
  > piattaforma *potrebbe* iniettare è fragile. La sonda funziona con la chiave
  > legacy, con `sb_secret_…` e durante la rotazione, senza modifiche.
  > Verificato: chiave di servizio → passa; publishable, chiave inventata o
  > nessuna chiave → 401.

## Le due trappole che hanno reso necessario tutto questo

1. **`Authorization: Bearer sb_secret_…` viene rifiutato.** Le chiavi nuove non
   sono JWT: la piattaforma prova a decodificarle e risponde `Invalid JWT`.
   Vanno sull'header `apikey`.
2. **`verify_jwt = true` blocca le chiavi nuove.** Il controllo integrato
   riconosce solo i JWT legacy. Le funzioni chiamate con una chiave nuova
   devono girare con `verify_jwt = false` e autorizzare da sole.

## Procedura

1. **Crea la chiave segreta**
   Dashboard → Settings → API Keys → *Publishable and secret API keys* →
   crea una secret key di nome `default`. Copiala: si vede una volta sola.

2. **Aggiorna il Vault** (copre tutti i cron in un colpo)
   ```sql
   select vault.update_secret(
     (select id from vault.secrets where name = 'service_role_key'),
     'sb_secret_…'
   );
   ```

3. **Aggiorna il Mac**
   `~/Library/Application Support/dev.gz.brain/config.json` → campo
   `supabase_secret_key`. Il file è già a permessi `600`, lasciali così.

4. **Aggiorna il server del connettore MCP**
   Su Hetzner: `/etc/gz-mcp.env` → `SUPABASE_SERVICE_ROLE_KEY=sb_secret_…`,
   poi riavvia il servizio.

5. **Spegni `verify_jwt` su `social-insights`**
   Dashboard → Edge Functions → social-insights → `verify_jwt = false`.
   Il controllo di autorizzazione è già dentro la funzione (v4, distribuita il
   2026-08-07), quindi si può fare in qualunque momento.

   I due cron di NCREATIVE (`nc-social-suggestions`, `nc-social-audit`) sono
   **in pausa** dal 2026-08-07: il modulo social è vuoto e manca
   `ANTHROPIC_API_KEY`. Si riaccendono con
   `select cron.alter_job((select jobid from cron.job where jobname='nc-social-suggestions'), active => true);`

6. **Ridistribuisci `booking`**
   `social-insights` è già alla v4 con la sonda. Per `booking` serve la CLI
   (`supabase functions deploy booking`) oppure il deploy da dashboard —
   sulla macchina la CLI **non è installata**.

7. **Ricompila e reinstalla l'app**
   `scripts/bundle.sh`

8. **Verifica prima di revocare**
   - apri GZ Brain, carica Tesoreria e Camere PSE
   - manda una richiesta di prova dal form `/prenota` di camerepse.it
   - `select public.chiama_edge('social-insights', '{"mode":"suggestions"}'::jsonb);`
   - chiedi qualcosa a GZ Brain dal telefono via MCP
   - `select public.quadratura_notturna();`

9. **Solo a questo punto: disattiva le chiavi legacy**
   Dashboard → Settings → API Keys → tab *Legacy API keys* → disattiva
   `anon` e `service_role`.
   ⚠️ L'app iOS usa già la publishable key (`sb_publishable_…`), quindi non è
   toccata. Controlla però che i siti gz-ibiza e wallis-57 usino la
   publishable e non la vecchia `anon` prima di disattivarla.

## Dopo

Da quel momento la chiave della tesoreria si revoca da sola, dalla dashboard,
senza spegnere nient'altro. È tutto il punto dell'esercizio.
