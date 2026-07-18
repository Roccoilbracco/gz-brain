-- ─────────────────────────────────────────────────────────────────────────────
-- Contatti: i lead vinti diventano clienti, con anagrafica e storico
--
-- `clienti` nasce come anagrafica di fatturazione (ragione sociale, P.IVA, e
-- ci puntano fatture e commesse). Qui la estendiamo alle persone fisiche
-- dell'immobiliare senza spezzarla in due: un `tipo` distingue privato e
-- azienda, e i campi persona restano nulli per le aziende.
--
-- ragione_sociale resta NOT NULL perché è il nome mostrato ovunque (fatture
-- comprese): per un privato ci mettiamo il nome completo.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.clienti
  add column if not exists tipo         text not null default 'privato',  -- privato|azienda
  add column if not exists nome         text,
  add column if not exists cognome      text,
  add column if not exists data_nascita date,
  add column if not exists lingua       text,                             -- it|es|en: per gli auguri
  add column if not exists re_lead_id   uuid;                             -- lead immobiliare di origine

-- Le anagrafiche già esistenti con P.IVA sono aziende, non privati.
update public.clienti set tipo = 'azienda' where piva is not null and tipo = 'privato';

-- 1:1 con il lead di origine: la conversione può ripetersi (riapri e richiudi
-- un lead) senza mai creare un doppione.
create unique index if not exists clienti_re_lead_id_uniq
  on public.clienti using btree (re_lead_id) where (re_lead_id is not null);

create index if not exists clienti_data_nascita_idx
  on public.clienti using btree (data_nascita) where (data_nascita is not null);

-- Storico transazioni: la controparte era solo testo libero, così non si
-- poteva risalire da un contatto a cosa ha comprato o affittato.
alter table public.proprieta_storico add column if not exists cliente_id uuid references public.clienti(id) on delete set null;
create index if not exists proprieta_storico_cliente_idx on public.proprieta_storico using btree (cliente_id);

-- ── Lead vinto → cliente ────────────────────────────────────────────────────
-- Scatta solo sul passaggio a 'vinto': è il momento in cui il potenziale
-- cliente diventa cliente. L'interesse del lead (acquisto/affitto/traspaso)
-- finisce nelle note, così si sa da dove arriva.
create or replace function public.sync_re_lead_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  nome_pulito text;
  primo       text;
  resto       text;
begin
  if new.stage is distinct from 'vinto' then
    return new;
  end if;

  nome_pulito := nullif(btrim(coalesce(new.name, '')), '');
  if nome_pulito is null then
    return new;   -- senza un nome non si crea un'anagrafica sensata
  end if;

  -- "Mario Rossi Bianchi" → nome "Mario", cognome "Rossi Bianchi"
  primo := split_part(nome_pulito, ' ', 1);
  resto := nullif(btrim(substr(nome_pulito, length(primo) + 1)), '');

  insert into public.clienti (ragione_sociale, tipo, nome, cognome, email, telefono, source, re_lead_id, note)
  values (
    nome_pulito,
    'privato',
    primo,
    resto,
    nullif(btrim(coalesce(new.email, '')), ''),
    nullif(btrim(coalesce(new.phone, '')), ''),
    'lead',
    new.id,
    nullif(concat_ws(' · ',
      'Da lead ' || coalesce(new.source, 'sito'),
      nullif(new.interest, ''),
      nullif(new.zone, '')), '')
  )
  on conflict (re_lead_id) where (re_lead_id is not null) do update
    set email      = coalesce(excluded.email, public.clienti.email),
        telefono   = coalesce(excluded.telefono, public.clienti.telefono),
        updated_at = now();

  return new;
exception when others then
  -- un problema di anagrafica non deve impedire di chiudere il lead
  return new;
end;
$$;

drop trigger if exists trg_sync_re_lead_cliente on public.re_leads;
create trigger trg_sync_re_lead_cliente
  after insert or update of stage on public.re_leads
  for each row execute function public.sync_re_lead_cliente();

-- ── Ricorrenze: compleanni in arrivo ────────────────────────────────────────
-- Il calcolo "quanti giorni mancano" fatto in SQL: l'anno del compleanno è
-- quello corrente, e se è già passato si guarda al prossimo. Il 29 febbraio
-- cade sul 28 negli anni non bisestili (make_date fallirebbe).
create or replace function public.prossimi_compleanni(giorni int default 30)
returns table (
  id uuid, ragione_sociale text, nome text, cognome text,
  data_nascita date, email text, telefono text, lingua text,
  compleanno date, giorni_mancanti int, eta int
)
language sql
stable
as $$
  with base as (
    select c.id, c.ragione_sociale, c.nome, c.cognome, c.data_nascita,
           c.email, c.telefono, c.lingua,
           make_date(
             extract(year from current_date)::int,
             extract(month from c.data_nascita)::int,
             least(extract(day from c.data_nascita)::int,
                   extract(day from (date_trunc('month',
                     make_date(extract(year from current_date)::int,
                               extract(month from c.data_nascita)::int, 1))
                     + interval '1 month - 1 day'))::int)
           ) as quest_anno
      from public.clienti c
     where c.data_nascita is not null
  ),
  con_prossimo as (
    select base.*,
           case when quest_anno >= current_date
                then quest_anno
                else (quest_anno + interval '1 year')::date
           end as compleanno
      from base
  )
  select id, ragione_sociale, nome, cognome, data_nascita, email, telefono, lingua,
         compleanno,
         (compleanno - current_date)::int as giorni_mancanti,
         (extract(year from compleanno)::int - extract(year from data_nascita)::int) as eta
    from con_prossimo
   where compleanno - current_date <= giorni
   order by compleanno;
$$;
