-- ============================================================================
-- Allegati della contabilità — fatture, ricevute, scontrini, bollette in PDF
--
-- Una riga di contabilità dice quanto e quando; la prova sta nel foglio di
-- carta. Qui il foglio si attacca alla riga, così quando serve controllare non
-- si va a cercare nella cartella dei download.
--
-- Tabella unica e polimorfa (`entita` + `entita_id`) invece di una colonna per
-- tabella: gli allegati sono la stessa cosa ovunque, e domani una pulizia o una
-- prenotazione ne vorranno uno senza bisogno di un'altra migrazione.
-- Niente foreign key proprio perché punta a tabelle diverse: le righe orfane le
-- toglie l'app quando cancella il movimento (lì può togliere anche il file).
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('allegati', 'allegati', false)
on conflict (id) do nothing;

create table if not exists public.allegati (
  id            uuid primary key default gen_random_uuid(),
  entita        text not null,               -- movimento | bolletta
  entita_id     uuid not null,
  titolo        text,                        -- come l'ha chiamato l'utente
  file_path     text not null,               -- percorso nel bucket `allegati`
  file_name     text,
  mime          text,
  size_bytes    bigint,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists allegati_entita_idx on public.allegati (entita, entita_id);

-- Come `documenti` e `bollette`: RLS accesa senza policy, quindi la tabella la
-- vede solo chi usa la secret key (l'app nativa). Le fatture non hanno motivo
-- di uscire da lì — né dal browser né dal portale proprietari.
alter table public.allegati enable row level security;
