-- Archivio contabile aprile 2024 – giugno 2026: solo tabelle storico_*.
--
-- L'ultima riga rimasta senza pagante. La descrizione la metteva dentro al
-- «pack de mayo» finanziato con gli 800 € in contanti di Giorgio, ma l'utente
-- il 29/07/26 ha detto che le pulizie in quel pacchetto non ci sono: la
-- dicitura se ne va, e come tutte le pulizie escono dal conto della società.
update public.storico_movimenti
   set descrizione = 'Pulizie (maggio)',
       pagato_da = 'Conto Proprieta',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'detto dall''utente il 29/07/26: queste pulizie NON fanno parte del pack de mayo — tolta la dicitura — e come tutte le pulizie escono dal conto della società'
 where descrizione ilike 'Pulizie (pack de mayo%';
