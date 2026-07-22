-- Campi specifici del proprietario/inquilino che offre un immobile in gestione.
alter table public.re_owners
  add column if not exists property_offered text,      -- che immobile offre (descrizione)
  add column if not exists size_sqm       integer,     -- m²
  add column if not exists has_license    boolean,     -- ha licenza (sì/no/—)
  add column if not exists license_type   text,        -- tipo di licenza
  add column if not exists three_phase    boolean;      -- installazione trifase (sì/no/—)
