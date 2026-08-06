-- ============================================================================
-- L'estratto conto della banca si aggancia al conto di tesoreria.
--
-- `storico_banca.conto` è testo libero — «Affittacamere Massimo 4509110» —
-- nato dagli import. Per aprire l'estratto dalla scheda di un conto serve un
-- aggancio stabile: l'etichetta può cambiare al prossimo import, l'id no.
--
-- Restano fuori i conti che non sono delle camere: il conto personale di
-- Giorgio (BPER 42919934) non è tesoreria di Porto Sant'Elpidio e in `conti`
-- non esiste. La cassa contante non ha estratto perché non ha banca.
--
-- Massimo e Giacomo non hanno il saldo progressivo: le liste movimenti BPER
-- non lo esportano. Non è un buco da tappare qui — la quadratura notturna lo
-- segnala già come «saldo assente», ed è corretto che lo faccia.
-- ============================================================================

alter table public.storico_banca
  add column if not exists conto_id text references public.conti(id);

update public.storico_banca set conto_id = case
    when conto like 'Affittacamere Massimo%' then 'massimo'
    when conto like 'Anastasi Giacomo%'      then 'beeper'
    when conto like 'Carifermo%'             then 'carifermo'
  end
 where conto_id is null;

create index if not exists storico_banca_conto_id_idx
  on public.storico_banca (conto_id, data);

comment on column public.storico_banca.conto_id is
  'Conto di tesoreria (public.conti) a cui appartiene la riga. La colonna `conto` resta come etichetta dell''import di provenienza.';
