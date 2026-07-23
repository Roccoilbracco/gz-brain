-- Camere PSE — pulizie e colazioni diventano uscite reali in Cassa, dai
-- soggiorni che partono dal 23/07/2026 in poi (inizio automazione). Prima di
-- quella data è già registrato a mano nell'Excel e va lasciato com'è.
--
-- `contabilizzata` = true → già nei conti / storico, non genera uscita.
-- Il cutoff (inizio automazione) è il 23/07/2026, sia per l'update una-tantum
-- sia dentro sync_camere_pse() per le righe che crea d'ora in poi.
alter table public.pulizie   add column if not exists contabilizzata boolean not null default false;
alter table public.colazioni add column if not exists contabilizzata boolean not null default false;

update public.pulizie   set contabilizzata = (data < '2026-07-23');
update public.colazioni set contabilizzata = (coalesce(partenza, arrivo) < '2026-07-23');

-- sync_camere_pse() aggiornata nello stesso deploy:
--  • incasso diretto instradato al conto scelto (Cassa default, Beeper bonifico,
--    Massimo OTA), appena la prenotazione è pagata;
--  • uscita pulizia (20 €) quando la pulizia è «fatta» e contabilizzata=false;
--  • uscita colazioni (costo pieno) quando la colazione è «servita»;
--  • le righe nuove nascono contabilizzata = (checkout < '2026-07-23').
