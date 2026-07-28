-- ═══════════════════════════════════════════════════════════════════════════
-- Camere PSE — la pulizia e le colazioni seguono la prenotazione
--
-- sync_camere_pse() apriva la riga di pulizia al primo giro e poi non la
-- guardava più: se il check-out si spostava, se cambiava la camera o il numero
-- di ospiti, la riga restava com'era nata. Bastava una modifica arrivata da
-- Beds24 (o una correzione a mano sulla prenotazione) e Servizi mostrava una
-- pulizia in un giorno in cui non c'è nessun check-out, o colazioni contate per
-- due persone quando l'ospite è uno solo. Oggi in DB c'erano già due righe così.
--
-- Da qui la riga generata si riallinea a ogni giro, e con lei l'uscita che ne
-- era nata (importo, data, descrizione, casa). Se il check-out torna nel futuro
-- la pulizia torna «prevista» e l'uscita si ritira: si rifarà da sé al momento
-- giusto. Vale solo per le righe generate e non ancora toccate da una persona.
--
-- `modificata_a_mano` è la stessa convenzione delle prenotazioni (vedi
-- 2026-07-26_modificata_a_mano.sql): valorizzata = la sincronizzazione non
-- riscrive più quella riga. Le due righe già divergenti oggi vengono marcate
-- così: sono scelte di chi le ha messe lì, non errori da raddrizzare.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.pulizie   add column if not exists modificata_a_mano timestamptz;
alter table public.colazioni add column if not exists modificata_a_mano timestamptz;

comment on column public.pulizie.modificata_a_mano is
  'Quando una persona ha corretto questa riga. Se valorizzata, sync_camere_pse() non la riallinea più alla prenotazione.';
comment on column public.colazioni.modificata_a_mano is
  'Quando una persona ha corretto questa riga. Se valorizzata, sync_camere_pse() non la riallinea più alla prenotazione.';

-- Quello che diverge OGGI è già stato deciso da qualcuno: si protegge, non si
-- raddrizza. Da domani in poi diverge solo ciò che cambia sulla prenotazione.
update public.pulizie x
   set modificata_a_mano = now()
  from public.prenotazioni p
 where x.prenotazione_id = p.id
   and x.modificata_a_mano is null
   and (x.data is distinct from p.checkout or x.casa is distinct from p.struttura);

update public.colazioni c
   set modificata_a_mano = now()
  from public.prenotazioni p
 where c.prenotazione_id = p.id
   and c.modificata_a_mano is null
   and (c.arrivo is distinct from p.checkin
        or c.partenza is distinct from p.checkout
        or c.persone is distinct from greatest(1, coalesce(p.guests, 1)));

create or replace function public.sync_camere_pse()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  n_pul int := 0; n_fatte int := 0; n_col int := 0; n_col_upd int := 0; n_cassa int := 0;
  n_usc_pul int := 0; n_usc_col int := 0; n_ota int := 0; n_riall int := 0; n_tolti int := 0;
  n_mutuo int := 0; n_utenze int := 0;
  n_pul_riall int := 0; n_col_riall int := 0; n_prev int := 0;
  n_usc_riall int := 0; n_usc_tolte int := 0; n_tmp int := 0;
  inizio date := '2026-07-23';
  mutuo_da date := '2026-07-01';    -- prima rata del mutuo Via Po registrata qui
  utenze_da date := '2026-07-01';   -- prima delle bollette di Via Po che passano da Carifermo
  oggi date := current_date;
