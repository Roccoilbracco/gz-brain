-- Archivio contabile aprile 2024 – giugno 2026: solo tabelle storico_*.
--
-- Brico Io Civitanova, 31,55 €, dentro due volte: una dal libro maestro
-- (02/07/25, «Doc. oficial», verificata, Via Romagna) e una dall'estratto
-- bancario di Giorgio (27/06/25, «Relazione PDF 6/7/26», non verificata,
-- casa generica «Mixto»). È la stessa compra arrivata da due parti.
-- Si tiene quella del libro maestro. Il sospetto era già scritto nella nota
-- della riga: «⚠ Posible solape parcial… VERIFICAR».
update public.storico_movimenti
   set doppione = true,
       note = regexp_replace(coalesce(note,''), '\s*⚠ Posible solape.*?VERIFICAR\.', '', 'g'),
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'doppione 29/07/26: stessa compra della riga del 02/07/25 «BRICOIO CIVITANOVA 31.55€», che viene dal libro maestro ed è verificata.'
 where data = '2025-06-27' and importo_cents = 3155
   and descrizione ilike 'Brico Io Civitanova%';
