-- Archivio contabile aprile 2024 – giugno 2026: solo tabelle storico_*.
-- Niente qui dentro sfiora prenotazioni, movimenti o conti della gestione viva.
--
-- Tre correzioni, tutte nate leggendo il libro riga per riga il 29/07/26.

-- ── 1. Le utenze intestate a Sara Paoletti sono di Via Po ──────────────────
-- Stavano su Via Romagna. Sara Paoletti è l'intestataria delle utenze di Via
-- Po — è la stessa persona della polizza AON, che dice «assicurazione Via Po».
alter table public.storico_movimenti add column if not exists note_correzione text;

update public.storico_movimenti
   set struttura = 'Via Po',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'struttura corretta 29/07/26: utenza intestata a Sara Paoletti = Via Po (era Via Romagna)'
 where descrizione ilike '%utenza Paoletti Sara%'
   and struttura is distinct from 'Via Po';

-- ── 2. Le spese di alloggio non avevano un «chi ha pagato» ─────────────────
-- Era una colonna di soli importi, così pulizie, colazioni e lavanderia
-- comparivano tutte come «Da chiarire» pur uscendo dal conto della società.
alter table public.storico_spese_alloggio add column if not exists pagato_da text;

update public.storico_spese_alloggio
   set pagato_da = 'Conto Proprieta'
 where struttura = 'Via Po' and pagato_da is null;

-- Le stesse voci, quando invece stanno fra i movimenti.
update public.storico_movimenti
   set pagato_da = 'Conto Proprieta'
 where tipo = 'uscita'
   and struttura = 'Via Po'
   and lower(coalesce(categoria,'')) in ('pulizie','limpieza','lavanderia','colazioni','colazione')
   and coalesce(pagato_da,'') in ('', 'Ver nota', 'Por identificar');

-- ── 3. La stessa bolletta contata due volte ────────────────────────────────
-- Arrivava sia dall'estratto conto Carifermo (l'addebito in banca) sia dalle
-- fatture caricate l'8/7/26. Tre importi identici: 217,13 · 578,61 · 453,65,
-- in tutto 1.249,39 €.
--
-- Le righe NON si cancellano: un archivio che perde righe non si può più
-- ricontrollare. Escono dai conti come già fanno le contropartite.
alter table public.storico_movimenti
  add column if not exists doppione boolean not null default false;

comment on column public.storico_movimenti.doppione is
  'La riga resta salvata ma sta fuori da elenchi e totali: è la stessa spesa già registrata da un''altra fonte.';

-- Si tiene la riga della fattura — ha la categoria giusta (il 453,65 è gas,
-- non luce, anche se in banca si legge «Enel») e la data della bolletta — e le
-- si dà il pagante che l'addebito in banca dimostra.
update public.storico_movimenti
   set pagato_da = 'Conto Proprieta',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'pagante preso dall''addebito Carifermo corrispondente (29/07/26)'
 where fonte = 'Facturas (8/7/26)' and struttura = 'Via Po'
   and importo_cents in (21713, 57861, 45365);

update public.storico_movimenti
   set doppione = true,
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'doppione 29/07/26: stessa bolletta già registrata dalle fatture (8/7/26)'
 where fonte = 'Estratto conto Carifermo' and struttura = 'Via Po'
   and lower(coalesce(categoria,'')) in ('luce','gas')
   and importo_cents in (21713, 57861, 45365);

-- ── Da decidere, non fatto ─────────────────────────────────────────────────
-- In settembre, ottobre e dicembre 2025 le stime «*mensual* (indicación
-- 9/7/26)» da 100 €/mese convivono con le righe vere delle pulizie e della
-- lavanderia: altri 400,00 € contati due volte. Negli altri mesi la stima è
-- l'unico dato e va tenuta. Serve una conferma prima di toglierle.
