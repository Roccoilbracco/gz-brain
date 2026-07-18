-- ── WhatsApp + agenti conversazionali ────────────────────────────────────────
-- Un agente per progetto (gz-ibiza, wallis-57), ognuno agganciato al suo numero
-- WhatsApp tramite Baileys. Il servizio Node su Hetzner scrive qui; GZ Brain legge.
-- Additiva: non tocca nessuna tabella esistente.

-- Configurazione dell'agente, una riga per progetto/numero.
create table if not exists public.wa_agents (
  id                  uuid primary key default gen_random_uuid(),
  project_slug        text not null unique,          -- 'gz-ibiza' | 'wallis-57'
  display_name        text not null,
  phone_number        text,                          -- numero collegato (informativo)
  -- KILL SWITCH: se false l'agente non invia nulla, i messaggi vengono comunque salvati.
  enabled             boolean not null default false,
  connection_status   text not null default 'disconnesso',  -- disconnesso|qr|connesso
  connection_error    text,
  last_seen_at        timestamptz,
  model               text not null default 'claude-sonnet-5',
  system_prompt       text not null default '',
  knowledge           text not null default '',      -- info a cui l'agente attinge
  greeting            text,                          -- primo messaggio a chi scrive nuovo
  -- Stop automatici: oltre N messaggi dell'agente senza qualificare, passa a umano.
  max_agent_messages  int not null default 20,
  escalation_keywords text[] not null default array['persona','umano','operatore','titolare','chiamami'],
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Una conversazione per (progetto, numero cliente).
create table if not exists public.wa_conversations (
  id               uuid primary key default gen_random_uuid(),
  project_slug     text not null,
  wa_jid           text not null,        -- es. '34600111222@s.whatsapp.net'
  phone            text,
  customer_name    text,                 -- push name WhatsApp, poi corretto dall'agente
  status           text not null default 'attiva',  -- attiva|qualificata|escalata|chiusa
  -- Override per singola conversazione: l'agente tace qui anche se globalmente attivo
  -- (lo alza l'escalation, o tu a mano quando subentri).
  agent_enabled    boolean not null default true,
  agent_msg_count  int not null default 0,
  summary          text,                 -- riassunto della richiesta, generato dall'agente
  -- Card kanban generata: re_leads per gz-ibiza, solicitudes_web per wallis-57.
  lead_id          uuid,
  lead_table       text,
  last_message_at  timestamptz,
  created_at       timestamptz not null default now(),
  unique (project_slug, wa_jid)
);

create table if not exists public.wa_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.wa_conversations(id) on delete cascade,
  direction       text not null,            -- 'in' | 'out'
  author          text not null,            -- 'cliente' | 'agente' | 'umano'
  body            text not null default '',
  wa_msg_id       text,                     -- id WhatsApp, per deduplicare i retry
  created_at      timestamptz not null default now()
);

create index if not exists wa_conversations_slug_idx  on public.wa_conversations (project_slug, last_message_at desc);
create index if not exists wa_conversations_status_idx on public.wa_conversations (status);
create index if not exists wa_messages_conv_idx        on public.wa_messages (conversation_id, created_at);
create unique index if not exists wa_messages_waid_idx on public.wa_messages (wa_msg_id) where wa_msg_id is not null;

alter table public.wa_agents        enable row level security;
alter table public.wa_conversations enable row level security;
alter table public.wa_messages      enable row level security;

-- Seed dei due agenti, spenti: si accendono dal bottone Agente in GZ Brain
-- dopo aver collegato il numero e riletto il prompt.
insert into public.wa_agents (project_slug, display_name, system_prompt, greeting)
values
  ('gz-ibiza',  'Agente GZ Ibiza',  '', 'Ciao! Sono l''assistente di GZ Ibiza Properties. Come posso aiutarti?'),
  ('wallis-57', 'Agente Wallis 57', '', 'Hola! Soy el asistente de Wallis 57. ¿En qué puedo ayudarte?')
on conflict (project_slug) do nothing;
