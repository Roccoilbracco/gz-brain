-- NCREATIVE — moduli Social Media, Finanze (agenzia) e Personale.
-- Seguono la convenzione `nc_`: importi in centesimi, RLS attiva, solo service_role.

-- ── 1. SOCIAL MEDIA ─────────────────────────────────────────────────────────
-- Account seguiti: sia quelli dei clienti (`role` = 'own') sia i competitor
-- ('competitor'), agganciati allo stesso cliente per il confronto.
create table if not exists public.nc_social_accounts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete cascade,
  role text not null default 'own',                -- own | competitor
  platform text not null default 'instagram',
  handle text not null,
  external_id text,                                -- IG user id / channel id
  page_id text,                                    -- Facebook Page collegata
  ad_account_id text,                              -- act_xxx per le ads
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now()
);

-- Fotografia giornaliera per account. Una riga per (account, giorno).
create table if not exists public.nc_social_daily (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.nc_social_accounts(id) on delete cascade,
  date date not null,
  followers integer,
  posts integer,
  likes integer not null default 0,
  comments integer not null default 0,
  messages integer not null default 0,
  reach integer,
  impressions integer,
  profile_views integer,
  source text not null default 'manual',           -- manual | meta | import
  created_at timestamptz not null default now(),
  unique (account_id, date)
);

-- Singoli contenuti pubblicati, con le loro metriche.
create table if not exists public.nc_social_posts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.nc_social_accounts(id) on delete cascade,
  external_id text,
  published_at timestamptz,
  permalink text,
  format text,                                     -- reel | post | carousel | story
  caption text,
  likes integer not null default 0,
  comments integer not null default 0,
  saves integer not null default 0,
  shares integer not null default 0,
  reach integer,
  is_ad boolean not null default false,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  unique (account_id, external_id)
);

-- Campagne a pagamento, aggregate per giorno.
create table if not exists public.nc_ads_daily (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete cascade,
  date date not null,
  campaign text,
  spend_cents integer not null default 0,
  impressions integer not null default 0,
  clicks integer not null default 0,
  results integer not null default 0,
  likes integer not null default 0,
  comments integer not null default 0,
  messages integer not null default 0,
  source text not null default 'manual',
  created_at timestamptz not null default now()
);

-- Suggerimenti quotidiani e audit mensili (testo generato, in markdown).
create table if not exists public.nc_insights (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.nc_clients(id) on delete cascade,
  kind text not null default 'suggestion',         -- suggestion | audit
  period text,                                     -- "yyyy-MM" per gli audit
  date date,                                       -- giorno per i suggerimenti
  title text,
  body text,
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

-- Credenziali delle integrazioni (token Meta ecc.). Sta su Supabase, mai nel repo.
create table if not exists public.nc_integrations (
  id uuid primary key default gen_random_uuid(),
  provider text not null,                          -- meta | tiktok | gocardless
  label text,
  access_token text,
  refresh_token text,
  expires_at timestamptz,
  meta jsonb not null default '{}',
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (provider, label)
);

-- ── 2. FINANZE AGENZIA ──────────────────────────────────────────────────────
-- Budget per categoria: `month` null = budget annuale spalmato sui 12 mesi.
create table if not exists public.nc_budget (
  id uuid primary key default gen_random_uuid(),
  year integer not null,
  month integer,                                   -- 1-12, null = tutto l'anno
  category text not null,                          -- stessa tassonomia di nc_expenses
  amount_cents integer not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  unique (year, month, category)
);

create table if not exists public.nc_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  bank text,
  iban_last4 text,
  provider text,                                   -- gocardless | manual
  external_id text,
  currency text not null default 'EUR',
  balance_cents integer not null default 0,
  synced_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Movimenti bancari. `external_id` unico per non duplicare a ogni sync.
create table if not exists public.nc_bank_tx (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.nc_bank_accounts(id) on delete cascade,
  date date not null,
  description text,
  counterparty text,
  amount_cents integer not null default 0,         -- negativo = uscita
  category text,
  expense_id uuid references public.nc_expenses(id) on delete set null,
  invoice_id uuid references public.nc_invoices(id) on delete set null,
  external_id text unique,
  source text not null default 'manual',
  created_at timestamptz not null default now()
);

-- ── 3. PERSONALE ────────────────────────────────────────────────────────────
-- Una riga per voce, qualunque sia la colonna (famiglia/giorgio/niko) e il tipo.
-- Tenere una tabella sola rende banale la vista a tre colonne × tre orizzonti.
create table if not exists public.nc_personal_items (
  id uuid primary key default gen_random_uuid(),
  person text not null default 'famiglia',         -- famiglia | giorgio | niko
  kind text not null default 'todo',               -- appuntamento | todo | importante | spesa | pasto | obiettivo | finanza
  title text not null,
  notes text,
  day date,                                        -- null = senza data
  time_at text,                                    -- "18:30", niente fusi orari
  slot text,                                       -- pranzo | cena (per i pasti)
  done boolean not null default false,
  priority integer not null default 0,
  repeat_rule text,                                -- daily | weekly | monthly
  notify_at text,                                  -- "09:00": promemoria ricorrente
  month text,                                      -- "yyyy-MM" per obiettivi e finanze
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.nc_social_accounts enable row level security;
alter table public.nc_social_daily    enable row level security;
alter table public.nc_social_posts    enable row level security;
alter table public.nc_ads_daily       enable row level security;
alter table public.nc_insights        enable row level security;
alter table public.nc_integrations    enable row level security;
alter table public.nc_budget          enable row level security;
alter table public.nc_bank_accounts   enable row level security;
alter table public.nc_bank_tx         enable row level security;
alter table public.nc_personal_items  enable row level security;

create index if not exists nc_social_daily_date_idx  on public.nc_social_daily (date desc);
create index if not exists nc_social_posts_pub_idx   on public.nc_social_posts (published_at desc);
create index if not exists nc_ads_daily_date_idx     on public.nc_ads_daily (date desc);
create index if not exists nc_insights_client_idx    on public.nc_insights (client_id, kind, created_at desc);
create index if not exists nc_bank_tx_date_idx       on public.nc_bank_tx (date desc);
create index if not exists nc_personal_day_idx       on public.nc_personal_items (day, person);
create index if not exists nc_personal_month_idx     on public.nc_personal_items (month);
