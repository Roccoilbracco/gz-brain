-- Camere PSE — pulizie e colazioni diventano uscite reali in Cassa, ma solo
-- dai prossimi soggiorni (agosto in poi). Luglio è già registrato a mano
-- nell'Excel e va lasciato com'è per non contarlo due volte.
--
-- Aggiunge `contabilizzata` alle due tabelle (true = già nei conti / storico,
-- non genera uscita). Tutto ciò che parte prima di agosto = true; da agosto in
-- poi = false, e sync_camere_pse() crea l'uscita quando la pulizia è «fatta» e
-- la colazione «servita». Vedi la funzione aggiornata nello stesso deploy.
alter table public.pulizie   add column if not exists contabilizzata boolean not null default false;
alter table public.colazioni add column if not exists contabilizzata boolean not null default false;

update public.pulizie   set contabilizzata = (data < '2026-08-01');
update public.colazioni set contabilizzata = (coalesce(partenza, arrivo) < '2026-08-01');

-- sync_camere_pse() ridefinita: instrada l'incasso diretto al conto scelto
-- (Cassa di default, Beeper se bonifico, Massimo se OTA) e genera le uscite
-- pulizia/colazioni per le righe contabilizzata=false quando sono fatte/servite.
-- Corpo completo applicato via migration pulizie_colazioni_contabilizzazione.
