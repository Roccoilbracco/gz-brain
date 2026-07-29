-- Archivio contabile aprile 2024 – giugno 2026: solo tabelle storico_*.
-- Ultimo giro di «chi ha pagato», detto dall'utente il 29/07/26.

-- 1. Le quattro bollette Plenitude di Via Romagna: conto della società.
update public.storico_movimenti
   set pagato_da = 'Conto Proprieta',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'pagante detto dall''utente il 29/07/26: conto società di Via Romagna'
 where struttura = 'Via Romagna' and descrizione ilike '%Plenitude%'
   and coalesce(pagato_da,'') in ('', 'Ver nota', 'Por identificar');

-- 2. Le compre fatte con la carta di Giorgio, più Amazon e le tasse.
update public.storico_movimenti
   set pagato_da = 'Giorgio',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'pagante detto dall''utente il 29/07/26'
 where tipo = 'uscita' and coalesce(pagato_da,'') in ('', 'Ver nota', 'Por identificar')
   and (descrizione ilike 'Amazon Italia%' or descrizione ilike 'Tasse Via Romagna%'
        or descrizione ilike 'Ancona HFB%' or descrizione ilike 'Comet Spa%'
        or descrizione ilike 'Edilcasa Caccamo%' or descrizione ilike 'Ferramenta Braccialarg%');

-- 3. Le righe rimaste mute: conto della società.
update public.storico_movimenti
   set pagato_da = 'Conto Proprieta',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'pagante detto dall''utente il 29/07/26: conto società'
 where tipo = 'uscita' and coalesce(pagato_da,'') in ('', 'Ver nota', 'Por identificar')
   and (descrizione ilike 'Kurti Refik%' or descrizione ilike 'Maroni%'
        or descrizione ilike 'Cerradura ventana%' or descrizione ilike 'Timi —%'
        or descrizione ilike 'Geberit%' or descrizione ilike 'Tennacola%'
        or descrizione ilike 'Limpiezas (Maria/Valentina)%' or descrizione ilike 'Spesa muratori%'
        or descrizione ilike 'Comisiones bancarias%');

-- Maroni e le pulizie di Maria/Valentina sono di Via Po, non di Via Romagna.
update public.storico_movimenti
   set struttura = 'Via Po',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'casa corretta dall''utente il 29/07/26: è Via Po'
 where (descrizione ilike 'Maroni%' or descrizione ilike 'Limpiezas (Maria/Valentina)%')
   and struttura is distinct from 'Via Po';

-- 4. La compra di Via Romagna, divisa fra i due soci.
-- Era una riga sola da 95.734 € con pagante «Ver nota». I due apporti che la
-- coprono stanno già dentro come contropartite, uno per socio: 51.300 di
-- Giorgio e 44.434 di Giacomo, che fanno esattamente 95.734. La riga si
-- spacca in due come tutte le altre spese divise fra i soci, se no «chi ha
-- pagato» non può dire niente. Il totale non cambia.
insert into public.storico_movimenti
  (periodo, data, struttura, tipo, categoria, descrizione, importo_cents,
   pagato_da, fonte, verificato, note, note_correzione)
select periodo, data, struttura, tipo, categoria,
       'COMPRA INMUEBLE VIA ROMAGNA — saldo al rogito (quota Giacomo)',
       4443400, 'Giacomo', fonte, verificato, note,
       'riga creata il 29/07/26 spaccando la compra da 95.734 € nelle due quote dei soci (51.300 Giorgio + 44.434 Giacomo), come detto dall''utente. Il totale non cambia.'
  from public.storico_movimenti
 where descrizione = 'COMPRA INMUEBLE VIA ROMAGNA — saldo al rogito (51.300 Giorgio + 44.434 Giacomo)';

update public.storico_movimenti
   set descrizione = 'COMPRA INMUEBLE VIA ROMAGNA — saldo al rogito (quota Giorgio)',
       importo_cents = 5130000,
       pagato_da = 'Giorgio',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'spaccata il 29/07/26 nelle due quote dei soci: qui restano i 51.300 € di Giorgio, i 44.434 € di Giacomo sono nella riga gemella. Il totale non cambia.'
 where descrizione = 'COMPRA INMUEBLE VIA ROMAGNA — saldo al rogito (51.300 Giorgio + 44.434 Giacomo)';

-- Resta da chiarire una riga sola: «Pulizie (pack de mayo, financiado con los
-- 800 € de Giorgio)», 100 €. Le altre due del pacchetto di maggio — falegname
-- e quota ringhiera — le ha pagate Giacomo, ma questa non è stata detta.
