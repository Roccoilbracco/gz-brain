-- ============================================================================
-- Camere PSE — bollette (utenze che paghiamo) + sincronizzazione giornaliera
--
-- 1. public.bollette: luce, gas, acqua, internet, immondizia, IMU, varie.
--    Sta fuori da public.movimenti apposta: queste bollette si pagano da un
--    conto bancario che non è né Cassa né Massimo né Beeper, e metterle lì
--    sfalserebbe i saldi (che oggi quadrano al centesimo con l'Excel).
-- 2. Collegamento pulizie/colazioni/movimenti ↔ prenotazioni, così le righe
--    smettono di vivere separate dai soggiorni che le generano.
-- 3. sync_camere_pse(): job giornaliero che apre le pulizie ai check-out,
--    aggiorna le colazioni servite e registra in Cassa gli incassi diretti
--    quando l'ospite parte.
-- ============================================================================

-- ── 1. BOLLETTE ─────────────────────────────────────────────────────────────
create table if not exists public.bollette (
  id            uuid primary key default gen_random_uuid(),
  casa          text not null,               -- via-po | via-romagna | comune
  tipo          text not null,               -- luce | gas | acqua | internet | immondizia | imu | varie
  fornitore     text,
  scadenza      date,
  periodo       text,                        -- periodo coperto, come sta in bolletta
  importo_cents integer not null,
  pagata        boolean not null default true,
  note          text,
  ext_key       text unique,                 -- chiave d'import, evita i doppioni
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists bollette_casa_tipo_idx on public.bollette (casa, tipo, scadenza);
alter table public.bollette enable row level security;

-- Bollette reali dal foglio «Suministros (detalle)» del maestro.
insert into public.bollette (casa, tipo, fornitore, scadenza, periodo, importo_cents, ext_key) values
  ('via-po','luce','Enel','2025-09-23',null,24567,'mst:vp:luce:1'),
  ('via-po','luce','Enel','2025-11-26',null,21713,'mst:vp:luce:2'),
  ('via-po','luce','Enel','2026-01-27',null,53332,'mst:vp:luce:3'),
  ('via-po','luce','Enel','2026-03-24',null,57861,'mst:vp:luce:4'),
  ('via-po','luce','Enel','2026-05-27',null,45048,'mst:vp:luce:5'),
  ('via-po','luce','Enel','2026-06-23',null,11215,'mst:vp:luce:6'),
  ('via-po','luce','Enel','2026-07-08','Conguaglio estratto conto',433,'mst:vp:luce:adj'),
  ('via-po','gas','Enel','2025-10-29','Fornitura Via Monte Catria 1',9394,'mst:vp:gas:1'),
  ('via-po','gas','Enel','2025-12-29','Fornitura Via Monte Catria 1',13418,'mst:vp:gas:2'),
  ('via-po','gas','Enel','2026-03-16','Fornitura Via Monte Catria 1',64663,'mst:vp:gas:3'),
  ('via-po','gas','Enel','2026-04-28','Fornitura Via Monte Catria 1',45365,'mst:vp:gas:4'),
  ('via-po','internet','Enel fibra','2025-09-29','Via Po 13',1990,'mst:vp:fib:1'),
  ('via-po','internet','Enel fibra','2025-10-28','Via Po 13',1990,'mst:vp:fib:2'),
  ('via-po','internet','Enel fibra','2025-11-28','Via Po 13',1990,'mst:vp:fib:3'),
  ('via-po','internet','Enel fibra','2025-12-29','Via Po 13',1990,'mst:vp:fib:4'),
  ('via-po','internet','Enel fibra','2026-02-02','Via Po 13',1990,'mst:vp:fib:5'),
  ('via-po','internet','Enel fibra','2026-03-02','Via Po 13',1990,'mst:vp:fib:6'),
  ('via-po','internet','Enel fibra','2026-03-30','Via Po 13',1990,'mst:vp:fib:7'),
  ('via-po','internet','Enel fibra','2026-04-28','Via Po 13',1990,'mst:vp:fib:8'),
  ('via-po','internet','Enel fibra','2026-05-28','Via Po 13',1990,'mst:vp:fib:9'),
  ('via-po','internet','Enel fibra','2026-06-29','Via Po 13',1990,'mst:vp:fib:10'),
  ('via-romagna','luce','Plenitude','2025-11-28','01/09 → 02/11/25',11611,'mst:vr:luce:1'),
  ('via-romagna','luce','Plenitude','2026-02-06','03/11 → 31/12/25',32230,'mst:vr:luce:2'),
  ('via-romagna','luce','Plenitude','2026-03-31','01/01 → 28/02/26',32605,'mst:vr:luce:3'),
  ('via-romagna','luce','Plenitude','2026-06-03','01/03 → 30/04/26',20262,'mst:vr:luce:4')
on conflict (ext_key) do nothing;

-- Nota: la rettifica di −105,00 € di Via Romagna del foglio è un allineamento
-- all'estratto conto (luce non ancora addebitata), non una bolletta: resta fuori.

-- ── 2. COLLEGAMENTI ─────────────────────────────────────────────────────────
alter table public.prenotazioni add column if not exists cassa_registrata boolean not null default false;
comment on column public.prenotazioni.cassa_registrata is
  'true quando l''incasso è già in public.movimenti: impedisce al job giornaliero di ricrearlo.';

alter table public.movimenti  add column if not exists prenotazione_id uuid references public.prenotazioni(id) on delete set null;
alter table public.pulizie    add column if not exists prenotazione_id uuid references public.prenotazioni(id) on delete cascade;
alter table public.colazioni  add column if not exists prenotazione_id uuid references public.prenotazioni(id) on delete cascade;
create unique index if not exists pulizie_pren_uidx   on public.pulizie   (prenotazione_id) where prenotazione_id is not null;
create unique index if not exists colazioni_pren_uidx on public.colazioni (prenotazione_id) where prenotazione_id is not null;

-- Le pulizie importate dall'Excel si appaiano ai check-out per (casa, data);
-- quando nello stesso giorno e nella stessa casa ce n'è più d'una si accoppiano
-- in ordine, così l'abbinamento è deterministico.
with p as (
  select id, struttura, checkout,
         row_number() over (partition by struttura, checkout order by coalesce(camera,''), id) rn
  from public.prenotazioni where status <> 'cancellata' and checkout is not null
), x as (
  select id, casa, data,
         row_number() over (partition by casa, data order by coalesce(sort_order,0), id) rn
  from public.pulizie where prenotazione_id is null
)
update public.pulizie s set prenotazione_id = p.id
from x join p on p.struttura = x.casa and p.checkout = x.data and p.rn = x.rn
where s.id = x.id;

with p as (
  select id, checkin, checkout,
         row_number() over (partition by checkin, checkout order by id) rn
  from public.prenotazioni where status <> 'cancellata' and source = 'booking'
), x as (
  select id, arrivo, partenza,
         row_number() over (partition by arrivo, partenza order by coalesce(sort_order,0), id) rn
  from public.colazioni where prenotazione_id is null
)
update public.colazioni c set prenotazione_id = p.id
from x join p on p.checkin = x.arrivo and p.checkout = x.partenza and p.rn = x.rn
where c.id = x.id;

-- Gli incassi contante di tutte le prenotazioni dirette già esistenti sono nei
-- movimenti importati dall'Excel (ext_key xls35:cassa:*). Vanno marcati come
-- registrati in blocco: appaiarli uno a uno per importo e data non è
-- affidabile (due incassi da 70 € lo stesso giorno combaciano con due
-- prenotazioni diverse, e la mansarda di luglio è ambigua).
update public.prenotazioni
set cassa_registrata = true
where source not in ('booking','airbnb') and cassa_registrata = false;

-- Anche le OTA: i loro incassi vivono sul conto Massimo, non in Cassa.
update public.prenotazioni set cassa_registrata = true where source in ('booking','airbnb');

-- ── 3. SINCRONIZZAZIONE GIORNALIERA ─────────────────────────────────────────
create or replace function public.sync_camere_pse()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n_pul int := 0; n_fatte int := 0; n_col int := 0; n_col_upd int := 0; n_cassa int := 0;
  oggi date := current_date;
begin
  -- a) una pulizia per ogni check-out che non ce l'ha ancora (20 € a camera)
  insert into public.pulizie (data, casa, descrizione, stato, costo_cents, prenotazione_id, sort_order)
  select p.checkout, p.struttura,
         coalesce(nullif(p.guest_name, ''), 'Ospite') || coalesce(' — ' || nullif(p.camera, ''), ''),
         case when p.checkout <= oggi then 'fatta' else 'prevista' end,
         2000, p.id, 0
  from public.prenotazioni p
  where p.status <> 'cancellata' and p.checkout is not null
    and not exists (select 1 from public.pulizie x where x.prenotazione_id = p.id);
  get diagnostics n_pul = row_count;

  -- b) il check-out è passato → la pulizia è fatta
  update public.pulizie set stato = 'fatta'
  where stato is distinct from 'fatta' and data <= oggi;
  get diagnostics n_fatte = row_count;

  -- c) colazioni Booking: 3,50 € a persona per notte, una riga per soggiorno
  insert into public.colazioni (ospite, camera, arrivo, partenza, notti, persone,
                                costo_totale_cents, notti_servite, costo_servito_cents, stato,
                                prenotazione_id, sort_order)
  select coalesce(nullif(p.guest_name, ''), 'Ospite'), p.camera, p.checkin, p.checkout,
         (p.checkout - p.checkin), greatest(1, coalesce(p.guests, 1)),
         (p.checkout - p.checkin) * greatest(1, coalesce(p.guests, 1)) * 350,
         0, 0, 'previste', p.id, 0
  from public.prenotazioni p
  where p.status <> 'cancellata' and p.source = 'booking'
    and p.checkin is not null and p.checkout > p.checkin
    and not exists (select 1 from public.colazioni c where c.prenotazione_id = p.id);
  get diagnostics n_col = row_count;

  -- d) ricalcolo di quante colazioni sono state davvero servite a oggi
  update public.colazioni c
  set notti_servite      = g.servite,
      costo_servito_cents = g.servite * greatest(1, coalesce(c.persone, 1)) * 350,
      stato              = case when g.servite >= coalesce(c.notti, 0) then 'servite'
                                when g.servite > 0 then 'in corso' else 'previste' end
  from (
    select id, greatest(0, least(coalesce(partenza, arrivo), oggi) - arrivo) servite
    from public.colazioni where arrivo is not null
  ) g
  where c.id = g.id
    and (c.notti_servite is distinct from g.servite
         or c.costo_servito_cents is distinct from g.servite * greatest(1, coalesce(c.persone, 1)) * 350);
  get diagnostics n_col_upd = row_count;

  -- e) l'ospite diretto è partito e aveva pagato → l'incasso entra in Cassa.
  --    ext_key deterministica + cassa_registrata: due lucchetti contro i doppioni.
  insert into public.movimenti (data, struttura, tipo, categoria, descrizione,
                                importo_cents, modalita, conto_id, ext_key, prenotazione_id)
  select p.checkout, p.struttura, 'entrata', 'affitto',
         coalesce(nullif(p.guest_name, ''), 'Diretto')
           || coalesce(' — ' || nullif(p.camera, ''), '')
           || ' (' || to_char(p.checkin, 'DD/MM') || '–' || to_char(p.checkout, 'DD/MM') || ')',
         p.paid_cents, 'contante', coalesce(nullif(p.conto_id, ''), 'cassa'),
         'pren:' || p.id::text, p.id
  from public.prenotazioni p
  where p.status <> 'cancellata'
    and p.source not in ('booking','airbnb')
    and p.cassa_registrata = false
    and p.paid_cents > 0
    and p.checkout is not null and p.checkout <= oggi
  on conflict (ext_key) do nothing;
  get diagnostics n_cassa = row_count;

  update public.prenotazioni p set cassa_registrata = true
  where exists (select 1 from public.movimenti m where m.ext_key = 'pren:' || p.id::text);

  return jsonb_build_object(
    'eseguito_il', oggi,
    'pulizie_create', n_pul, 'pulizie_fatte', n_fatte,
    'colazioni_create', n_col, 'colazioni_aggiornate', n_col_upd,
    'entrate_in_cassa', n_cassa
  );
end;
$$;

comment on function public.sync_camere_pse() is
  'Allinea pulizie, colazioni e incassi in Cassa allo scorrere dei giorni. Idempotente: si può rilanciare quante volte si vuole.';

-- Ogni notte alle 03:10 (ora del server).
select cron.unschedule('camere-pse-sync') where exists (select 1 from cron.job where jobname = 'camere-pse-sync');
select cron.schedule('camere-pse-sync', '10 3 * * *', $$select public.sync_camere_pse();$$);
