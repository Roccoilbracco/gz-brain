-- ═══════════════════════════════════════════════════════════════════════════
-- Archivio contabile — sei righe di luglio che erano di Tesoreria
--
-- I due libri non si sommano mai: `storico_*` è l'archivio (apr 2024 – giu
-- 2026), le tabelle vive sono la contabilità che parte dal 01/07/2026. Ma sei
-- pagamenti erano stati scritti in tutti e due, e nell'archivio finivano nella
-- stagione «Ott 2025 – Giu 2026» perché la scheda calcolava la stagione dalla
-- sola data, senza nessun muro in fondo.
--
-- Nessun saldo era sbagliato — il saldo di Massimo lo fa solo il libro vivo,
-- dove ogni pagamento c'è una volta sola. Sbagliato era l'archivio: diceva che
-- in quel periodo erano usciti 1.164,82 € che sono usciti a luglio.
--
-- Le sei, tutte Via Po e tutte dal conto Massimo, con la riga viva che resta:
--   02/07   40,58 €  Unipol            → «ADDEBITO SDD Unipol Assicurazioni»
--   03/07    2,50 €  Nexi POS          → «ADDEBITO SDD NEXI Payments (canone POS)»
--   06/07   12,73 €  spese bancarie    → «Competenze, spese ed oneri (trimestre)»
--   13/07   49,47 €  Wind Tre          → «ADDEBITO SDD Wind Tre S.p.A.»
--   17/07  323,50 €  commissioni Booking di giugno, pagate a luglio
--                                      → «ADDEBITO SDD Booking.com B.V.»
--   21/07  736,04 €  F24               → «PAGAM. DELEGA F24 …» (con la nota su Gioia)
--
-- Le versioni vive sono più complete di quelle cancellate: non si perde niente.
-- Il muro perché non ricapiti sta in StoricoEdit.swift (`fineArchivio`): dal
-- 1º luglio 2026 in poi la scheda dell'archivio rifiuta la data.
-- ═══════════════════════════════════════════════════════════════════════════

delete from public.storico_movimenti where data >= '2026-07-01';

-- Dopo: ultima data dell'archivio 30/06/2026, 430 righe, saldo Massimo invariato.
