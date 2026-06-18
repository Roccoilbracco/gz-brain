-- Applicata su Supabase qjmgifkkutzkjepyoshf il 2026-06-18 (via MCP).
-- Modulo Clienti (CRM): un cliente ha N progetti (commesse).
-- I lead Energizzo chiuso_vinto diventano clienti in automatico (trigger).

-- 1. Anagrafica clienti
create table if not exists public.clienti (
  id uuid primary key default gen_random_uuid(),
  ragione_sociale text not null,
  piva text,
  comune text,
  provincia text,
  indirizzo text,
  email text,
  telefono text,
  note text,
  source text not null default 'manuale',            -- 'manuale' | 'energizzo'
  lead_id uuid references public.leads(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists clienti_lead_id_uniq on public.clienti(lead_id) where lead_id is not null;

-- 2. Commesse (i progetti per cliente)
create table if not exists public.commesse (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clienti(id) on delete cascade,
  nome text not null,
  tipo text,
  stato text not null default 'in_corso',            -- in_corso | completata | sospesa | annullata
  importo numeric,
  note text,
  data_inizio date,
  data_fine date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists commesse_cliente_id_idx on public.commesse(cliente_id);

-- 3. RLS attivo (accesso solo via service role dell'app; nessuna policy anon by design)
alter table public.clienti enable row level security;
alter table public.commesse enable row level security;

-- 4. Sync automatico lead chiuso_vinto -> cliente (protetto: non blocca mai la scrittura del lead)
create or replace function public.sync_lead_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
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
      null;
    end;
  end if;
  return new;
end;
$$;
revoke execute on function public.sync_lead_cliente() from anon, authenticated, public;

drop trigger if exists trg_sync_lead_cliente on public.leads;
create trigger trg_sync_lead_cliente
  after insert or update of status on public.leads
  for each row execute function public.sync_lead_cliente();

-- 5. Backfill clienti dai lead gia' chiuso_vinto
insert into public.clienti (ragione_sociale, piva, comune, provincia, indirizzo, email, telefono, source, lead_id)
select l.ragione_sociale, l.piva, l.comune, l.provincia, l.indirizzo,
       coalesce(l.email, l.email_info, l.email_commerciale),
       coalesce(l.telefono, l.whatsapp, l.telefoni),
       'energizzo', l.id
from public.leads l
where l.status = 'chiuso_vinto'
on conflict (lead_id) where lead_id is not null do nothing;
