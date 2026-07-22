-- ============================================================================
-- Archivio documenti GZ Ibiza: modelli/bozze di contratto ed encargo, e i PDF
-- firmati agganciati al proprietario (o all'immobile).
--
-- Distinto da proprieta_documenti, che resta il posto dei documenti tecnici del
-- singolo immobile (contratto, piantina, catasto). Questa tabella tiene i
-- modelli riusabili e i documenti firmati del proprietario.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('documenti', 'documenti', false)
on conflict (id) do nothing;

create table if not exists public.documenti (
  id            uuid primary key default gen_random_uuid(),
  progetto      text not null default 'gz-ibiza',
  tipo          text not null default 'modello',   -- modello | firmato
  categoria     text not null default 'altro',     -- encargo | venta | alquiler | traspaso | mandato | nota | altro
  titolo        text not null,
  descrizione   text,
  file_path     text not null,
  file_name     text,
  mime          text,
  size_bytes    bigint,
  owner_id      uuid references public.re_owners(id) on delete set null,
  proprieta_id  uuid references public.proprieta(id) on delete set null,
  lead_id       uuid references public.re_leads(id) on delete set null,
  firmato_il    date,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists documenti_progetto_idx on public.documenti (progetto, tipo, categoria);
create index if not exists documenti_owner_idx    on public.documenti (owner_id);
create index if not exists documenti_prop_idx     on public.documenti (proprieta_id);

alter table public.documenti enable row level security;
