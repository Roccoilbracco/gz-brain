-- Educamp Via Romagna: elenco ospiti + calcolo mensile per ospite (affitto/commissione/utenze).
create table if not exists public.educamp_ospiti (
  id uuid primary key default gen_random_uuid(),
  ospite text not null,
  gruppo text,
  camera text,
  checkin date,
  checkout date,
  notti integer,
  note text,
  sort_order integer default 0
);
create table if not exists public.educamp_righe (
  id uuid primary key default gen_random_uuid(),
  mese text not null,                 -- "yyyy-MM"
  ospite text not null,
  camera text,
  giorni integer,
  lordo_cents integer not null default 0,
  commissione_cents integer not null default 0,
  netto_cents integer not null default 0,
  utenze_cents integer not null default 0,
  totale_ospite_cents integer not null default 0,
  netto_noi_cents integer not null default 0,
  sort_order integer default 0
);
alter table public.educamp_ospiti enable row level security;
alter table public.educamp_righe enable row level security;
create index if not exists educamp_righe_mese_idx on public.educamp_righe (mese, sort_order);
