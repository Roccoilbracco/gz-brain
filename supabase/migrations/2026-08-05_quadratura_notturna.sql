-- ============================================================================
-- Quadratura notturna: il database si controlla da solo e lascia scritto cosa
-- non torna. Non blocca niente, segnala. I vincoli (vedi
-- 2026-08-05_vincoli_contabili.sql) impediscono gli stati impossibili;
-- questo trova gli stati sospetti.
--
-- Il controllo sull'estratto conto NON usa l'ordine delle righe: `id` è un uuid
-- casuale e `created_at` è identico su tutto l'import, quindi dentro la stessa
-- giornata non esiste un ordine ricostruibile. Usa invece la catena dei saldi:
-- ogni riga deve avere un'altra riga il cui saldo sia (saldo - importo).
-- 212 righe su 215 del conto Carifermo la rispettano; le rotture sono i buchi veri.
-- ============================================================================

create table if not exists public.quadrature (
  id               uuid primary key default gen_random_uuid(),
  eseguita_il      timestamptz not null default now(),
  controllo        text not null,
  gravita          text not null check (gravita in ('errore','attenzione','info')),
  oggetto          text,
  dettaglio        text,
  importo_cents    integer,
  data_riferimento date
);
alter table public.quadrature enable row level security;
create index if not exists quadrature_eseguita_idx on public.quadrature (eseguita_il desc);
create index if not exists quadrature_gravita_idx  on public.quadrature (gravita, eseguita_il desc);

comment on table public.quadrature is
  'Esiti della quadratura notturna (cron quadratura-notturna, 03:40). Una riga per anomalia. L''ultima esecuzione è max(eseguita_il).';

create or replace function public.quadratura_notturna()
returns integer
language plpgsql
as $$
declare n integer; ora timestamptz := now();
begin
  -- 1. ESTRATTO CONTO: catena dei saldi spezzata.
  -- Se manca l'anello precedente, alla banca risulta un movimento che nel
  -- libro non c'è. L'apertura del conto (predecessore = 0) non è una rottura.
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
                      where p.conto = b.conto and p.id <> b.id
                        and p.saldo_cents = b.saldo_cents - b.importo_cents);

  -- 2. ESTRATTO CONTO: righe senza saldo, quindi non verificabili.
  -- Oggi riguarda i conti Massimo e Giacomo: l'import non prendeva il saldo.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, importo_cents)
  select ora, 'estratto conto: saldo assente', 'attenzione', conto,
         count(*) || ' righe su ' || (select count(*) from public.storico_banca s where s.conto = b.conto) ||
         ' non hanno il saldo progressivo: su queste la quadratura non è calcolabile.', null
    from public.storico_banca b where saldo_cents is null group by conto;

  -- 3. Righe di libro maestro con importo a zero: segnaposto da completare.
  insert into public.quadrature (eseguita_il, controllo, gravita, oggetto, dettaglio, data_riferimento)
  select ora, 'movimento senza importo', 'attenzione', coalesce(struttura,'-'),
         left(coalesce(descrizione,'(senza descrizione)'),100), data
    from public.storico_movimenti where importo_cents = 0
  union all
  select ora, 'movimento senza importo', 'attenzione', coalesce(struttura,'-'),
         left(coalesce(descrizione,'(senza descrizione)'),100), data
    from public.movimenti where importo_cents = 0;

  -- 4. Soggiorni finiti e non saldati: soldi che dovrebbero essere entrati.
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

  -- 6. Doppioni. Il controllo conosce la partita doppia: in questo libro una
  -- spesa in contanti si scrive due volte, come uscita e come entrata di
  -- contropartita. Due righe identiche ma di tipo opposto sono la norma.
  -- Il doppione vero è la stessa riga con stesso tipo E stessa contropartita.
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

  select count(*) into n from public.quadrature where eseguita_il = ora;
  return n;
end $$;

revoke all on function public.quadratura_notturna() from public, anon, authenticated;

select cron.schedule('quadratura-notturna', '40 3 * * *', $c$select public.quadratura_notturna();$c$);
