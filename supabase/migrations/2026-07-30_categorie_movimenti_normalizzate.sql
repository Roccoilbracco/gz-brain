-- ═══════════════════════════════════════════════════════════════════════════
-- Camere PSE — la categoria di un movimento è una parola, non una frase
--
-- `movimenti.categoria` è testo libero, e il Conto economico raggruppa per
-- quella stringa esatta. Ogni variante di maiuscole, ogni spazio in coda, ogni
-- commento infilato nella categoria diventa una riga a sé nel prospetto: si
-- leggeva «Affitto 120 €» sotto «affitto 4.805 €» come se fossero due voci
-- diverse, e la rata del mutuo compariva tre volte con tre nomi.
--
-- Le classificazioni del codice (isDebito, isPartitaDiGiro, isCauzione…)
-- lavorano già in minuscolo e per sottostringa, quindi non si rompono: quello
-- che si rompeva era solo il raggruppamento, cioè il numero che si legge.
--
-- Qui si fa tre cose: si rimettono a posto le cinque righe divergenti, si
-- normalizza tutto (minuscolo, senza spazi in coda) e si mette un trigger
-- perché la prossima riga nasca già pulita — da qualunque parte arrivi, app,
-- connettore MCP o SQL a mano.
--
-- Il prefisso `giro:` resta: non è sporcizia, è la convenzione che tiene le
-- partite di giro fuori dal conto economico (vedi isPartitaDiGiro). Il testo
-- dopo i due punti si abbassa di caso e basta.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Le righe che portavano informazione nella categoria ──────────────────
-- Quello che stava scritto lì non si butta: si sposta nella descrizione, che è
-- il posto dove uno lo cerca.

-- Genni, Stanza 3: la categoria conteneva il totale e l'acconto.
update public.movimenti
   set categoria = 'affitto',
       descrizione = 'Stanza 3 (King) — Genni 26/07–03/08 (560 € totali, 100 € di acconto con bonifico)'
 where categoria = 'affitto (560€) DATI 100€ DI ACCONTO CON BONIFICO';

-- Le due rate del mutuo di Via Romagna su Beeper: 15/06 e 15/07, importi
-- diversi di 18 centesimi (tasso variabile). Non sono un doppione — Beeper non
-- ha saldo iniziale al 01/07, il suo saldo si costruisce da giugno, quindi la
-- rata di giugno non è già dentro a nessun'altra riga.
-- La prima era segnata «RATA MUTUO LUGLIO» ma è pagata il 15/06: il mese
-- scritto non torna con la data. Si tiene la data, che è un fatto, e si dice
-- nella descrizione com'era etichettata — non si indovina il mese giusto.
update public.movimenti
   set categoria = 'mutuo',
       descrizione = 'Rata mutuo Via Romagna — pagata il 15/06 (era segnata «RATA MUTO LUGLIO»: il mese va confermato)'
 where categoria = 'RATA MUTUO LUGLIO';

update public.movimenti
   set categoria = 'mutuo',
       descrizione = coalesce(descrizione, 'Rata mutuo Via Romagna — pagata il 15/07')
 where categoria = 'Mutuo via Romagna Luglio';

-- ── 2. Tutto il resto: minuscolo, senza spazi in coda ───────────────────────
-- Prende «Manutenzione » (con lo spazio) e i due «giro:» con le maiuscole.
update public.movimenti
   set categoria = nullif(btrim(lower(categoria)), '')
 where categoria is distinct from nullif(btrim(lower(categoria)), '');

-- ── 3. Che non ricapiti ─────────────────────────────────────────────────────
-- Un vincolo con l'elenco chiuso delle categorie sarebbe più severo, ma
-- sbagliato: «giro: storno commissioni luglio» è legittima e non si può
-- prevedere. Qui basta togliere di mezzo le differenze che non significano
-- niente — maiuscole e spazi — e lasciare libera la parola.
create or replace function public.movimenti_normalizza_categoria()
returns trigger
language plpgsql
as $function$
begin
  new.categoria := nullif(btrim(lower(new.categoria)), '');
  return new;
end;
$function$;

comment on function public.movimenti_normalizza_categoria() is
  'La categoria di un movimento arriva sempre in minuscolo e senza spazi ai bordi: il Conto economico raggruppa per quella stringa, e «Affitto» non deve diventare una voce diversa da «affitto».';

drop trigger if exists movimenti_categoria_normalizzata on public.movimenti;
create trigger movimenti_categoria_normalizzata
  before insert or update of categoria on public.movimenti
  for each row execute function public.movimenti_normalizza_categoria();

comment on column public.movimenti.categoria is
  'Una parola, non una frase: il Conto economico raggruppa per questa stringa. Minuscolo e senza spazi ai bordi lo garantisce un trigger. Le partite di giro usano il prefisso «giro:». Il dettaglio va nella descrizione.';
