-- ═══════════════════════════════════════════════════════════════════════════
-- MIRROR dello schema live (Supabase qjmgifkkutzkjepyoshf) — 2026-07-02
-- Tabelle del modulo fatturazione/spese/banca, create a suo tempo via
-- MCP/dashboard e mai specchiate nel repo. Questo file NON è stato applicato
-- come migration: documenta lo stato reale del DB (regola "mirror manuale").
-- Le tabelle clienti/commesse e i campi ssh_* di projects hanno già i loro file.
--
-- Storage bucket usati dall'app (non ricreabili via SQL): fatture, spese,
-- estratti, azienda, clienti.
-- RLS: attivo su tutte le tabelle, NESSUNA policy = accesso solo service-role
-- (pattern voluto, app single-tenant).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Impostazioni azienda (riga singola, id forzato a 1) ──
create table if not exists public.azienda_settings (
  id               smallint primary key default 1,
  ragione_sociale  text,
  indirizzo        text,
  vat_number       text,
  reg_number       text,
  iban             text,
  bic              text,
  website          text,
  email            text,
  logo_path        text,          -- path nel bucket 'azienda'
  firma_path       text,          -- (legacy, non usato dall'app)
  firmatario       text,          -- nome reso in corsivo nel PDF fattura
  updated_at       timestamptz not null default now(),
  constraint azienda_settings_singleton check (id = 1)
);
alter table public.azienda_settings enable row level security;

-- ── Fatture attive (importi SEMPRE in cents interi) ──
create table if not exists public.fatture (
  id               uuid primary key default gen_random_uuid(),
  anno             smallint not null,
  numero           integer not null,
  cliente_id       uuid not null references public.clienti(id) on delete restrict,
  data             date not null default current_date,
  scadenza         date,
  valuta           text not null default 'EUR',
  vat_mode         text not null default 'reverse_charge',  -- reverse_charge | cyprus_19 | out_of_scope
  imponibile_cents integer not null default 0,
  iva_cents        integer not null default 0,
  totale_cents     integer not null default 0,
  stato            text not null default 'bozza',           -- emessa | inviata | pagata | annullata
  note             text,
  pdf_path         text,          -- path nel bucket 'fatture' (<anno>/<numero>.pdf)
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.fatture enable row level security;

-- PROPOSTO, NON ANCORA APPLICATO AL DB LIVE (dati attuali già senza duplicati):
-- create unique index if not exists fatture_anno_numero_uq on public.fatture (anno, numero);

create table if not exists public.fattura_righe (
  id                     uuid primary key default gen_random_uuid(),
  fattura_id             uuid not null references public.fatture(id) on delete cascade,
  descrizione            text not null,
  qta                    numeric not null default 1,
  prezzo_unitario_cents  integer not null default 0,
  totale_cents           integer not null default 0,
  ordine                 smallint not null default 0
);
alter table public.fattura_righe enable row level security;

-- ── Spese (fatture passive ricevute/pagate) ──
create table if not exists public.spese (
  id             uuid primary key default gen_random_uuid(),
  data           date not null default current_date,
  fornitore      text,
  descrizione    text,
  importo_cents  integer not null default 0,   -- imponibile
  iva_cents      integer not null default 0,
  categoria      text,
  file_path      text,          -- path nel bucket 'spese'
  created_at     timestamptz not null default now()
);
alter table public.spese enable row level security;

-- ── Estratti conto bancari (un file per mese) ──
create table if not exists public.estratti_conto (
  id          uuid primary key default gen_random_uuid(),
  anno        integer not null,
  mese        integer not null,
  banca       text,
  file_path   text,             -- path nel bucket 'estratti' (CSV per la riconciliazione)
  created_at  timestamptz default now()
);
alter table public.estratti_conto enable row level security;

-- ── Abbinamenti manuali movimento bancario ↔ spesa/fattura ──
create table if not exists public.mov_match (
  tx_id       text primary key,  -- id transazione dal CSV (o data|importo|descrizione)
  kind        text not null,     -- spesa | fattura | ignora
  ref_id      uuid,              -- id della spesa/fattura abbinata (null per 'ignora')
  created_at  timestamptz default now()
);
alter table public.mov_match enable row level security;

-- ── Documenti allegati ai clienti ──
create table if not exists public.cliente_documenti (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clienti(id) on delete cascade,
  nome        text not null,
  path        text not null,     -- path nel bucket 'clienti'
  created_at  timestamptz not null default now()
);
alter table public.cliente_documenti enable row level security;
