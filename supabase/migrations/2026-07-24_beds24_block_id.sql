-- Traccia il "blocco" creato su Beds24 per una prenotazione che NON viene dalle
-- OTA (diretta, sito, whatsapp…). Serve al push di disponibilità: senza questo id
-- non sapremmo quale blocco aggiornare o rimuovere quando la prenotazione cambia
-- date o viene cancellata, e ne creeremmo uno nuovo a ogni giro.
alter table public.prenotazioni
  add column if not exists beds24_block_id text;

comment on column public.prenotazioni.beds24_block_id is
  'ID della prenotazione "black" creata su Beds24 per bloccare le date sulle OTA. Solo per prenotazioni non-OTA di Via Po (Via Romagna non esiste in Beds24).';

create index if not exists prenotazioni_beds24_block_id_idx
  on public.prenotazioni (beds24_block_id) where beds24_block_id is not null;
