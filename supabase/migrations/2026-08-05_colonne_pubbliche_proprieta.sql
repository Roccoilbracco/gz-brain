-- ============================================================================
-- La policy anon su `proprieta` («anon read proprieta pubblicate») filtra le
-- RIGHE ma non le COLONNE: da sola darebbe accesso a tutti i 69 campi.
-- A proteggere i campi interni sono i GRANT per colonna, che erano già
-- corretti. Qui vengono resi espliciti e documentati, così chi tocca i grant
-- in futuro sa cosa sta aprendo.
--
-- Leggibile da anon (57 colonne): dati da vetrina + descrizioni + foto/video.
-- Negato ad anon: address, latitude, longitude, rif_catastale,
--                 fatturato_annuo, owner_id, idealista_cod.
-- ============================================================================

comment on column public.proprieta.notes is
  'PUBBLICO: leggibile da chiunque abbia la publishable key sulle righe con pubblicata=true. Contiene il testo dell''annuncio (Idealista). NON scrivere qui trattative, margini o dati del proprietario.';
comment on column public.proprieta.address is
  'INTERNO: grant negato ad anon. Indirizzo esatto.';
comment on column public.proprieta.latitude is 'INTERNO: grant negato ad anon.';
comment on column public.proprieta.longitude is 'INTERNO: grant negato ad anon.';
comment on column public.proprieta.rif_catastale is 'INTERNO: grant negato ad anon.';
comment on column public.proprieta.fatturato_annuo is 'INTERNO: grant negato ad anon. Fatturato del negozio.';
comment on column public.proprieta.owner_id is 'INTERNO: grant negato ad anon.';

-- Cintura oltre alle bretelle: se un domani qualcuno fa GRANT SELECT su tutta
-- la tabella ad anon, questi restano comunque fuori.
revoke select (address, latitude, longitude, rif_catastale, fatturato_annuo, owner_id, idealista_cod)
  on public.proprieta from anon;
