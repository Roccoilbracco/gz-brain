-- ─────────────────────────────────────────────────────────────────────────────
-- Ogni progetto immobiliare ha le SUE proprietà, i SUOI lead, i SUOI contatti
--
-- Com'era: `proprieta.site_visibility` jsonb {slug: bool}. Una proprietà poteva
-- comparire su più siti, e "a chi appartiene" non era scritto da nessuna parte:
-- si deduceva da dove era pubblicata. Non è mai servito — al momento della
-- migrazione: 15 righe {gz-ibiza:true}, 1 riga {wallis-57:true}, 76 vuote,
-- nessuna su due siti — e non è quello che vogliamo: GZ Ibiza pubblica le sue,
-- Wallis 57 le sue.
--
-- Com'è adesso, due colonne che dicono due cose diverse:
--   project_slug → DI CHI è l'immobile (non cambia, decide in che dash appare)
--   pubblicata   → SE è online sul sito di quel progetto (si accende e spegne)
--
-- Stesso `project_slug` che `visite`, `visite_disponibilita`, `wa_contatti` e
-- `wa_conversations` già usano: qui si allineano anche proprieta, re_leads,
-- re_owners e clienti.
--
-- `site_visibility` NON viene droppata qui: resta finché i due siti non sono
-- ridistribuiti e leggono `pubblicata`. La drop sta in fondo, commentata.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Le quattro tabelle che non avevano il progetto ────────────────────────
-- Il default 'gz-ibiza' non è pigrizia: è l'unica risposta giusta per tutto
-- quello che esiste oggi, ed evita che un client vecchio inserisca righe orfane.

alter table public.proprieta
  add column if not exists project_slug text,
  add column if not exists pubblicata   boolean not null default false;

alter table public.re_leads  add column if not exists project_slug text;
alter table public.re_owners add column if not exists project_slug text;
alter table public.clienti   add column if not exists project_slug text;

-- ── 2. Backfill dai dati attuali ─────────────────────────────────────────────

-- L'unica proprietà marcata wallis-57 resta a Wallis; tutto il resto (comprese
-- le 76 senza visibilità, che sono l'import Idealista) è GZ Ibiza.
update public.proprieta
   set project_slug = case when site_visibility ? 'wallis-57' then 'wallis-57'
                           else 'gz-ibiza' end
 where project_slug is null;

-- "Pubblicata" = era visibile su almeno un sito.
update public.proprieta
   set pubblicata = true
 where exists (select 1
                 from jsonb_each_text(coalesce(site_visibility, '{}'::jsonb)) kv
                where kv.value = 'true');

update public.re_leads  set project_slug = 'gz-ibiza' where project_slug is null;
update public.re_owners set project_slug = 'gz-ibiza' where project_slug is null;
update public.clienti   set project_slug = 'gz-ibiza' where project_slug is null;

-- ── 3. Vincoli: il progetto deve esistere e non può mancare ──────────────────

do $$
begin
  execute 'alter table public.proprieta  alter column project_slug set not null,
                                         alter column project_slug set default ''gz-ibiza''';
  execute 'alter table public.re_leads   alter column project_slug set not null,
                                         alter column project_slug set default ''gz-ibiza''';
  execute 'alter table public.re_owners  alter column project_slug set not null,
                                         alter column project_slug set default ''gz-ibiza''';
  execute 'alter table public.clienti    alter column project_slug set not null,
                                         alter column project_slug set default ''gz-ibiza''';
end $$;

alter table public.proprieta
  drop constraint if exists proprieta_project_slug_fkey,
  add  constraint proprieta_project_slug_fkey
       foreign key (project_slug) references public.projects(slug)
       on update cascade;

alter table public.re_leads
  drop constraint if exists re_leads_project_slug_fkey,
  add  constraint re_leads_project_slug_fkey
       foreign key (project_slug) references public.projects(slug)
       on update cascade;

alter table public.re_owners
  drop constraint if exists re_owners_project_slug_fkey,
  add  constraint re_owners_project_slug_fkey
       foreign key (project_slug) references public.projects(slug)
       on update cascade;

alter table public.clienti
  drop constraint if exists clienti_project_slug_fkey,
  add  constraint clienti_project_slug_fkey
       foreign key (project_slug) references public.projects(slug)
       on update cascade;

