-- ─────────────────────────────────────────────────────────────────────────────
-- Rimozione di `proprieta.site_visibility`
--
-- Sostituita da 2026-07-24_project_slug_immobiliare.sql con due colonne che
-- dicono due cose diverse: `project_slug` (di chi è l'immobile) e `pubblicata`
-- (se è online sul sito di quel progetto).
--
-- Verifiche fatte prima di scrivere questo file (2026-07-24):
--   · nessuna vista, funzione o policy la cita
--   · GZ Brain non la legge più (build installata in /Applications)
--   · i repo gz-ibiza e wallis-57 filtrano su project_slug + pubblicata,
--     e le loro build in out/ non contengono più la stringa
--   · nessuna delle due app Next è in produzione: gzibizaproperties.com serve
--     un sito Joomla che non tocca Supabase, Wallis non ha ancora un dominio
--
-- Il GRANT per colonna verso `anon` cade da solo insieme alla colonna.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.proprieta drop column site_visibility;
