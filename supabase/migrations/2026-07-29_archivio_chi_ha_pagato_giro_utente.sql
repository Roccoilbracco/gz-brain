-- Archivio contabile aprile 2024 – giugno 2026: solo tabelle storico_*.
--
-- Chi ha pagato, detto dall'utente riga per riga il 29/07/26 guardando le
-- schede «A chi» dell'archivio. Prima erano tutte «Da chiarire», cioè scritte
-- da nessuna parte. Sono 45 righe.
create temporary table _q(quando date, come text, chi text) on commit drop;
insert into _q values
  ('2025-09-01','Ragazzi — mano de obra%','Giacomo'),
  ('2025-10-25','Boletín Domenico%','Giacomo'),
  ('2025-11-05','Material 2 baños%','Giacomo'),
  ('2025-12-15','Porta e montaggio%','Giacomo'),
  ('2026-04-08','6 puertas%','Giacomo'),
  ('2026-05-19','Falegname%','Giacomo'),
  ('2026-05-19','Quota ringhiera%','Giacomo'),
  ('2025-10-16','Edif (antes fin de mes)%','Giacomo'),
  ('2025-11-13','Color City (última factura)%','Giacomo'),
  ('2026-05-19','Color City','Giacomo'),
  ('2025-12-22','Domenico Romagnoli%','Giacomo'),
  ('2026-06-01','Stefano tuttofare%','Giacomo'),
  ('2026-06-11','Carpintero — cerradura 3 puertas%','Giacomo'),
  ('2026-03-16','Idroimpianti di Pistolesi Alessio%','Giorgio'),
  ('2025-06-27','Brico Io Civitanova%','Giorgio'),
  ('2025-06-27','Ferramenta Diomedi%','Giorgio'),
  ('2026-06-08','Edif — material marzo%','Giorgio'),
  ('2025-07-03','Leroy Merlin Ancona%','Giorgio'),
  ('2025-12-05','Leroy Merlin (PayPal)%','Giorgio'),
  ('2025-08-07','OBI Civitanova%','Giorgio'),
  ('2026-03-18','Fontanero%','Conto Proprieta'),
  ('2026-06-04','Fontanero%','Conto Proprieta'),
  ('2026-03-11','Paolo electricista%','Conto Proprieta'),
  ('2026-04-30','Elettricista — pago intermedio%','Conto Proprieta'),
  ('2026-06-30','Elettricista — debito vecchio%','Conto Proprieta'),
  ('2026-01-15','Obi — puerta%','Conto Proprieta'),
  ('2025-12-01','Muratore — cierre%','Conto Proprieta');

update public.storico_movimenti m
   set pagato_da = q.chi,
       note_correzione = coalesce(m.note_correzione || ' | ', '')
         || 'pagante detto dall''utente il 29/07/26 (era «da chiarire»)'
  from _q q
 where m.data = q.quando
   and m.descrizione ilike q.come
   and coalesce(m.pagato_da,'') in ('', 'Ver nota', 'Por identificar');

-- Le utenze di Via Po rimaste da chiarire — luce, gas, acqua, fibra — escono
-- tutte dal conto della società.
update public.storico_movimenti
   set pagato_da = 'Conto Proprieta',
       note_correzione = coalesce(note_correzione || ' | ', '')
         || 'utenze Via Po: conto società, detto dall''utente il 29/07/26'
 where tipo = 'uscita' and struttura = 'Via Po' and not doppione
   and lower(coalesce(categoria,'')) in ('luce','gas','acqua','internet')
   and coalesce(pagato_da,'') in ('', 'Ver nota', 'Por identificar');

-- ── Non toccato ────────────────────────────────────────────────────────────
-- Le quattro bollette Plenitude di Via Romagna (967,08 €) restano da chiarire:
-- l'indicazione diceva di che casa sono, non chi le ha pagate.
