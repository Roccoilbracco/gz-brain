-- ============================================================================
-- Due cose in questa migrazione.
--
-- 1) OTTAVO CONTROLLO: gli automatismi che dicono di essere andati bene e non è vero.
--
--    I cron che chiamano una edge function con net.http_post risultano SEMPRE
--    'succeeded' in cron.job_run_details: la http_post è asincrona e ritorna
--    subito un id, molto prima che arrivi la risposta. Un job può quindi
--    fallire ogni notte per una settimana senza che nulla lo dica.
--
--    Trovato così: `nc-social-suggestions` rispondeva
--      HTTP 500 {"error":"ANTHROPIC_API_KEY secret is not set"}
--    con sette 'succeeded' consecutivi nei log del cron.
--
--    L'esito vero sta in net._http_response, ed è lì che va guardato.
--    Finestra 25 ore: la quadratura gira alle 03:40, il cron social alle 05:30,
--    quindi ogni esecuzione deve arrivare a coprire quella del giorno prima.
--
-- 2) L'ESTRATTO SI RAGGRUPPA PER `conto_id`, non per l'etichetta.
--
--    `storico_banca.conto` è il testo dell'import. Da
--    2026-08-05_estratto_conto_agganciato_al_conto esiste `conto_id`, stabile.
--    Se il prossimo import scrivesse «Carifermo 0120064/A» l'etichetta
--    cambierebbe, la catena dei saldi si spezzerebbe in due tronconi e il
--    controllo sparerebbe decine di falsi «catena interrotta».
--    Fallback sull'etichetta per eventuali righe non ancora agganciate.
-- ============================================================================

create or replace function public.quadratura_notturna()
returns integer
language plpgsql
as $$
declare n integer; ora timestamptz := now();
begin
  -- 1. ESTRATTO CONTO: catena dei saldi spezzata.
  -- Non si usa l'ordine delle righe: `id` è uuid casuale e `created_at` è
  -- identico su tutto l'import, quindi dentro la giornata un ordine non esiste.
  -- Ogni riga deve avere un'altra riga il cui saldo sia (saldo - importo).
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents, data_riferimento)
  select ora, 'estratto conto: catena interrotta', 'errore',
         b.conto,
         'Manca la riga che porta il saldo a ' || to_char((b.saldo_cents - b.importo_cents)/100.0,'FM999G999G990D00') ||
         ' EUR prima di: ' || left(coalesce(nullif(b.descrizione,''), b.causale, 'movimento senza descrizione'), 80),
         b.importo_cents, b.data
    from public.storico_banca b
   where b.saldo_cents is not null
     and b.saldo_cents - b.importo_cents <> 0
     and not exists (select 1 from public.storico_banca p
                      where coalesce(p.conto_id, p.conto) = coalesce(b.conto_id, b.conto)
                        and p.id <> b.id
                        and p.saldo_cents = b.saldo_cents - b.importo_cents);

  -- 2. ESTRATTO CONTO: righe senza saldo, quindi non verificabili.
  -- Oggi riguarda Massimo e Giacomo: le liste movimenti BPER non esportano
  -- il saldo progressivo. I totali si contano prima del join, altrimenti la
  -- sottoquery correlata leggerebbe una colonna fuori dal GROUP BY (42803).
  with per_conto as (
    select coalesce(conto_id, conto) as chiave,
           max(conto) as etichetta,
           count(*) as totale,
           count(*) filter (where saldo_cents is null) as senza_saldo
      from public.storico_banca
     group by coalesce(conto_id, conto)
  )
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents)
  select ora, 'estratto conto: saldo assente', 'attenzione', etichetta,
         senza_saldo || ' righe su ' || totale ||
         ' non hanno il saldo progressivo: su queste la quadratura non è calcolabile.', null
    from per_conto where senza_saldo > 0;

  -- 3. Righe di libro maestro con importo a zero: segnaposto da completare.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, data_riferimento)
  select ora, 'movimento senza importo', 'attenzione', coalesce(struttura,'-'),
         left(coalesce(descrizione,'(senza descrizione)'),100), data
    from public.storico_movimenti where importo_cents = 0
  union all
  select ora, 'movimento senza importo', 'attenzione', coalesce(struttura,'-'),
         left(coalesce(descrizione,'(senza descrizione)'),100), data
    from public.movimenti where importo_cents = 0;

  -- 4. Soggiorni finiti e non saldati.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents, data_riferimento)
  select ora, 'soggiorno finito non saldato', 'errore',
         coalesce(guest_name,'(senza nome)'),
         struttura || ' - ' || coalesce(camera,'?') || ', partito il ' || checkout ||
         ': incassati ' || to_char(paid_cents/100.0,'FM999G990D00') || ' su ' || to_char(amount_cents/100.0,'FM999G990D00') || ' EUR',
         amount_cents - paid_cents, checkout
    from public.prenotazioni
   where checkout < current_date and status <> 'cancellata' and paid_cents < amount_cents;

  -- 5. Soggiorni finiti mai passati in cassa.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents, data_riferimento)
  select ora, 'soggiorno finito non registrato in cassa', 'attenzione',
         coalesce(guest_name,'(senza nome)'),
         struttura || ' - ' || coalesce(camera,'?') || ', partito il ' || checkout || ', canale ' || coalesce(source,'?'),
         paid_cents, checkout
    from public.prenotazioni
   where checkout < current_date and status <> 'cancellata' and cassa_registrata is not true;

  -- 6. Doppioni, tenendo conto della partita doppia: in questo libro una spesa
  -- cash si scrive due volte, uscita + entrata di contropartita. Due righe
  -- identiche ma di tipo opposto sono la norma; il doppione vero è la stessa
  -- riga con stesso tipo E stessa contropartita.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents, data_riferimento)
  select ora, 'possibile doppione', 'attenzione', coalesce(struttura,'-'),
         count(*) || ' righe identiche (' || tipo || ', contropartita=' || coalesce(contropartita::text,'null') || '): ' ||
         left(coalesce(descrizione,'(senza descrizione)'),70),
         importo_cents, data
    from public.storico_movimenti
   where doppione is not true and importo_cents <> 0
   group by data, importo_cents, descrizione, struttura, tipo, contropartita
  having count(*) > 1;

  -- 7. Bollette non pagate.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents)
  select ora, 'bolletta non pagata', 'attenzione', coalesce(fornitore, '-'),
         'importo ' || to_char(importo_cents/100.0,'FM999G990D00') || ' EUR', importo_cents
    from public.bollette where pagata is not true;

  -- 8. Automatismi che dicono di essere andati bene ma non è vero.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio)
  select ora, 'automatismo fallito in silenzio', 'errore',
         'HTTP ' || r.status_code,
         'Una chiamata automatica ha risposto ' || r.status_code || ' il ' ||
         to_char(r.created, 'DD/MM alle HH24:MI') || ': ' ||
         left(coalesce(r.error_msg, r.content, '(nessun dettaglio)'), 120)
    from net._http_response r
   where r.created > ora - interval '25 hours'
     and (r.status_code is null or r.status_code >= 400);

  select count(*) into n from public.quadrature where eseguita_il = ora;
  return n;
end $$;

revoke all on function public.quadratura_notturna() from public, anon, authenticated;
