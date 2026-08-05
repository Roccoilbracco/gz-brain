-- ============================================================================
-- La chiave service_role non sta più in chiaro dentro cron.job.command.
-- Vive nel Vault (secret 'service_role_key'); i cron la leggono al volo.
-- Ruotarla = una UPDATE sul Vault, non 4 comandi cron da riscrivere a mano.
--
-- Prima di questa migrazione 4 job su 6 avevano il JWT completo nel comando,
-- leggibile da chiunque potesse fare `select * from cron.job`.
-- ============================================================================

-- Il secret va creato una volta con la chiave corrente:
--   select vault.create_secret('<service_role_key>', 'service_role_key',
--          'Chiave service_role usata dai cron per chiamare le edge function.');

create or replace function public.chiama_edge(nome text, corpo jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'vault', 'net'
as $$
declare k text; rid bigint;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'service_role_key';
  if k is null then
    raise exception 'secret service_role_key assente dal Vault: i cron non possono autenticarsi';
  end if;
  select net.http_post(
    url     := 'https://hxxpaicppjwtvoxuuiwm.supabase.co/functions/v1/' || nome,
    headers := jsonb_build_object('Authorization', 'Bearer ' || k,
                                  'Content-Type', 'application/json'),
    body    := corpo
  ) into rid;
  return rid;
end $$;

-- Solo i cron (che girano come postgres) devono poterla chiamare.
revoke all on function public.chiama_edge(text, jsonb) from public, anon, authenticated;

-- I due cron vivi passano dal Vault.
select cron.alter_job(3, command => $cmd$select public.chiama_edge('social-insights', '{"mode":"suggestions"}'::jsonb);$cmd$);
select cron.alter_job(4, command => $cmd$select public.chiama_edge('social-insights', '{"mode":"audit"}'::jsonb);$cmd$);

-- I due cron Beds24 erano disattivi da quando l'integrazione è stata dismessa
-- (le prenotazioni OTA si inseriscono a mano) e si portavano dietro la chiave
-- in chiaro. Definizione originale conservata qui per storia:
--   beds24-sync-20min  */20 * * * *      POST /functions/v1/beds24-sync          body {}
--   beds24-push-20min  10,30,50 * * * *  POST /functions/v1/beds24-push?apply=1  body {}
select cron.unschedule(1);
select cron.unschedule(6);
