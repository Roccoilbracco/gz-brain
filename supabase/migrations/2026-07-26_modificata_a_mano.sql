-- Le prenotazioni delle OTA le riscriveva la sincronizzazione a ogni giro:
-- si correggeva la camera (o l'importo, o le date) e venti minuti dopo era
-- tornata come l'aveva mandata Beds24. Da qui in poi una riga toccata a mano
-- porta la data della modifica, e beds24-sync la lascia stare.
--
-- Resta un'eccezione, ed è voluta: la CANCELLAZIONE arriva sempre. Se il
-- cliente disdice sul canale e noi non lo vediamo, la camera resta occupata
-- nel planning e si rischia di rivenderla.

alter table public.prenotazioni
  add column if not exists modificata_a_mano timestamptz;

comment on column public.prenotazioni.modificata_a_mano is
  'Quando una persona ha modificato questa riga dall''app. Se valorizzata, beds24-sync non sovrascrive più i campi (tranne propagare le cancellazioni).';

-- Le correzioni fatte finora vanno protette anche loro: tutte le prenotazioni
-- OTA già toccate a mano oggi, e in generale quelle passate, restano come sono.
update public.prenotazioni
   set modificata_a_mano = coalesce(modificata_a_mano, updated_at)
 where ext_id like 'beds24:%'
   and (checkout < current_date or updated_at > created_at + interval '1 minute');
