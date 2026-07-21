-- Registro proprietari/inquilini che affidano immobili in gestione.
-- Pipeline gemella di re_leads (stessa struttura), con campi propri dell'immobile offerto.
create table if not exists public.re_owners (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text,
  email           text,
  source          text not null default 'diretto',
  stage           text not null default 'nuovo',   -- nuovo/da_valutare/disponibile/in_gestione/concluso/archiviato
  interest        text,          -- tipo operazione offerta: affitto / vendita / traspaso
  category        text,          -- residenziale / commerciale
  property_type   text,
  zone            text,
  budget_min      integer,       -- prezzo richiesto (min)
  budget_max      integer,       -- prezzo richiesto (max)
  bedrooms        smallint,
  notes           text,
  request_message text,
  assigned_to     text,
  idealista_ref   text,
  last_contact_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- campi specifici dell'immobile offerto dal proprietario
  property_offered text,         -- che immobile offre (descrizione)
  size_sqm         integer,      -- m²
  has_license      boolean,      -- ha licenza (sì/no/—)
  license_type     text,         -- tipo di licenza
  three_phase      boolean       -- installazione trifase (sì/no/—)
);

alter table public.re_owners enable row level security;

create index if not exists re_owners_created_idx on public.re_owners (created_at desc);
create index if not exists re_owners_stage_idx   on public.re_owners (stage);
