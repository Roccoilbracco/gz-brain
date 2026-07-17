-- ============================================================================
-- GZ Brain — schema completo (replica strutturale di Unvrs Brain)
-- Genera tutte le tabelle, vincoli, indici, funzione+trigger e attiva RLS.
-- NON contiene dati: il DB parte vuoto.
--
-- Come applicarlo su un progetto Supabase nuovo:
--   Dashboard Supabase → SQL Editor → incolla questo file → Run
--   (oppure: psql "<CONNECTION_STRING>" -f supabase/schema.sql)
--
-- Modello sicurezza: RLS attivo su tutte le tabelle, nessuna policy.
-- Solo la service_role key (usata dall'app nativa) può leggere/scrivere.
-- ============================================================================

-- ── projects ──────────────────────────────────────────────────────────────
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  description text,
  status      text not null default 'setup' check (status = any (array['live','dev','setup','pausa'])),
  hue         integer not null default 217 check (hue >= 0 and hue <= 360),
  notes       text,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  local_path  text,
  ssh_host    text,
  ssh_path    text
);

-- ── leads ─────────────────────────────────────────────────────────────────
create table if not exists public.leads (
  id                   uuid primary key default gen_random_uuid(),
  project_id           uuid not null references public.projects(id) on delete cascade,
  ragione_sociale      text not null,
  piva                 text not null,
  id_arera             text,
  tipo_servizio        text not null,
  comune               text,
  provincia            text,
  indirizzo            text,
  dominio              text,
  sito_web             text,
  email_info           text,
  email_commerciale    text,
  telefoni             text,
  gruppo               text,
  natura_giuridica     text,
  settori              text,
  latitude             double precision,
  longitude            double precision,
  email                text,
  status               text not null default 'da_contattare',
  owner_id             uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  contacts_enriched_at timestamptz,
  contacts_error       text,
  survey_token         uuid,
  survey_status        text,
  survey_sent_at       timestamptz,
  survey_completed_at  timestamptz,
  survey_last_step_at  timestamptz,
  whatsapp             text,
  telefono             text,
  categoria            text,
  commodity            text,
  servizio_tutela      boolean,
  in_gruppo            boolean,
  macroarea            text,
  completezza_contatti smallint,
  invite_number        integer
);
create index if not exists leads_project_ragione on public.leads using btree (project_id, ragione_sociale);
create index if not exists leads_project_status  on public.leads using btree (project_id, status);

-- ── lead_contacts ─────────────────────────────────────────────────────────
create table if not exists public.lead_contacts (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null references public.leads(id) on delete cascade,
  full_name     text not null,
  role          text,
  birth_date    date,
  birth_place   text,
  linkedin_url  text,
  source        text not null,
  raw           jsonb,
  created_at    timestamptz not null default now(),
  tax_code      text,
  is_legal_rep  boolean,
  gender        text,
  role_code     text,
  role_start    date,
  percent_share numeric
);
create index if not exists lead_contacts_lead on public.lead_contacts using btree (lead_id);

-- ── lead_notes ────────────────────────────────────────────────────────────
create table if not exists public.lead_notes (
  id         uuid primary key default gen_random_uuid(),
  lead_id    uuid not null references public.leads(id) on delete cascade,
  body       text not null,
  author_id  uuid,
  created_at timestamptz not null default now()
);
create index if not exists lead_notes_lead on public.lead_notes using btree (lead_id);

-- ── lead_activity_log ─────────────────────────────────────────────────────
create table if not exists public.lead_activity_log (
  id         uuid primary key default gen_random_uuid(),
  lead_id    uuid not null references public.leads(id) on delete cascade,
  event_type text not null,
  from_value text,
  to_value   text,
  author_id  uuid,
  created_at timestamptz not null default now()
);
create index if not exists lead_activity_lead on public.lead_activity_log using btree (lead_id, created_at desc);

-- ── hub_events ────────────────────────────────────────────────────────────
create table if not exists public.hub_events (
  id         bigint primary key generated always as identity,
  project_id uuid references public.projects(id) on delete cascade,
  kind       text not null,
  message    text not null,
  created_at timestamptz not null default now()
);
create index if not exists hub_events_project_created on public.hub_events using btree (project_id, created_at desc);

