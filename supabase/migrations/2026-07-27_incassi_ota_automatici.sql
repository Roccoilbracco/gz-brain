-- ═══════════════════════════════════════════════════════════════════════════
-- Camere PSE — gli incassi delle OTA entrano da soli in Tesoreria
--
-- Fino a oggi sync_camere_pse() creava il movimento d'incasso solo per le
-- prenotazioni dirette: quelle Booking e Airbnb erano escluse, perché i loro
-- incassi di luglio erano arrivati dall'import dell'Excel (ext_key xls35/xls38).
-- Risultato: una prenotazione OTA nuova o modificata non compariva mai nei
-- fogli — è il caso di Pier Bordoni (Airbnb, 148,00 € pagati) e di Michele Del
-- Pozzo (Booking, 446,00 €).
--
-- Da qui in avanti:
--   • ogni prenotazione OTA pagata scrive la sua entrata sul conto del canale
--     (Massimo), categoria «airbnb»/«booking», con l'importo LORDO pagato
--     dall'ospite — la commissione resta un'uscita a parte, come nei fogli;
--   • se cambi il pagato nella prenotazione, il movimento generato si
--     riallinea (e sparisce se il pagato torna a zero). Vale anche per i
--     diretti: la prenotazione è la fonte, il movimento la segue.
--     I movimenti scritti a mano in Tesoreria non hanno ext_key «pren:» e
--     quindi non vengono toccati.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.sync_camere_pse()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  n_pul int := 0; n_fatte int := 0; n_col int := 0; n_col_upd int := 0; n_cassa int := 0;
  n_usc_pul int := 0; n_usc_col int := 0; n_ota int := 0; n_riall int := 0; n_tolti int := 0;
  inizio date := '2026-07-23';
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

  update public.pulizie set stato = 'fatta' where stato is distinct from 'fatta' and data <= oggi;
  get diagnostics n_fatte = row_count;

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
  -- canale (Massimo). Importo lordo pagato: la commissione è un'uscita sua,
  -- così l'estratto del conto resta leggibile come nei fogli di luglio.
  -- La data è il check-out, come gli incassi Booking importati dall'Excel.
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

  return jsonb_build_object('eseguito_il', oggi,
    'pulizie_create', n_pul, 'pulizie_fatte', n_fatte, 'colazioni_create', n_col,
    'colazioni_aggiornate', n_col_upd, 'entrate_in_cassa', n_cassa, 'entrate_ota', n_ota,
    'incassi_riallineati', n_riall, 'incassi_tolti', n_tolti,
    'uscite_pulizia', n_usc_pul, 'uscite_colazioni', n_usc_col);
end;
$function$;

-- ── Recupero delle due prenotazioni OTA rimaste fuori dai fogli ─────────────
-- Erano marcate «già registrate» dall'allineamento del 22/07 (che dava per
-- scontato che ogni incasso OTA fosse nell'Excel), ma un movimento non ce
-- l'hanno: si sbloccano e la sync qui sopra scrive le due entrate. L'ext_key
-- «pren:<id>» impedisce i doppioni se questa migrazione venisse rieseguita.
update public.prenotazioni p
set cassa_registrata = false
where coalesce(p.source,'') in ('booking','airbnb')
  and p.status <> 'cancellata'
  and p.paid_cents > 0
  and p.ext_id in ('beds24:90334508', 'beds24:90005332')   -- Pier Bordoni, Michele Del Pozzo
  and not exists (select 1 from public.movimenti m where m.prenotazione_id = p.id and m.tipo = 'entrata');

select public.sync_camere_pse();
