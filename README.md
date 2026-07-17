# GZ Brain

App nativa macOS (SwiftUI + AppKit): centro di controllo per progetti, leads/CRM e fatturazione.
Config Supabase in `~/Library/Application Support/dev.gz.brain/config.json`
(chiavi: `supabase_url`, `supabase_secret_key`).

## Cosa contiene

- **Panoramica** — KPI (progetti attivi, eventi oggi, leads) + griglia progetti con barre attività animate
- **Progetti** — griglia 3 colonne; modifica via modal (creazione/eliminazione restano al Direttore)
- **Dettaglio progetto** — layout semplice senza leads, layout Energizzo completo con leads:
  pipeline 4×2 con filamenti animati, pannello tipo servizio con scie, filtri per stadio,
  viste Tabella (paginata) / Card (mini-Italia SVG con pin reali) / Mappa (MapKit con clustering nativo)
- **Pagina lead** — anagrafica, contatti/persone, note (aggiunta), timeline attività, binario stadi cliccabile
- **Tab Code** — terminale nativo SwiftTerm nella cartella del progetto con `claude` avviato automaticamente
- **QuickDash** — popover dalla barra menu (esagono) con stato progetti e ultime attività
- **Pallino blu** — quarto semaforo nella titlebar, posizionato a runtime dai frame reali dei bottoni nativi
  (passo/dimensione/quota identici su qualsiasi macOS), toggle sidebar, dim senza focus, glifo su hover zona

## Comandi

- `swift run` — avvio dev
- `scripts/bundle.sh` — build release + bundle + installazione in `/Applications/GZ Brain.app`

## Note

- Tema: solo holo (gli altri 6 temi Tauri arriveranno dopo l'eventuale adozione)
- La tab Code richiede `local_path` sul progetto (oggi presente solo su energizzo-website;
  gli altri vanno collegati via Direttore)
