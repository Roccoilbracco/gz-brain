-- ═══════════════════════════════════════════════════════════════════════════
-- Generazione documenti — GZ Ibiza
--
-- Finora l'archivio teneva due cose: i modelli in bianco (PDF caricati) e le
-- copie firmate. Fra le due manca il pezzo di lavoro vero: prendere il
-- borrador giusto, metterci dentro proprietario, immobile, cliente e le
-- condizioni economiche definitive, e tirarne fuori il documento da firmare.
--
-- Un PDF caricato non si può riempire. Quindi il borrador diventa TESTO con
-- segnaposto {{...}} — si scrive una volta, si riempie ogni volta.
--
--   doc_borradores  → il testo del contratto tipo, con i segnaposto
--   documenti.tipo  → guadagna 'generato': il documento uscito dal borrador,
--                     già agganciato a proprietario, immobile e cliente,
--                     con dentro i dati con cui è stato prodotto (dati jsonb),
--                     così si può rigenerare identico o correggere un numero.
--   proprieta.owner_id → quale proprietario (re_owners) possiede l'immobile.
--                     Serviva per la regola «se ne ha uno solo, non lo chiedo».
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. Il proprietario dell'immobile ─────────────────────────────────────────
--
-- `proprieta_proprietari` resta la catena storica (chi lo ha posseduto e
-- quando): è due diligence. Questo invece è il collegamento vivo con la
-- pipeline proprietari — chi firma l'encargo, chi incassa l'affitto.
alter table public.proprieta
  add column if not exists owner_id uuid references public.re_owners(id) on delete set null;

create index if not exists proprieta_owner_idx on public.proprieta (owner_id);


