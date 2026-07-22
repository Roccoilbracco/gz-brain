-- NCREATIVE — CRM dell'agenzia di social media marketing di Nikola.
-- Vive nello stesso progetto Supabase di GZ Brain ma non tocca nulla del CRM
-- immobiliare: tutte le tabelle sono prefissate `nc_`.
-- Importi in centesimi (integer), come tesoreria/educamp.

-- Clienti e contratti (retainer mensile + servizi attivi)
create table if not exists public.nc_clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,                              -- brand / ragione sociale
  contact_name text,
  email text,
  phone text,
  instagram text,
  website text,
  status text not null default 'lead',             -- lead | active | paused | churned
  retainer_cents integer not null default 0,       -- fee mensile ricorrente
  services text[] not null default '{}',           -- social, ads, content, branding, web
  start_date date,
  source text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Pipeline commerciale: lead in entrata e preventivi inviati
create table if not exists public.nc_deals (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete set null,
  title text not null,
  contact_name text,                               -- lead senza scheda cliente
  email text,
  phone text,
  stage text not null default 'new',               -- new | contacted | proposal | negotiation | won | lost
  value_cents integer not null default 0,
  recurring boolean not null default false,        -- retainer mensile vs one-off
  source text,
  expected_close date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Campagne / progetti per cliente
create table if not exists public.nc_campaigns (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete cascade,
  name text not null,
  kind text,                                       -- campaign | retainer | launch | one-off
  status text not null default 'active',           -- planned | active | done | on_hold
  start_date date,
  end_date date,
  budget_cents integer not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

-- Calendario contenuti social
create table if not exists public.nc_content (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete cascade,
  campaign_id uuid references public.nc_campaigns(id) on delete set null,
  title text not null,
  platform text not null default 'instagram',      -- instagram | tiktok | youtube | linkedin | facebook | twitter
  format text,                                     -- reel | post | story | carousel | video
  publish_date date,
  status text not null default 'idea',             -- idea | draft | review | approved | scheduled | published
  owner text,
  link text,
  notes text,
  created_at timestamptz not null default now()
);

-- Fatture emesse
create table if not exists public.nc_invoices (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete set null,
  number text,
  issue_date date not null default current_date,
  due_date date,
  period text,                                     -- "yyyy-MM" di competenza
  description text,
  amount_cents integer not null default 0,         -- imponibile
  vat_pct numeric not null default 21,
  status text not null default 'draft',            -- draft | sent | paid
  paid_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Spese (ads, tool, freelance, ufficio…)
create table if not exists public.nc_expenses (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete set null,  -- se riaddebitata al cliente
  date date not null default current_date,
  category text not null default 'other',          -- ads | tools | freelance | salary | office | other
  vendor text,
  description text,
  amount_cents integer not null default 0,
  recurring boolean not null default false,
  notes text,
  created_at timestamptz not null default now()
);

alter table public.nc_clients   enable row level security;
alter table public.nc_deals     enable row level security;
alter table public.nc_campaigns enable row level security;
alter table public.nc_content   enable row level security;
alter table public.nc_invoices  enable row level security;
alter table public.nc_expenses  enable row level security;

create index if not exists nc_deals_stage_idx      on public.nc_deals (stage);
create index if not exists nc_content_date_idx     on public.nc_content (publish_date);
create index if not exists nc_content_client_idx   on public.nc_content (client_id);
create index if not exists nc_invoices_client_idx  on public.nc_invoices (client_id);
create index if not exists nc_invoices_issue_idx   on public.nc_invoices (issue_date);
create index if not exists nc_expenses_date_idx    on public.nc_expenses (date);
