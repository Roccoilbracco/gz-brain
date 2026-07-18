-- ─────────────────────────────────────────────────────────────────────────────
-- re_leads: messaggio della richiesta separato dalle note interne
--
-- Come su Wallis (solicitudes_web.mensaje vs .notas): il testo scritto dal
-- cliente nel form resta immutabile in request_message, mentre notes torna a
-- essere il campo libero per le note interne (drawer del kanban, agente WhatsApp).
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.re_leads add column if not exists request_message text;

-- Il trigger del form gz-ibiza scrive il messaggio in request_message, non in notes
create or replace function public.solicitud_web_to_re_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sitio is distinct from 'gz-ibiza' then
    return new;
  end if;

  insert into public.re_leads (name, phone, email, source, stage, request_message, solicitud_id, created_at)
  values (
    nullif(btrim(concat_ws(' ', nullif(btrim(new.nombre), ''), nullif(btrim(new.apellido), ''))), ''),
    nullif(btrim(new.telefono), ''),
    nullif(btrim(new.email), ''),
    'sito',
    'nuovo',
    nullif(btrim(new.mensaje), ''),
    new.id,
    new.created_at
  )
  on conflict (solicitud_id) where (solicitud_id is not null) do nothing;

  return new;
exception when others then
  -- mai bloccare l'invio del form del sito per un problema di sync
  return new;
end;
$$;

-- Lead già arrivati dal sito: sposta il messaggio da notes a request_message
update public.re_leads
   set request_message = notes, notes = null
 where solicitud_id is not null
   and request_message is null
   and notes is not null;
