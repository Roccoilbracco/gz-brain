-- Higiene dopo l'apertura del repo: il trigger che normalizza la categoria dei
-- movimenti girava senza `search_path` fissato. È SECURITY INVOKER, quindi non
-- era una scalata di privilegi; ma con il path fissato smette di dipendere da
-- quello che si porta dietro la sessione che lo fa scattare.
--
-- `create or replace` conserva l'oid della funzione: il trigger
-- `movimenti_categoria_normalizzata` su public.movimenti resta agganciato.
create or replace function public.movimenti_normalizza_categoria()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  new.categoria := nullif(btrim(lower(new.categoria)), '');
  return new;
end;
$function$;
