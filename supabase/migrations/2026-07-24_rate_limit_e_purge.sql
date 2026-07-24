-- ═══════════════════════════════════════════════════════════════════════════
-- Rate limit per gli endpoint pubblici + scadenza degli hash IP — 24/07/2026
--
-- Seguito di `2026-07-24_hardening_sicurezza.sql`. Lì il form dei siti ha
-- preso un limite di 5 invii/ora per IP; restavano scoperti due punti:
--
--   a) la edge function `booking` (camerepse) gira con `verify_jwt=false` e
--      scrive in `prenotazioni` con la service key: chiunque poteva riempire
--      il calendario di prenotazioni finte. Ogni riga finta si trascina
--      dietro pulizie e colazioni generate da `sync_camere_pse()`.
--   b) gli `ip_hash` restavano a vita. Servono per contare, non per
--      archiviare: dopo 24 ore non dicono più niente di utile.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── Contatore condiviso dagli endpoint pubblici ───────────────────────────
--
-- Sta a parte da `prenotazioni` di proposito: quella è una tabella di lavoro
-- sincronizzata con Beds24, non il posto dove tenere la contabilità degli
-- abusi. Qui dentro non c'è nessun IP in chiaro, solo il suo hash con sale.

create table if not exists public.web_rate_limit (
  id         bigserial primary key,
  scope      text        not null,   -- 'booking', 'solicitud', …
  ip_hash    text        not null,
  created_at timestamptz not null default now()
);

alter table public.web_rate_limit enable row level security;
-- Nessuna policy: ci arriva solo la service key, come per il resto del CRM.

create index if not exists web_rate_limit_lookup_idx
  on public.web_rate_limit (scope, ip_hash, created_at desc);

revoke all on public.web_rate_limit          from anon, authenticated;
revoke all on sequence public.web_rate_limit_id_seq from anon, authenticated;


-- ── Gli hash IP scadono dopo 24 ore ───────────────────────────────────────
--
-- La finestra del rate limit è un'ora: tenerli un giorno è già abbondante e
-- lascia margine per capire un eventuale attacco il mattino dopo. Oltre,
-- sarebbero solo dati personali (pseudonimi, ma pur sempre tali) conservati
-- senza uno scopo.

create or replace function public.purge_ip_hash()
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.solicitudes_web
     set ip_hash = null
   where ip_hash is not null
     and created_at < now() - interval '24 hours';

  delete from public.web_rate_limit
   where created_at < now() - interval '24 hours';
$$;

revoke all on function public.purge_ip_hash() from public, anon, authenticated;

select cron.unschedule('purge-ip-hash')
 where exists (select 1 from cron.job where jobname = 'purge-ip-hash');

select cron.schedule('purge-ip-hash', '20 4 * * *', 'select public.purge_ip_hash();');
