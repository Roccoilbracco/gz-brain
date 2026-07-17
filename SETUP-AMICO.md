# GZ Brain — setup sul tuo Mac

App nativa macOS (SwiftUI) per gestire i tuoi progetti, i lead immobiliari,
le proprietà e le prenotazioni. Questo file spiega come metterla in funzione.

## 1. Requisiti
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`) — per compilare Swift
- `claude` CLI installato (per il tab Code) — https://claude.ai/code

## 2. Metti il repo in `~/Developer`
```bash
mkdir -p ~/Developer
# se ti è arrivato come bundle:
git clone gz-brain.bundle ~/Developer/gz-brain
# (oppure clona dal repo GitHub che ti hanno indicato)
cd ~/Developer/gz-brain
```

## 3. Config Supabase (il TUO database)
L'app legge le chiavi da un file JSON. Crealo con le tue chiavi Supabase:
```bash
mkdir -p ~/Library/Application\ Support/dev.gz.brain
cat > ~/Library/Application\ Support/dev.gz.brain/config.json <<'JSON'
{
  "supabase_url": "https://TUO-REF.supabase.co",
  "supabase_secret_key": "sb_secret_LA-TUA-SERVICE-KEY"
}
JSON
```
- `supabase_url`: Project Settings → API → Project URL
- `supabase_secret_key`: la **service_role key** (Project Settings → API)
- NON committare mai questo file (contiene un segreto). Sta fuori dal repo.

Il database (tabelle, RLS, bucket) è **già stato creato** sul tuo progetto Supabase.
Se dovessi ricrearlo da zero, il setup completo è in `supabase/schema.sql`
(SQL Editor → incolla → Run).

## 4. Build e installazione
```bash
bash scripts/bundle.sh
```
Compila, crea l'icona e installa `/Applications/GZ Brain.app`. Poi apri l'app.
La spia in Impostazioni deve dire "Supabase collegato".

## 5. Progetto "Camere PSE" — sistema il percorso locale
Il progetto è già nel DB, ma il `local_path` punta a un altro Mac.
1. Clona il sito: `git clone https://github.com/Roccoilbracco/camerepse-sito ~/Developer/camerepse-sito`
2. Nell'app: seleziona Camere PSE → Modifica → oppure ricrealo dal pulsante
   "+ Aggiungi progetto" scegliendo la cartella `~/Developer/camerepse-sito`.
   Serve al tab Code (Claude locale) e alla Preview.

## 6. Dati demo da pulire (prima dell'uso vero)
Nel DB ci sono dati di esempio (lead, proprietà, prenotazioni). Per svuotarli,
dal SQL Editor Supabase:
```sql
truncate public.re_leads, public.proprieta cascade;   -- svuota anche storico/documenti
truncate public.prenotazioni;
-- le foto/documenti demo restano nel bucket 'proprieta': cancellali dallo Storage se vuoi
```

## 7. Integrazione prenotazioni Airbnb / Booking (da fare)
Airbnb e Booking non hanno API dirette per il singolo host. Opzioni:
- **iCal 2-way (gratis, consigliato per iniziare)**: esporta il link .ics da Airbnb
  (Calendario → Sincronizza) e Booking (Tariffe e disponibilità → Sincronizza),
  un job ogni 15-30 min li legge e scrive in `public.prenotazioni`
  (`source='airbnb'`/`'booking'`, date, camera). Genera anche un iCal dalle
  prenotazioni dirette e importalo su Airbnb/Booking per bloccare le date.
  Limite: l'iCal dà solo date, non prezzo/ospite.
- **Channel manager (Smoobu/Beds24/Hostaway, a pagamento)**: API complete, sync
  bidirezionale, dati ospite+prezzo.
- **Parsing email (Gmail API)**: legge le mail di conferma → più dati, ma fragile.

Il sito camerepse.it può scrivere le richieste dirette in `public.prenotazioni`
con `status='in_attesa'`: compaiono subito nella dashboard.

## Struttura DB (riferimento)
- `projects` — progetti (Camere PSE, ecc.)
- `re_leads` — lead immobiliari (CRM), pipeline kanban
- `proprieta` + `proprieta_storico` + `proprieta_documenti` — immobili, storico vendite, documenti
- `prenotazioni` — prenotazioni camere (dashboard Camere PSE)
- `clienti`, `commesse`, `fatture`, `spese`, ecc. — gestionale
Tutte con RLS attivo: accede solo la service_role key.
