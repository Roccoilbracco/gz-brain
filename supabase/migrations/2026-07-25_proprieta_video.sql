-- Video dell'immobile, accanto alle foto.
--
-- Stessa forma di `photos`: un array di path dentro il bucket pubblico
-- `proprieta`, sotto <id>/video/. Ordine dell'array = ordine di riproduzione,
-- il primo è quello che si mostra per primo, come la copertina delle foto.
alter table public.proprieta
  add column if not exists videos text[] default '{}'::text[];

comment on column public.proprieta.videos is
  'Path dei video nel bucket pubblico proprieta (<id>/video/<file>). Ordine = ordine di presentazione.';

-- I siti (gz-ibiza, wallis-57) leggono con la chiave anon, che ha permessi
-- colonna per colonna dopo l'hardening: senza questo grant la loro query
-- fallisce in blocco e la lista immobili sparisce dal sito.
grant select (videos) on public.proprieta to anon;