begin
  -- pulizie: NON per gli Educamp (soggiorni lunghi, pulizie nel loro modello)
  insert into public.pulizie (data, casa, descrizione, stato, costo_cents, prenotazione_id, sort_order, contabilizzata)
  select p.checkout, p.struttura,
         coalesce(nullif(p.guest_name, ''), 'Ospite') || coalesce(' - ' || nullif(p.camera, ''), ''),
         case when p.checkout <= oggi then 'fatta' else 'prevista' end,
         2000, p.id, 0, (p.checkout < inizio)
  from public.prenotazioni p
  where p.status <> 'cancellata' and p.checkout is not null and coalesce(p.source,'') <> 'educamp'
    and not exists (select 1 from public.pulizie x where x.prenotazione_id = p.id);
  get diagnostics n_pul = row_count;

  -- la prenotazione è la fonte: data, casa e descrizione della pulizia la seguono
  update public.pulizie x
  set data = p.checkout, casa = p.struttura,
      descrizione = coalesce(nullif(p.guest_name, ''), 'Ospite') || coalesce(' - ' || nullif(p.camera, ''), '')
  from public.prenotazioni p
  where x.prenotazione_id = p.id and x.modificata_a_mano is null
    and p.status <> 'cancellata' and p.checkout is not null and coalesce(p.source,'') <> 'educamp'
    and (x.data is distinct from p.checkout
         or x.casa is distinct from p.struttura
         or x.descrizione is distinct from
            coalesce(nullif(p.guest_name, ''), 'Ospite') || coalesce(' - ' || nullif(p.camera, ''), ''));
  get diagnostics n_pul_riall = row_count;

  update public.pulizie set stato = 'fatta' where stato is distinct from 'fatta' and data <= oggi;
  get diagnostics n_fatte = row_count;

  -- il check-out è stato spostato in avanti: la pulizia non è più stata fatta.
  -- Solo se non è ancora finita nei conti — quelle vecchie sono costi veri.
  update public.pulizie set stato = 'prevista'
   where stato = 'fatta' and data > oggi and contabilizzata = false;
  get diagnostics n_prev = row_count;

  insert into public.colazioni (ospite, camera, casa, arrivo, partenza, notti, persone,
                                costo_totale_cents, notti_servite, costo_servito_cents, stato,
                                prenotazione_id, sort_order, contabilizzata)
  select coalesce(nullif(p.guest_name, ''), 'Ospite'), p.camera, p.struttura, p.checkin, p.checkout,
         (p.checkout - p.checkin), greatest(1, coalesce(p.guests, 1)),
         (p.checkout - p.checkin) * greatest(1, coalesce(p.guests, 1)) * 350,
         0, 0, 'previste', p.id, 0, (p.checkout < inizio)
  from public.prenotazioni p
  where p.status <> 'cancellata' and p.source = 'booking'
    and p.checkin is not null and p.checkout > p.checkin
    and not exists (select 1 from public.colazioni c where c.prenotazione_id = p.id);
  get diagnostics n_col = row_count;

  -- stesso patto per le colazioni generate: date, ospite, camera e persone (e
  -- quindi il costo pieno) tornano quelli della prenotazione. Le colazioni delle
  -- dirette non le crea la sync: le mette qualcuno a mano, e restano sue.
  update public.colazioni c
  set ospite = coalesce(nullif(p.guest_name, ''), 'Ospite'), camera = p.camera, casa = p.struttura,
      arrivo = p.checkin, partenza = p.checkout, notti = (p.checkout - p.checkin),
      persone = greatest(1, coalesce(p.guests, 1)),
      costo_totale_cents = (p.checkout - p.checkin) * greatest(1, coalesce(p.guests, 1)) * 350
  from public.prenotazioni p
  where c.prenotazione_id = p.id and c.modificata_a_mano is null
    and p.status <> 'cancellata' and p.source = 'booking'
    and p.checkin is not null and p.checkout > p.checkin
    and (c.arrivo is distinct from p.checkin
         or c.partenza is distinct from p.checkout
         or c.persone is distinct from greatest(1, coalesce(p.guests, 1))
         or c.ospite is distinct from coalesce(nullif(p.guest_name, ''), 'Ospite')
         or c.camera is distinct from p.camera);
  get diagnostics n_col_riall = row_count;

  update public.colazioni c set casa = p.struttura
  from public.prenotazioni p where c.prenotazione_id = p.id and c.casa is distinct from p.struttura;

  update public.colazioni c
  set notti_servite = g.servite,
      costo_servito_cents = g.servite * greatest(1, coalesce(c.persone, 1)) * 350,
      stato = case when g.servite >= coalesce(c.notti, 0) then 'servite'
                   when g.servite > 0 then 'in corso' else 'previste' end
  from (select id, greatest(0, least(coalesce(partenza, arrivo), oggi) - arrivo) servite
        from public.colazioni where arrivo is not null) g
  where c.id = g.id
    and (c.notti_servite is distinct from g.servite
         or c.costo_servito_cents is distinct from g.servite * greatest(1, coalesce(c.persone, 1)) * 350);
  get diagnostics n_col_upd = row_count;

  -- incasso diretto: NON OTA e NON Educamp (il denaro Educamp è già in cassa)
  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key, prenotazione_id)
  select coalesce(p.checkin, p.checkout, oggi), p.struttura, 'entrata', 'affitto',
         coalesce(nullif(p.guest_name, ''), 'Diretto') || coalesce(' - ' || nullif(p.camera, ''), '')
           || ' (' || to_char(coalesce(p.checkin,p.checkout), 'DD/MM') || '-' || to_char(p.checkout, 'DD/MM') || ')',
         p.paid_cents, 'contante', coalesce(nullif(p.conto_id, ''), 'cassa'),
         'pren:' || p.id::text, p.id
  from public.prenotazioni p
  where p.status <> 'cancellata' and coalesce(p.source,'') not in ('booking','airbnb','educamp')
    and p.cassa_registrata = false and p.paid_cents > 0
  on conflict (ext_key) do nothing;
  get diagnostics n_cassa = row_count;

  -- incasso OTA: il portale incassa dall'ospite e gira i soldi sul conto del
  -- canale (Massimo). Importo lordo pagato: la commissione è un'uscita sua.
  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key, prenotazione_id)
  select coalesce(p.checkout, p.checkin, oggi), p.struttura, 'entrata', p.source,
         (case when p.source = 'airbnb' then 'Airbnb — ' else 'Booking — ' end)
           || coalesce(nullif(p.guest_name, ''), 'Ospite')
           || coalesce(' (' || nullif(p.camera, '') || ')', '')
           || ' ' || to_char(coalesce(p.checkin, p.checkout), 'DD/MM')
           || '-' || to_char(coalesce(p.checkout, p.checkin), 'DD/MM'),
         p.paid_cents, 'bonifico', coalesce(nullif(p.conto_id, ''), 'massimo'),
         'pren:' || p.id::text, p.id
  from public.prenotazioni p
  where p.status <> 'cancellata' and coalesce(p.source,'') in ('booking','airbnb')
    and p.cassa_registrata = false and p.paid_cents > 0
  on conflict (ext_key) do nothing;
  get diagnostics n_ota = row_count;

  update public.prenotazioni p set cassa_registrata = true
  where p.cassa_registrata = false
    and exists (select 1 from public.movimenti m where m.ext_key = 'pren:' || p.id::text);

  -- il pagato è cambiato nella prenotazione → il movimento generato la segue
  update public.movimenti m
  set importo_cents = p.paid_cents, updated_at = now()
  from public.prenotazioni p
  where m.ext_key = 'pren:' || p.id::text
    and p.status <> 'cancellata' and p.paid_cents > 0
    and m.importo_cents is distinct from p.paid_cents;
  get diagnostics n_riall = row_count;

  -- il pagato è tornato a zero → l'incasso generato non ha più ragione di stare
  -- nei conti (se poi rientra, la riga si ricrea da sola al prossimo giro)
  delete from public.movimenti m
  using public.prenotazioni p
  where m.ext_key = 'pren:' || p.id::text
    and p.status <> 'cancellata' and coalesce(p.paid_cents, 0) = 0;
  get diagnostics n_tolti = row_count;

  update public.prenotazioni p set cassa_registrata = false
  where p.cassa_registrata = true and coalesce(p.paid_cents, 0) = 0 and p.status <> 'cancellata'
    and not exists (select 1 from public.movimenti m where m.ext_key = 'pren:' || p.id::text);

  -- ── CARIFERMO ────────────────────────────────────────────────────────────
  -- a) la rata del mutuo di Via Po: 690 € il primo di ogni mese, da luglio 2026
  --    fino al mese in corso. Il mese nuovo compare da solo al primo giro utile.
  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key)
  select d::date, 'via-po', 'uscita', 'mutuo',
         'Rata mutuo Via Po — ' || to_char(d, 'MM/YYYY'),
         69000, 'addebito', 'carifermo', 'mutuo-vp:' || to_char(d, 'YYYY-MM')
  from generate_series(mutuo_da::timestamp, date_trunc('month', oggi::timestamp), interval '1 month') d
  on conflict (ext_key) do nothing;
  get diagnostics n_mutuo = row_count;

  -- b) le utenze di Via Po pagate da luglio 2026: escono da Carifermo
  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key)
  select b.scadenza, 'via-po', 'uscita', 'utenze',
         'Utenza ' || b.tipo || coalesce(' — ' || nullif(b.fornitore, ''), '')
           || coalesce(' (' || nullif(b.periodo, '') || ')', ''),
         b.importo_cents, 'addebito', 'carifermo', 'bolletta:' || b.id::text
  from public.bollette b
  where b.casa = 'via-po' and b.pagata and b.scadenza is not null and b.scadenza >= utenze_da
  on conflict (ext_key) do nothing;
  get diagnostics n_utenze = row_count;

  -- c) la bolletta è la fonte: importo, data e descrizione del movimento la seguono
  update public.movimenti m
  set importo_cents = b.importo_cents, data = b.scadenza,
      descrizione = 'Utenza ' || b.tipo || coalesce(' — ' || nullif(b.fornitore, ''), '')
                      || coalesce(' (' || nullif(b.periodo, '') || ')', ''),
      updated_at = now()
  from public.bollette b
  where m.ext_key = 'bolletta:' || b.id::text and b.pagata and b.scadenza is not null
    and (m.importo_cents is distinct from b.importo_cents or m.data is distinct from b.scadenza);

  -- d) bolletta segnata non pagata o cancellata → via anche l'uscita generata
  delete from public.movimenti m
  where m.ext_key like 'bolletta:%'
    and not exists (select 1 from public.bollette b
                    where m.ext_key = 'bolletta:' || b.id::text and b.pagata and b.scadenza >= utenze_da);

  -- ── USCITE DEI SERVIZI ───────────────────────────────────────────────────
  -- Prima di riaprirle: la riga di servizio non c'è più, o è tornata indietro
  -- (pulizia non più «fatta», colazioni non più «servite») → l'uscita se ne va e
  -- la riga torna da contabilizzare, così si rifarà quando sarà di nuovo il caso.
  -- Il taglio a `inizio` protegge l'archivio: prima del 23/07 le uscite stavano
  -- nell'Excel, non nei movimenti, e contabilizzata = true non va toccato.
  delete from public.movimenti m
  where m.ext_key like 'pulizia:%'
    and not exists (select 1 from public.pulizie pu
                    where m.ext_key = 'pulizia:' || pu.id::text and pu.stato = 'fatta');
  get diagnostics n_usc_tolte = row_count;

  update public.pulizie set contabilizzata = false
   where contabilizzata and stato <> 'fatta' and data >= inizio;

  delete from public.movimenti m
  where m.ext_key like 'colazione:%'
    and not exists (select 1 from public.colazioni cz
                    where m.ext_key = 'colazione:' || cz.id::text
                      and cz.stato = 'servite' and cz.costo_totale_cents > 0);
  get diagnostics n_tmp = row_count;
  n_usc_tolte := n_usc_tolte + n_tmp;

  update public.colazioni set contabilizzata = false
   where contabilizzata and stato <> 'servite' and coalesce(partenza, arrivo) >= inizio;

  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key)
  select pu.data, pu.casa, 'uscita', 'pulizia',
         'Pulizia e lavanderia — ' || coalesce(nullif(pu.descrizione,''),
              case pu.casa when 'via-po' then 'Via Po' when 'via-romagna' then 'Via Romagna' else 'PSE' end),
         pu.costo_cents, 'contante', 'cassa', 'pulizia:' || pu.id::text
  from public.pulizie pu
  where pu.stato = 'fatta' and pu.contabilizzata = false
  on conflict (ext_key) do nothing;
  get diagnostics n_usc_pul = row_count;
  update public.pulizie set contabilizzata = true where stato = 'fatta' and contabilizzata = false;

  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key)
  select coalesce(cz.partenza, cz.arrivo), coalesce(cz.casa, 'via-po'), 'uscita', 'colazioni',
         'Colazioni Booking — ' || coalesce(cz.ospite, 'ospite'),
         cz.costo_totale_cents, 'contante', 'cassa', 'colazione:' || cz.id::text
  from public.colazioni cz
  where cz.stato = 'servite' and cz.contabilizzata = false and cz.costo_totale_cents > 0
  on conflict (ext_key) do nothing;
  get diagnostics n_usc_col = row_count;
  update public.colazioni set contabilizzata = true where stato = 'servite' and contabilizzata = false;

  -- e) la riga di servizio è la fonte dell'uscita che ne è nata: se si è
  --    riallineata alla prenotazione, il movimento la segue (data, casa, importo).
  update public.movimenti m
  set data = pu.data, struttura = pu.casa, importo_cents = pu.costo_cents,
      descrizione = 'Pulizia e lavanderia — ' || coalesce(nullif(pu.descrizione,''),
              case pu.casa when 'via-po' then 'Via Po' when 'via-romagna' then 'Via Romagna' else 'PSE' end),
      updated_at = now()
  from public.pulizie pu
  where m.ext_key = 'pulizia:' || pu.id::text
    and (m.data is distinct from pu.data or m.struttura is distinct from pu.casa
         or m.importo_cents is distinct from pu.costo_cents);
  get diagnostics n_usc_riall = row_count;

  update public.movimenti m
  set data = coalesce(cz.partenza, cz.arrivo), struttura = coalesce(cz.casa, 'via-po'),
      importo_cents = cz.costo_totale_cents,
      descrizione = 'Colazioni Booking — ' || coalesce(cz.ospite, 'ospite'),
      updated_at = now()
  from public.colazioni cz
  where m.ext_key = 'colazione:' || cz.id::text
    and (m.data is distinct from coalesce(cz.partenza, cz.arrivo)
         or m.struttura is distinct from coalesce(cz.casa, 'via-po')
         or m.importo_cents is distinct from cz.costo_totale_cents);
  get diagnostics n_tmp = row_count;
  n_usc_riall := n_usc_riall + n_tmp;

  return jsonb_build_object('eseguito_il', oggi,
    'pulizie_create', n_pul, 'pulizie_fatte', n_fatte, 'colazioni_create', n_col,
    'colazioni_aggiornate', n_col_upd, 'entrate_in_cassa', n_cassa, 'entrate_ota', n_ota,
    'incassi_riallineati', n_riall, 'incassi_tolti', n_tolti,
    'rate_mutuo', n_mutuo, 'utenze_carifermo', n_utenze,
    'pulizie_riallineate', n_pul_riall, 'colazioni_riallineate', n_col_riall,
    'pulizie_tornate_previste', n_prev,
    'uscite_pulizia', n_usc_pul, 'uscite_colazioni', n_usc_col,
    'uscite_servizi_riallineate', n_usc_riall, 'uscite_servizi_ritirate', n_usc_tolte);
end;
$function$;

comment on function public.sync_camere_pse() is
  'Giro giornaliero Camere PSE: apre e riallinea pulizie/colazioni sulla prenotazione, porta incassi e uscite nei movimenti, rata mutuo e utenze di Via Po su Carifermo. Le righe con modificata_a_mano valorizzato non le tocca.';

select public.sync_camere_pse();
