-- Cron del modulo Social di NCREATIVE.
-- Chiama l'Edge Function `social-insights`: suggerimenti ogni notte, audit il
-- primo del mese. Il token non sta qui dentro — viene riletto dal job beds24,
-- che è già schedulato con la service_role key, così questo file resta
-- committabile senza segreti.
do $$
declare
  tok text;
  url text := 'https://hxxpaicppjwtvoxuuiwm.supabase.co/functions/v1/social-insights';
begin
  select (regexp_match(command, 'Bearer ([A-Za-z0-9._-]+)'))[1] into tok
    from cron.job where jobname = 'beds24-sync-20min';
  if tok is null then
    raise exception 'token non trovato: schedula prima beds24-sync-20min, o incolla qui la service_role key';
  end if;

  perform cron.unschedule('nc-social-suggestions')
    where exists (select 1 from cron.job where jobname = 'nc-social-suggestions');
  perform cron.unschedule('nc-social-audit')
    where exists (select 1 from cron.job where jobname = 'nc-social-audit');

  -- 05:30 UTC (07:30 in Spagna d'estate): la dashboard è pronta a colazione
  perform cron.schedule('nc-social-suggestions', '30 5 * * *', format($f$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Authorization', 'Bearer %s', 'Content-Type', 'application/json'),
      body := '{"mode":"suggestions"}'::jsonb
    );
  $f$, url, tok));

  -- primo del mese: l'audit copre il mese appena chiuso (la funzione ricava il
  -- periodo dal giorno precedente)
  perform cron.schedule('nc-social-audit', '0 6 1 * *', format($f$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Authorization', 'Bearer %s', 'Content-Type', 'application/json'),
      body := '{"mode":"audit"}'::jsonb
    );
  $f$, url, tok));
end $$;
