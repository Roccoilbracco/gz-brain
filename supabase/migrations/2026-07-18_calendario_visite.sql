-- ── Calendario visite ────────────────────────────────────────────────────────
-- Due tabelle distinte: la DISPONIBILITÀ (regola settimanale ricorrente, la
-- imposti tu) e le VISITE (appuntamenti concreti, li fissa l'agente o tu).
-- Gli slot liberi non sono memorizzati: si calcolano al volo come
-- disponibilità meno visite già prese, così cambiando gli orari non resta
-- niente di stantio da riconciliare.

create table if not exists public.visite_disponibilita (
  id             uuid primary key default gen_random_uuid(),
  project_slug   text not null,
  -- ISO 8601: 1 = lunedì … 7 = domenica
  giorno         smallint not null check (giorno between 1 and 7),
  ora_inizio     time not null,
  ora_fine       time not null,
  durata_minuti  smallint not null default 60 check (durata_minuti between 15 and 480),
  attivo         boolean not null default true,
  created_at     timestamptz not null default now(),
  check (ora_fine > ora_inizio)
);

create table if not exists public.visite (
  id                uuid primary key default gen_random_uuid(),
  project_slug      text not null,
  proprieta_id      uuid references public.proprieta(id) on delete set null,
  conversation_id   uuid references public.wa_conversations(id) on delete set null,
  lead_id           uuid,
  cliente_nome      text,
  cliente_telefono  text,
  inizio            timestamptz not null,
  fine              timestamptz not null,
  -- proposta: fissata dall'agente, ancora da confermare da te
  -- confermata: hai dato l'ok · annullata · fatta
  stato             text not null default 'proposta',
  note              text,
  created_at        timestamptz not null default now(),
  check (fine > inizio)
);

create index if not exists visite_periodo_idx on public.visite (project_slug, inizio);
create index if not exists visite_stato_idx on public.visite (stato);
create index if not exists visite_disp_idx on public.visite_disponibilita (project_slug, giorno);

alter table public.visite_disponibilita enable row level security;
alter table public.visite enable row level security;

-- Disponibilità di partenza per GZ Ibiza: lun-ven 10-14 e 16-19, sabato 10-13.
-- Sono valori sensati da cui partire, si cambiano dall'app.
insert into public.visite_disponibilita (project_slug, giorno, ora_inizio, ora_fine, durata_minuti)
select 'gz-ibiza', g, '10:00', '14:00', 60 from generate_series(1, 5) g
union all
select 'gz-ibiza', g, '16:00', '19:00', 60 from generate_series(1, 5) g
union all
select 'gz-ibiza', 6, '10:00', '13:00', 60
where not exists (select 1 from public.visite_disponibilita where project_slug = 'gz-ibiza');
