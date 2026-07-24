-- ═══════════════════════════════════════════════════════════════════════════
-- Hardening sicurezza — 24/07/2026
--
-- Contesto: la chiave pubblicabile (`sb_publishable_…`) è dentro il bundle JS
-- dei siti e nel binario iOS. È pubblica per design: chi vede cosa lo devono
-- decidere RLS, GRANT e policy. L'audit ha trovato quattro punti in cui non
-- era così. Qui si chiudono, senza toccare una riga dei siti.
--
--   1. `sync_camere_pse()` eseguibile da chiunque, e scriveva sul DB.
--   2. `anon` leggeva TUTTE le colonne di `proprieta` (address, rif_catastale,
--      fatturato_annuo…), non solo quelle da vetrina.
--   3. `solicitudes_web` accettava INSERT anonimi illimitati e senza vincoli.
--   4. I documenti finivano nel bucket PUBBLICO `proprieta`.
--
-- Principio applicato ovunque: RLS decide le RIGHE, i GRANT decidono le
-- COLONNE. Le due cose insieme reggono anche se una policy futura sbaglia.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. RPC: niente esecuzione dall'esterno ────────────────────────────────
--
-- Le funzioni trigger non hanno bisogno di EXECUTE per scattare (Postgres
-- controlla il privilegio alla CREATE TRIGGER, non a ogni riga), quindi
-- toglierlo non rompe nulla: chiude solo la porta /rest/v1/rpc/<nome>.

revoke all on function public.sync_camere_pse()          from public, anon, authenticated;
revoke all on function public.rls_auto_enable()          from public, anon, authenticated;
revoke all on function public.solicitud_web_to_re_lead() from public, anon, authenticated;
revoke all on function public.sync_lead_cliente()        from public, anon, authenticated;
revoke all on function public.sync_re_lead_cliente()     from public, anon, authenticated;

-- GZ Brain (macOS) e i cron girano con la service key: a loro serve.
grant execute on function public.sync_camere_pse() to service_role;

-- Il portale proprietari resta la API dell'app iOS, ma solo da loggati.
revoke all on function public.owner_proprieta()          from public, anon;
revoke all on function public.owner_documenti(uuid)      from public, anon;
revoke all on function public.owner_offerte(uuid)        from public, anon;
revoke all on function public.owner_visite(uuid)         from public, anon;
revoke all on function public.owns_proprieta(uuid)       from public, anon;
revoke all on function public.is_staff()                 from public, anon;
revoke all on function public.app_role()                 from public, anon;

-- `is_staff()` e `app_role()` sono chiamate DENTRO le policy RLS: senza
-- EXECUTE esplicito a `authenticated` lo staff non leggerebbe più nulla.
grant execute on function public.owner_proprieta()     to authenticated;
grant execute on function public.owner_documenti(uuid) to authenticated;
grant execute on function public.owner_offerte(uuid)   to authenticated;
grant execute on function public.owner_visite(uuid)    to authenticated;
grant execute on function public.owns_proprieta(uuid)  to authenticated;
grant execute on function public.is_staff()            to authenticated;
grant execute on function public.app_role()            to authenticated;

-- search_path mutabile = un utente può dirottare i nomi non qualificati.
alter function public.prossimi_compleanni(integer) set search_path = public;


-- ── 2. `anon` non scrive da nessuna parte, e legge solo la vetrina ────────
--
-- Oggi le scritture anonime sono già bloccate da RLS. Togliere anche il
-- GRANT è la seconda serratura: se un domani si aggiunge per sbaglio una
-- policy permissiva, il privilegio manca comunque e l'INSERT viene rifiutato.

do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format(
      'revoke select, insert, update, delete, truncate, references, trigger on public.%I from anon',
      t.tablename);
  end loop;
end $$;

-- Le uniche colonne di `proprieta` che il pubblico può vedere: quelle che i
-- siti gz-ibiza e wallis-57 mettono davvero in pagina. Restano FUORI, e da
-- adesso rispondono 403 anche se qualcuno le chiede a mano:
--   address, latitude, longitude  → l'indirizzo esatto non è da vetrina
--   rif_catastale, idealista_cod  → riferimenti interni
--   fatturato_annuo               → il fatturato di un'attività in vendita
--   category, scheda_tipo, updated_at, desc_zh, desc_tradotte_at
grant select (
  id, title, reference, zone, city, property_type, listing_type,
  price, price_rent, bedrooms, bathrooms, size_sqm, photos, status,
  site_visibility, created_at,
  desc_es, desc_en, desc_it, notes,
  sup_utile, sup_costruita, terrazza_mq, piano, anno_costruzione,
  stato_conserv, cert_energetico, disponibile_da, arredato, vista,
  orientamento, posti_auto, giardino_mq, facciata_ml, altezza_libera,
  vetrine, servizi_igienici, licenza_attivita, capienza, tavoli_terrazza,
  attivita_attuale, anni_contratto, spese_condominio, ibi_annuale, cauzione,
  climatizzazione, riscaldamento, ascensore, piscina, ripostiglio,
  magazzino, uscita_fumi, terrazza_autorizzata, cucina_industriale,
  cella_frigorifera
) on public.proprieta to anon;

comment on column public.proprieta.notes is
  'Testo dell''annuncio, PUBBLICO: i siti lo pubblicano come descrizione. '
  'Le note interne (margini, trattative, dati del proprietario) NON vanno qui.';