-- Le dash filtrano sempre per progetto: senza indice ogni apertura è un seq scan.
create index if not exists proprieta_project_slug_idx on public.proprieta (project_slug);
create index if not exists re_leads_project_slug_idx  on public.re_leads  (project_slug);
create index if not exists re_owners_project_slug_idx on public.re_owners (project_slug);
create index if not exists clienti_project_slug_idx   on public.clienti   (project_slug);
-- I siti chiedono "le pubblicate di questo progetto": indice composto.
create index if not exists proprieta_sito_idx on public.proprieta (project_slug, pubblicata)
  where pubblicata;

comment on column public.proprieta.project_slug is
  'Progetto proprietario dell''immobile (gz-ibiza | wallis-57). Decide in quale dash appare e su quale sito può essere pubblicato.';
comment on column public.proprieta.pubblicata is
  'true = online sul sito del proprio progetto. Sostituisce site_visibility.';

-- ── 4. Il form del sito alimenta la pipeline del progetto giusto ─────────────
-- Prima il trigger lavorava solo per gz-ibiza (Wallis leggeva solicitudes_web
-- con una board tutta sua). Adesso le due dash sono identiche: entrambe leggono
-- re_leads, quindi il ponte vale per qualunque `sitio` che sia un progetto.

create or replace function public.solicitud_web_to_re_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- `sitio` deve essere un progetto esistente: un valore sconosciuto non crea
  -- lead invisibili in nessuna dash.
  if new.sitio is null
     or not exists (select 1 from public.projects p where p.slug = new.sitio) then
    return new;
  end if;

  insert into public.re_leads (name, phone, email, source, stage, notes,
                               solicitud_id, project_slug, created_at)
  values (
    nullif(btrim(concat_ws(' ', nullif(btrim(new.nombre), ''), nullif(btrim(new.apellido), ''))), ''),
    nullif(btrim(new.telefono), ''),
    nullif(btrim(new.email), ''),
    'sito',
    'nuovo',
    nullif(btrim(new.mensaje), ''),
    new.id,
    new.sitio,
    new.created_at
  )
  on conflict (solicitud_id) where (solicitud_id is not null) do nothing;

  return new;
exception when others then
  -- mai bloccare l'invio del form del sito per un problema di sync
  return new;
end;
$$;

-- Backfill delle richieste arrivate da siti diversi da gz-ibiza (Wallis).
insert into public.re_leads (name, phone, email, source, stage, notes,
                             solicitud_id, project_slug, created_at)
select
  nullif(btrim(concat_ws(' ', nullif(btrim(s.nombre), ''), nullif(btrim(s.apellido), ''))), ''),
  nullif(btrim(s.telefono), ''),
  nullif(btrim(s.email), ''),
  'sito', 'nuovo',
  nullif(btrim(s.mensaje), ''),
  s.id, s.sitio, s.created_at
from public.solicitudes_web s
join public.projects p on p.slug = s.sitio
on conflict (solicitud_id) where (solicitud_id is not null) do nothing;

-- ── 5. Cosa vede il pubblico ─────────────────────────────────────────────────
-- La policy anon diceva "visibile se un qualsiasi slug in site_visibility è
-- true". Adesso: pubblicata. Il filtro per sito lo mette il sito stesso
-- (project_slug=eq.<slug>), la policy decide solo se la riga è online.

drop policy if exists "anon read site-visible proprieta" on public.proprieta;
create policy "anon read proprieta pubblicate" on public.proprieta
  for select to anon
  using (pubblicata);

-- Il GRANT per colonna di 2026-07-24_hardening_sicurezza.sql: le due nuove
-- colonne servono al sito, che filtra per progetto.
grant select (project_slug, pubblicata) on public.proprieta to anon;

-- `site_visibility` resta leggibile: i due siti in produzione ci filtrano
-- ancora sopra e revocarla adesso li spegnerebbe. Si toglie al passo 6.

-- ── 6. Rimozione di site_visibility ──────────────────────────────────────────
-- Fatta a parte, in 2026-07-24_drop_site_visibility.sql: nessuna delle due app
-- Next è in produzione, quindi non c'era da aspettare nessun deploy.
