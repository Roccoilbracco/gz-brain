-- ============================================================================
-- Le regole contabili scendono dal codice Swift al database, così valgono
-- anche per l'MCP, le edge function e l'SQL scritto a mano.
-- Ogni vincolo è stato verificato a vuoto sui dati esistenti: zero violazioni
-- al momento dell'applicazione.
--
-- NON inclusi di proposito:
--  · capacità/overbooking camere — fuori scope, il DB non modella i posti letto
--  · importo <> 0 su movimenti/storico_movimenti — esiste un segnaposto voluto
--    («Ingresso totale affitti Via Po CASH…», cifra da recuperare dal libro
--    maestro). Va nel report notturno, non in un vincolo che lo cancellerebbe.
--  · totale_ospite_cents e netto_noi_cents su educamp_righe — verificati: NON
--    seguono le formule che sembrano (23 righe su 23 le smentiscono).
-- ============================================================================

-- Affitti storici: il netto è sempre lordo meno commissione.
alter table public.storico_affitti
  add constraint storico_affitti_netto_coerente
    check (netto_cents = lordo_cents - commissione_cents),
  add constraint storico_affitti_importi_non_negativi
    check (lordo_cents >= 0 and commissione_cents >= 0);

-- Educamp: stessa regola sulla terna lordo/commissione/netto.
alter table public.educamp_righe
  add constraint educamp_righe_netto_coerente
    check (netto_cents = lordo_cents - commissione_cents),
  add constraint educamp_righe_importi_non_negativi
    check (lordo_cents >= 0 and commissione_cents >= 0);

-- Riepiloghi Booking: netto = lordo meno trattenute.
alter table public.storico_booking_riepiloghi
  add constraint booking_riepiloghi_netto_coerente
    check (netto_cents = lordo_cents - trattenute_cents),
  add constraint booking_riepiloghi_importi_non_negativi
    check (lordo_cents >= 0 and trattenute_cents >= 0);

-- Fatture: totale = imponibile + IVA. Nessuna fattura ancora emessa,
-- quindi il vincolo nasce insieme alla prima.
alter table public.fatture
  add constraint fatture_totale_coerente
    check (totale_cents = imponibile_cents + iva_cents),
  add constraint fatture_importi_non_negativi
    check (imponibile_cents >= 0 and iva_cents >= 0);

-- Prenotazioni: il checkout non può precedere il checkin.
-- L'uguaglianza resta ammessa: il day-use esiste ed è già in tabella.
alter table public.prenotazioni
  add constraint prenotazioni_date_coerenti
    check (checkout >= checkin),
  add constraint prenotazioni_importi_non_negativi
    check (amount_cents >= 0 and paid_cents >= 0);

-- Apporti soci e spese alloggio: una riga da zero euro è sempre un errore.
alter table public.storico_apporti_soci
  add constraint apporti_importo_non_nullo check (importo_cents <> 0);
alter table public.storico_spese_alloggio
  add constraint spese_alloggio_importo_non_nullo check (importo_cents <> 0);
