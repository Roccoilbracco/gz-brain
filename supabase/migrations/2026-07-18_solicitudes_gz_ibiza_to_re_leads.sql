-- ─────────────────────────────────────────────────────────────────────────────
-- Richieste dal form di gz-ibiza → lead nel kanban
--
-- Il sito (Roccoilbracco/gz-ibiza) inserisce in public.solicitudes_web con
-- sitio='gz-ibiza' usando la chiave publishable (RLS: solo insert per anon).
-- Wallis 57 legge solicitudes_web direttamente, GZ Ibiza invece ha il kanban
-- su public.re_leads: questo trigger fa da ponte e crea il lead in stadio
-- 'nuovo' con source 'sito'.
--
-- solicitud_id tiene il legame 1:1 con la richiesta originale (unique) così il
-- backfill e un'eventuale riesecuzione non duplicano i lead.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.re_leads add column if not exists solicitud_id uuid;

create unique index if not exists re_leads_solicitud_id_uniq
  on public.re_leads using btree (solicitud_id)
  where (solicitud_id is not null);

create or replace function public.solicitud_web_to_re_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sitio is distinct from 'gz-ibiza' then
    return new;
  end if;

  insert into public.re_leads (name, phone, email, source, stage, notes, solicitud_id, created_at)
  values (
    nullif(btrim(concat_ws(' ', nullif(btrim(new.nombre), ''), nullif(btrim(new.apellido), ''))), ''),
    nullif(btrim(new.telefono), ''),
    nullif(btrim(new.email), ''),
    'sito',
    'nuovo',
    nullif(btrim(new.mensaje), ''),
    new.id,
    new.created_at
  )
  on conflict (solicitud_id) where (solicitud_id is not null) do nothing;

  return new;
exception when others then
  -- mai bloccare l'invio del form del sito per un problema di sync
  return new;
end;
$$;

drop trigger if exists trg_solicitud_web_to_re_lead on public.solicitudes_web;
create trigger trg_solicitud_web_to_re_lead
  after insert on public.solicitudes_web
  for each row execute function public.solicitud_web_to_re_lead();

-- Backfill: richieste gz-ibiza già arrivate prima del trigger
insert into public.re_leads (name, phone, email, source, stage, notes, solicitud_id, created_at)
select
  nullif(btrim(concat_ws(' ', nullif(btrim(s.nombre), ''), nullif(btrim(s.apellido), ''))), ''),
  nullif(btrim(s.telefono), ''),
  nullif(btrim(s.email), ''),
  'sito',
  'nuovo',
  nullif(btrim(s.mensaje), ''),
  s.id,
  s.created_at
from public.solicitudes_web s
where s.sitio = 'gz-ibiza'
on conflict (solicitud_id) where (solicitud_id is not null) do nothing;