-- ── clienti ───────────────────────────────────────────────────────────────
create table if not exists public.clienti (
  id              uuid primary key default gen_random_uuid(),
  ragione_sociale text not null,
  piva            text,
  comune          text,
  provincia       text,
  indirizzo       text,
  email           text,
  telefono        text,
  note            text,
  source          text not null default 'manuale',
  lead_id         uuid references public.leads(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  cap             text,
  sito_web        text
);
create unique index if not exists clienti_lead_id_uniq on public.clienti using btree (lead_id) where (lead_id is not null);

-- ── commesse ──────────────────────────────────────────────────────────────
create table if not exists public.commesse (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clienti(id) on delete cascade,
  nome        text not null,
  tipo        text,
  stato       text not null default 'in_corso',
  importo     numeric,
  note        text,
  data_inizio date,
  data_fine   date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists commesse_cliente_id_idx on public.commesse using btree (cliente_id);

-- ── cliente_documenti ─────────────────────────────────────────────────────
create table if not exists public.cliente_documenti (
  id         uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clienti(id) on delete cascade,
  nome       text not null,
  path       text not null,
  created_at timestamptz not null default now()
);
create index if not exists cliente_documenti_cliente_id_idx on public.cliente_documenti using btree (cliente_id);

-- ── azienda_settings (singleton id=1) ─────────────────────────────────────
create table if not exists public.azienda_settings (
  id             smallint primary key default 1 check (id = 1),
  ragione_sociale text,
  indirizzo      text,
  vat_number     text,
  reg_number     text,
  iban           text,
  bic            text,
  website        text,
  email          text,
  logo_path      text,
  firma_path     text,
  updated_at     timestamptz not null default now(),
  firmatario     text
);

-- ── fatture ───────────────────────────────────────────────────────────────
create table if not exists public.fatture (
  id               uuid primary key default gen_random_uuid(),
  anno             smallint not null,
  numero           integer not null,
  cliente_id       uuid not null references public.clienti(id) on delete restrict,
  data             date not null default current_date,
  scadenza         date,
  valuta           text not null default 'EUR',
  vat_mode         text not null default 'reverse_charge',
  imponibile_cents integer not null default 0,
  iva_cents        integer not null default 0,
  totale_cents     integer not null default 0,
  stato            text not null default 'bozza',
  note             text,
  pdf_path         text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index if not exists fatture_anno_numero_uq on public.fatture using btree (anno, numero);
create index if not exists fatture_cliente_idx on public.fatture using btree (cliente_id);

-- ── fattura_righe ─────────────────────────────────────────────────────────
create table if not exists public.fattura_righe (
  id                    uuid primary key default gen_random_uuid(),
  fattura_id            uuid not null references public.fatture(id) on delete cascade,
  descrizione           text not null,
  qta                   numeric not null default 1,
  prezzo_unitario_cents integer not null default 0,
  totale_cents          integer not null default 0,
  ordine                smallint not null default 0
);
create index if not exists fattura_righe_fattura_idx on public.fattura_righe using btree (fattura_id);

-- ── spese ─────────────────────────────────────────────────────────────────
create table if not exists public.spese (
  id            uuid primary key default gen_random_uuid(),
  data          date not null default current_date,
  fornitore     text,
  descrizione   text,
  importo_cents integer not null default 0,
  iva_cents     integer not null default 0,
  categoria     text,
  file_path     text,
  created_at    timestamptz not null default now()
);

-- ── estratti_conto ────────────────────────────────────────────────────────
create table if not exists public.estratti_conto (
  id         uuid primary key default gen_random_uuid(),
  anno       integer not null,
  mese       integer not null,
  banca      text,
  file_path  text,
  created_at timestamptz default now()
);

-- ── mov_match ─────────────────────────────────────────────────────────────
create table if not exists public.mov_match (
  tx_id      text primary key,
  kind       text not null,
  ref_id     uuid,
  created_at timestamptz default now()
);

-- ── re_leads (CRM immobiliare: richieste da Sito/Social/Chiamate/WhatsApp/Email/Idealista) ──
create table if not exists public.re_leads (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text,
  email           text,
  source          text not null default 'sito',   -- sito|social|chiamata|whatsapp|email|idealista
  stage           text not null default 'nuovo',  -- pipeline: nuovo|contattato|qualificato|visita|proposta|trattativa|vinto|perso
  interest        text,                            -- acquisto|affitto|vendita
  property_type   text,                            -- appartamento|villa|attico|terreno|commerciale
  zone            text,
  budget_min      integer,
  budget_max      integer,
  bedrooms        smallint,
  notes           text,
  assigned_to     text,
  idealista_ref   text,
  last_contact_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists re_leads_stage_idx   on public.re_leads using btree (stage);
create index if not exists re_leads_source_idx  on public.re_leads using btree (source);
create index if not exists re_leads_created_idx on public.re_leads using btree (created_at desc);

-- ── funzione + trigger: lead chiuso_vinto → crea/aggiorna cliente ─────────
create or replace function public.sync_lead_cliente()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.status = 'chiuso_vinto' then
    begin
      insert into public.clienti (ragione_sociale, piva, comune, provincia, indirizzo, email, telefono, source, lead_id)
      values (new.ragione_sociale, new.piva, new.comune, new.provincia, new.indirizzo,
              coalesce(new.email, new.email_info, new.email_commerciale),
              coalesce(new.telefono, new.whatsapp, new.telefoni),
              'energizzo', new.id)
      on conflict (lead_id) where lead_id is not null
      do update set ragione_sociale = excluded.ragione_sociale,
                    piva = excluded.piva, comune = excluded.comune, provincia = excluded.provincia,
                    indirizzo = excluded.indirizzo, email = excluded.email, telefono = excluded.telefono,
                    updated_at = now();
    exception when others then
      null;  -- non bloccare la scrittura del lead per un problema di sync
    end;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_sync_lead_cliente on public.leads;
create trigger trg_sync_lead_cliente
  after insert or update of status on public.leads
  for each row execute function public.sync_lead_cliente();

-- ── RLS: attiva su tutte le tabelle, nessuna policy (solo service_role) ───
alter table public.projects          enable row level security;
alter table public.leads             enable row level security;
alter table public.lead_contacts     enable row level security;
alter table public.lead_notes        enable row level security;
alter table public.lead_activity_log enable row level security;
alter table public.hub_events        enable row level security;
alter table public.clienti           enable row level security;
alter table public.commesse          enable row level security;
alter table public.cliente_documenti enable row level security;
alter table public.azienda_settings  enable row level security;
alter table public.fatture           enable row level security;
alter table public.fattura_righe     enable row level security;
alter table public.spese             enable row level security;
alter table public.estratti_conto    enable row level security;
alter table public.mov_match         enable row level security;
alter table public.re_leads          enable row level security;
