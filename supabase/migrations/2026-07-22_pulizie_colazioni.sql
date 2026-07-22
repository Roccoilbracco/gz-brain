-- Servizi Camere PSE: dettaglio pulizie (20 €/check-out) e colazioni (3,50 €/pers·notte Booking).
create table if not exists public.pulizie (
  id uuid primary key default gen_random_uuid(),
  data date,
  casa text,                    -- via-po / via-romagna
  descrizione text,             -- camera / ospite
  stato text,                   -- fatta / prevista
  costo_cents integer not null default 0,
  sort_order integer default 0
);
create table if not exists public.colazioni (
  id uuid primary key default gen_random_uuid(),
  ospite text,
  camera text,
  arrivo date,
  partenza date,
  notti integer,
  persone integer,
  costo_totale_cents integer not null default 0,
  notti_servite integer,
  costo_servito_cents integer not null default 0,
  stato text,                   -- servite / prevista
  sort_order integer default 0
);
alter table public.pulizie enable row level security;
alter table public.colazioni enable row level security;
