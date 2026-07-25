-- Cancellare una prenotazione non era un'operazione sola: si metteva lo stato a
-- «cancellata» e restavano in giro la pulizia prevista, le colazioni Booking e
-- l'incasso che la sincronizzazione aveva già portato in cassa. I conti di
-- Tesoreria continuavano a contarli. Questa funzione fa tutto in un colpo.
--
-- Cosa NON tocca, per scelta:
--  • le pulizie già «fatta» e le colazioni già servite: sono costi sostenuti
--    davvero, cancellarli falserebbe il consuntivo;
--  • i movimenti inseriti a mano collegati alla prenotazione: quelli sono soldi
--    che qualcuno ha visto passare, li decide l'utente in Tesoreria. Li conta
--    soltanto, e li riporta indietro perché l'app possa dirlo.
-- Lo sblocco del calendario OTA lo fa già beds24-push al giro successivo:
-- guarda le prenotazioni con status «cancellata» e un beds24_block_id.

create or replace function public.annulla_prenotazione(
  p_id uuid,
  p_stralcia_incasso boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.prenotazioni%rowtype;
  n_pul int := 0; n_col int := 0; n_mov int := 0;
  pul_tenute int := 0; col_tenute int := 0; mov_manuali int := 0;
  incasso_prima int := 0;
begin
  select * into v from public.prenotazioni where id = p_id;
  if not found then
    return jsonb_build_object('errore', 'prenotazione inesistente');
  end if;
  incasso_prima := coalesce(v.paid_cents, 0);

  update public.prenotazioni
     set status = 'cancellata', updated_at = now()
   where id = p_id;

  delete from public.pulizie
   where prenotazione_id = p_id and coalesce(stato, '') <> 'fatta';
  get diagnostics n_pul = row_count;
  select count(*) into pul_tenute from public.pulizie where prenotazione_id = p_id;

  delete from public.colazioni
   where prenotazione_id = p_id and coalesce(notti_servite, 0) = 0;
  get diagnostics n_col = row_count;
  select count(*) into col_tenute from public.colazioni where prenotazione_id = p_id;

  -- L'incasso generato dalla sincronizzazione ha una ext_key deterministica:
  -- è l'unico movimento che questa funzione si permette di togliere.
  if p_stralcia_incasso then
    delete from public.movimenti
     where prenotazione_id = p_id and ext_key = 'pren:' || p_id::text;
    get diagnostics n_mov = row_count;
    update public.prenotazioni
       set paid_cents = 0, cassa_registrata = false, updated_at = now()
     where id = p_id;
  end if;

  select count(*) into mov_manuali
    from public.movimenti
   where prenotazione_id = p_id
     and coalesce(ext_key, '') <> 'pren:' || p_id::text;

  return jsonb_build_object(
    'ospite', v.guest_name,
    'pulizie_rimosse', n_pul,
    'pulizie_tenute', pul_tenute,
    'colazioni_rimosse', n_col,
    'colazioni_tenute', col_tenute,
    'incasso_stralciato_cents', case when n_mov > 0 then incasso_prima else 0 end,
    'incasso_azzerato', p_stralcia_incasso and incasso_prima > 0,
    'movimenti_manuali_collegati', mov_manuali
  );
end $$;

revoke all on function public.annulla_prenotazione(uuid, boolean) from public, anon, authenticated;
grant execute on function public.annulla_prenotazione(uuid, boolean) to service_role;

comment on function public.annulla_prenotazione(uuid, boolean) is
  'Cancella una prenotazione e ripulisce quello che ne dipende: pulizie non ancora fatte, colazioni non servite e (se richiesto) l''incasso generato dalla sync. Ritorna il riepilogo di cosa ha toccato.';
