#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# Toglie dal bucket PUBBLICO `proprieta` i file finiti sotto <propId>/docs/.
#
# Fino al 24/07/2026 i documenti venivano caricati lì: chiunque indovinasse
# l'URL li scaricava senza chiave. Da adesso vanno in `proprieta-docs`, che è
# privato. Restano da togliere i file caricati prima — al momento tre di
# prova (un PDF segnaposto, una piantina e una visura demo).
#
# Il DELETE diretto su storage.objects è vietato da Supabase (lascerebbe byte
# orfani), quindi si passa dalla Storage API. Serve la service key, la stessa
# che usa GZ Brain: si legge dal suo config.json, non si scrive da nessuna
# parte e non compare negli argomenti dei processi.
#
#   ./scripts/pulizia-docs-pubblici.sh          # elenca soltanto
#   ./scripts/pulizia-docs-pubblici.sh --elimina
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONFIG="$HOME/Library/Application Support/dev.gz.brain/config.json"
[[ -f "$CONFIG" ]] || { echo "config.json non trovato: $CONFIG" >&2; exit 1; }

URL=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["supabase_url"])' "$CONFIG")
KEY=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["supabase_secret_key"])' "$CONFIG")

# La Storage API elenca una cartella alla volta: prima le cartelle di primo
# livello (una per immobile), poi i file dentro <propId>/docs.
elenca_cartelle() {
  curl -s -X POST "$URL/storage/v1/object/list/proprieta" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"prefix":"","limit":1000}' |
  /usr/bin/python3 -c 'import json,sys;[print(o["name"]) for o in json.load(sys.stdin) if o.get("id") is None]'
}

elenca_docs() {
  local prop="$1"
  curl -s -X POST "$URL/storage/v1/object/list/proprieta" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"prefix\":\"$prop/docs\",\"limit\":1000}" |
  /usr/bin/python3 -c "
import json,sys
for o in json.load(sys.stdin):
    if o.get('id'): print('$prop/docs/' + o['name'])
"
}

TROVATI=()
while IFS= read -r prop; do
  [[ -z "$prop" ]] && continue
  while IFS= read -r doc; do
    [[ -n "$doc" ]] && TROVATI+=("$doc")
  done < <(elenca_docs "$prop")
done < <(elenca_cartelle)

if [[ ${#TROVATI[@]} -eq 0 ]]; then
  echo "Nessun documento nel bucket pubblico. Tutto a posto."
  exit 0
fi

echo "Documenti ancora nel bucket PUBBLICO (${#TROVATI[@]}):"
printf '  %s\n' "${TROVATI[@]}"

if [[ "${1:-}" != "--elimina" ]]; then
  echo
  echo "Solo elenco. Per rimuoverli davvero: $0 --elimina"
  exit 0
fi

echo
for doc in "${TROVATI[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    "$URL/storage/v1/object/proprieta/$doc" -H "Authorization: Bearer $KEY")
  echo "  [$code] $doc"
done
echo "Fatto."
