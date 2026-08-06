-- ============================================================================
-- Via l'ultima traccia di Beds24 nello schema.
--
-- `beds24_block_id` teneva gli id dei blocchi «black» che `beds24-push` creava
-- sul channel manager per le prenotazioni che Beds24 non conosceva. Con
-- l'integrazione dismessa quei blocchi non esistono piu' da nessuna parte: la
-- colonna puntava a righe su un account cancellato.
--
-- Una riga sola era valorizzata (Livia Gabbianelli, 21-23/08/2026, blocchi
-- 90365439 e 90365440 sulle due camere gemelle). Sta scritto qui perche' e'
-- l'unico posto dove quel dato sopravvive dopo il drop.
--
-- Nessuna funzione, vista o riga di codice leggeva la colonna: verificato su
-- pg_proc, pg_class e i due repo prima di eseguire.
-- ============================================================================

alter table public.prenotazioni drop column if exists beds24_block_id;
