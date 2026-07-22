-- ============================================================================
-- Camere PSE — la casa sulle colazioni + depositi attribuiti a Via Romagna
--
-- 1. public.colazioni non sapeva a quale struttura appartenesse una riga, e
--    senza quel dato Servizi → Colazioni non si può dividere per casa.
-- 2. I dieci «Deposito inquilino» erano senza struttura: sono tutti di Via
--    Romagna (confermato dall'utente). Erano il grosso dei 2.686,49 € che la
--    ripartizione per casa mostrava come «non attribuito».
-- ============================================================================

alter table public.colazioni add column if not exists casa text;

update public.colazioni c set casa = p.struttura
from public.prenotazioni p
where c.prenotazione_id = p.id and c.casa is distinct from p.struttura;

-- Le colazioni importate dall'Excel non hanno l'aggancio alla prenotazione, ma
-- sono tutte Booking di Via Po: Via Romagna non ha canali OTA.
update public.colazioni set casa = 'via-po' where casa is null;

update public.movimenti
set struttura = 'via-romagna', updated_at = now()
where struttura is null and categoria = 'deposito';

-- Dopo questa assegnazione restano «non attribuiti» solo 536,27 €: rata del
-- prestito, spese bancarie e il bonifico dell'asta, che sono davvero comuni.

-- La funzione giornaliera ora tiene aggiornata anche la casa delle colazioni:
-- vedi 2026-07-22_bollette_e_sync_giornaliero.sql per il resto del corpo.
-- (sync_camere_pse ridefinita con l'insert di colazioni che valorizza `casa` e
--  un update che la riallinea se la prenotazione viene corretta.)