-- ── 2. I borradores ──────────────────────────────────────────────────────────
create table if not exists public.doc_borradores (
  id          uuid primary key default gen_random_uuid(),
  progetto    text not null default 'gz-ibiza',
  categoria   text not null default 'altro',   -- encargo | alquiler | venta | reserva | traspaso | …
  nome        text not null,
  lingua      text not null default 'es',      -- es | it | en
  corpo       text not null default '',        -- testo con i segnaposto {{...}}
  note        text,
  archiviato  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists doc_borradores_prog_idx
  on public.doc_borradores (progetto, categoria, archiviato);

alter table public.doc_borradores enable row level security;
-- Nessuna policy: come `documenti`, ci entra solo la service key (GZ Brain).
-- Sono contratti in bozza con le condizioni economiche dentro.


-- ── 3. Il documento generato ─────────────────────────────────────────────────
--
-- `dati` tiene la fotografia dei valori usati: senza, un contratto generato è
-- un PDF muto e per cambiare una cifra si ricomincia da capo.
alter table public.documenti
  add column if not exists borrador_id uuid references public.doc_borradores(id) on delete set null,
  add column if not exists dati jsonb,
  add column if not exists generato_il timestamptz;

create index if not exists documenti_tipo_idx on public.documenti (progetto, tipo);


-- ── 4. Due borradores di partenza ────────────────────────────────────────────
--
-- Scheletri, non consulenza legale: vanno letti e adattati prima del primo
-- uso. Servono a far vedere come si scrivono i segnaposto.
insert into public.doc_borradores (progetto, categoria, nome, lingua, corpo, note)
select 'gz-ibiza', 'alquiler', 'Contrato de arrendamiento de vivienda', 'es',
$borrador$# CONTRATO DE ARRENDAMIENTO DE VIVIENDA

En {{lugar}}, a {{fecha}}

## REUNIDOS

De una parte, D./Dña. **{{propietario.nombre}}**, con NIF/NIE {{propietario.nif}} y domicilio en {{propietario.direccion}}, en adelante la PARTE ARRENDADORA.

De otra parte, D./Dña. **{{cliente.nombre}}**, con NIF/NIE {{cliente.nif}} y domicilio en {{cliente.direccion}}, en adelante la PARTE ARRENDATARIA.

Ambas partes se reconocen capacidad legal suficiente para contratar y obligarse, y

## EXPONEN

I. Que la parte arrendadora es propietaria de la vivienda sita en **{{inmueble.direccion}}**{{inmueble.zona_frase}}, con una superficie aproximada de {{inmueble.m2}} m².

II. Que la parte arrendataria está interesada en arrendar dicha vivienda, y ambas partes lo formalizan con arreglo a las siguientes

## CLÁUSULAS

**PRIMERA — Objeto.** La parte arrendadora cede en arrendamiento a la parte arrendataria la vivienda descrita en el expositivo I, que se entrega en buen estado de conservación y uso.

**SEGUNDA — Duración.** El contrato tendrá una duración de {{contrato.duracion}}, con inicio el {{contrato.inicio}} y vencimiento el {{contrato.fin}}, sin perjuicio de las prórrogas previstas en la Ley 29/1994 de Arrendamientos Urbanos.

**TERCERA — Renta.** La renta pactada es de **{{renta.mensual}} al mes**, pagadera por meses anticipados dentro de los siete primeros días de cada mes, mediante transferencia a la cuenta que designe la parte arrendadora.

{{renta.tabla}}

**CUARTA — Actualización.** {{ipc}}

**QUINTA — Fianza.** A la firma del presente contrato la parte arrendataria entrega la cantidad de **{{fianza}}** en concepto de fianza legal, que será depositada conforme a la normativa vigente y devuelta al término del contrato una vez comprobado el estado de la vivienda.

{{garantia}}

{{aval}}

**SEXTA — Gastos y suministros.**

{{gastos.tabla}}

**SÉPTIMA — Conservación.** Las reparaciones necesarias para conservar la vivienda en condiciones de habitabilidad corren a cargo de la parte arrendadora, salvo las derivadas del uso ordinario, que corresponden a la parte arrendataria.

**OCTAVA — Uso.** La vivienda se destinará a domicilio habitual de la parte arrendataria. No podrá subarrendarse ni cederse total o parcialmente sin consentimiento escrito de la parte arrendadora.

{{extras.tabla}}

Y en prueba de conformidad, ambas partes firman el presente contrato por duplicado y a un solo efecto en el lugar y fecha arriba indicados.


LA PARTE ARRENDADORA                    LA PARTE ARRENDATARIA


{{propietario.nombre}}                  {{cliente.nombre}}
$borrador$,
'Scheletro di partenza: leggilo e adattalo prima del primo uso.'
where not exists (
  select 1 from public.doc_borradores
  where progetto = 'gz-ibiza' and nome = 'Contrato de arrendamiento de vivienda');

insert into public.doc_borradores (progetto, categoria, nome, lingua, corpo, note)
select 'gz-ibiza', 'reserva', 'Hoja de reserva de local', 'es',
$borrador$# HOJA DE RESERVA

En {{lugar}}, a {{fecha}}

## PARTES

**Titular / arrendador:** {{propietario.nombre}}, NIF/NIE {{propietario.nif}}, domicilio en {{propietario.direccion}}.

**Reservante:** {{cliente.nombre}}, NIF/NIE {{cliente.nif}}, domicilio en {{cliente.direccion}}.

## INMUEBLE

Local sito en **{{inmueble.direccion}}**{{inmueble.zona_frase}}, referencia {{inmueble.referencia}}, superficie aproximada {{inmueble.m2}} m².

## CONDICIONES DE LA RESERVA

**PRIMERA.** El reservante entrega en este acto la cantidad de **{{garantia.importe}}** en concepto de reserva, que se descontará del primer pago en caso de formalizarse el contrato definitivo.

**SEGUNDA.** El titular retira el inmueble del mercado y se compromete a no ofrecerlo a terceros hasta el {{contrato.inicio}}, fecha límite para la firma del contrato definitivo.

**TERCERA.** Las condiciones económicas acordadas para el contrato definitivo son:

- Renta mensual: **{{renta.mensual}}**
- Duración: {{contrato.duracion}}, con inicio previsto el {{contrato.inicio}}
- Fianza: {{fianza}}

{{renta.tabla}}

**CUARTA — Gastos y suministros del contrato definitivo.**

{{gastos.tabla}}

**QUINTA.** Si la firma no se produce por causa imputable al reservante, la cantidad entregada quedará en poder del titular. Si no se produce por causa imputable al titular, éste devolverá la cantidad recibida.

{{extras.tabla}}

Y en prueba de conformidad firman la presente hoja de reserva.


EL TITULAR                              EL RESERVANTE


{{propietario.nombre}}                  {{cliente.nombre}}
$borrador$,
'Scheletro di partenza: leggilo e adattalo prima del primo uso.'
where not exists (
  select 1 from public.doc_borradores
  where progetto = 'gz-ibiza' and nome = 'Hoja de reserva de local');