-- ── 3. `solicitudes_web`: il form pubblico, ma con le briglie ─────────────

-- 3a. Solo le colonne del form. `estado` e `notas` sono di GZ Brain: chi
--     manda il modulo non può marcarsi la richiesta come già lavorata.
grant insert (nombre, apellido, telefono, email, mensaje, origen, sitio)
  on public.solicitudes_web to anon;

-- 3b. Vincoli di forma — valgono per tutti, anche per la service key.
alter table public.solicitudes_web
  drop constraint if exists solicitudes_web_lunghezze,
  add  constraint solicitudes_web_lunghezze check (
        char_length(nombre)                    between 1 and 120
    and char_length(coalesce(apellido, ''))    <= 120
    and char_length(coalesce(telefono, ''))    <= 40
    and char_length(email)                     between 5 and 200
    and char_length(coalesce(mensaje, ''))     <= 5000
    and char_length(coalesce(notas, ''))       <= 5000
  );

-- `not valid`: vale su ogni INSERT e UPDATE da adesso, ma non rifiuta le due
-- richieste di prova del 18 e 23/07 (una ha l'email `aa@aait`). Vanno bene
-- così: sono dati veri del tuo storico, non li riscrive una migration.
alter table public.solicitudes_web
  drop constraint if exists solicitudes_web_email_valida,
  add  constraint solicitudes_web_email_valida check (
    email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'
  ) not valid;

-- 3c. La policy non è più `with check (true)`: il sito e l'origine devono
--     essere quelli previsti. `sitio` decide se scatta il trigger che crea
--     il lead in `re_leads`, quindi era la leva per inquinare la pipeline.
drop policy if exists "web anon insert" on public.solicitudes_web;
create policy "web anon insert" on public.solicitudes_web
  for insert to anon
  with check (
        sitio  in ('gz-ibiza', 'wallis-57')
    and origen in ('web', 'vender')
    and estado = 'nuevo'
    and notas is null
  );

-- 3d. Rate limit per IP. L'IP arriva da PostgREST negli header di richiesta;
--     si salva solo l'hash con sale (non è un dato personale in chiaro) e
--     serve unicamente a contare. La service key è esente: GZ Brain e le
--     edge function devono poter inserire senza limiti.
alter table public.solicitudes_web add column if not exists ip_hash text;
create index if not exists solicitudes_web_ip_hash_idx
  on public.solicitudes_web (ip_hash, created_at desc);

create or replace function public.solicitudes_web_rate_limit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  rol      text := coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '');
  ip       text := split_part(
                     coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
                     ',', 1);
  recenti  int;
begin
  if rol = 'service_role' then
    return new;
  end if;

  if btrim(ip) = '' then          -- SQL diretto / cron: nessun IP da contare
    return new;
  end if;

  new.ip_hash := encode(extensions.digest('gz-brain|' || btrim(ip), 'sha256'), 'hex');

  select count(*) into recenti
    from public.solicitudes_web s
   where s.ip_hash = new.ip_hash
     and s.created_at > now() - interval '1 hour';

  -- `PT429`: PostgREST traduce i codici PTxxx nello stato HTTP xxx, così il
  -- sito riceve un 429 "troppe richieste" e non un 500 da errore interno.
  if recenti >= 5 then
    raise exception 'Demasiadas solicitudes desde esta conexión. Inténtalo más tarde.'
      using errcode = 'PT429';
  end if;

  return new;
end $$;

revoke all on function public.solicitudes_web_rate_limit() from public, anon, authenticated;

drop trigger if exists solicitudes_web_rate_limit on public.solicitudes_web;
create trigger solicitudes_web_rate_limit
  before insert on public.solicitudes_web
  for each row execute function public.solicitudes_web_rate_limit();


-- ── 4. Documenti fuori dal bucket pubblico ────────────────────────────────
--
-- Le FOTO restano pubbliche: i siti le servono senza chiave, è corretto.
-- I DOCUMENTI (contratti, planimetrie, visure) passano in un bucket privato,
-- raggiungibile solo con URL firmato da chi ha diritto di vederlo.

insert into storage.buckets (id, name, public)
values ('proprieta-docs', 'proprieta-docs', false)
on conflict (id) do nothing;

-- Lo staff gestisce tutto.
drop policy if exists "docs staff all" on storage.objects;
create policy "docs staff all" on storage.objects
  for all to authenticated
  using      (bucket_id = 'proprieta-docs' and public.is_staff())
  with check (bucket_id = 'proprieta-docs' and public.is_staff());

-- Il proprietario scarica SOLO i documenti marcati visibili delle SUE
-- proprietà. Il percorso non basta come prova: si passa dalla riga in
-- `proprieta_documenti`, che è la fonte di verità su chi può vedere cosa.
drop policy if exists "docs owner read" on storage.objects;
create policy "docs owner read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'proprieta-docs'
    and exists (
      select 1 from public.proprieta_documenti d
       where d.path = storage.objects.name
         and d.visibile_proprietario
         and public.owns_proprieta(d.proprieta_id)
    )
  );

-- I tre file di prova caricati il 17/07 sotto `<propId>/docs/` nel bucket
-- pubblico (un PDF segnaposto, una piantina e una visura demo) NON si
-- cancellano da qui: Supabase vieta il DELETE diretto su storage.objects
-- per non lasciare byte orfani. Vanno tolti con la Storage API — vedi
-- `scripts/pulizia-docs-pubblici.sh`.
