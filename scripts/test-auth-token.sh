#!/usr/bin/env bash
# Pide un access token a Auth0 (Resource Owner Password Grant con "realm"
# explícito, solo para pruebas locales) y lo usa contra una ruta protegida
# del Gateway.
#
# Usa el grant type "http://auth0.com/oauth/grant-type/password-realm" en
# vez de "password" a secas: así Auth0 no depende del "Default Directory"
# del tenant para resolver contra qué connection validar al usuario.
#
# "discordia" es una Regular Web Application (confidential client): Auth0
# exige client_secret en el pedido de token para CUALQUIER grant type, no
# solo para client_credentials. Sin esto, Auth0 devuelve un genérico
# {"error":"access_denied","error_description":"Unauthorized"} que no
# distingue esto de una password incorrecta.
#
# Uso:
#   ./scripts/test-auth-token.sh <client_id> <client_secret> <password> [username] [ruta]
#
# También podés setear AUTH0_CLIENT_ID / AUTH0_CLIENT_SECRET / AUTH0_USERNAME
# / AUTH0_PASSWORD / AUTH0_REALM como variables de entorno en vez de
# pasarlas por argumento.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$GATEWAY_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${AUTH0_DOMAIN:?Falta AUTH0_DOMAIN (revisá $ENV_FILE)}"
: "${AUTH0_AUDIENCE:?Falta AUTH0_AUDIENCE (revisá $ENV_FILE)}"

AUTH0_CLIENT_ID="${AUTH0_CLIENT_ID:-${1:-}}"
AUTH0_CLIENT_SECRET="${AUTH0_CLIENT_SECRET:-${2:-}}"
AUTH0_PASSWORD="${AUTH0_PASSWORD:-${3:-}}"
AUTH0_USERNAME="${AUTH0_USERNAME:-${4:-tester@discordia.com}}"
GATEWAY_ROUTE="${GATEWAY_ROUTE:-${5:-/api/v1/users}}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"
AUTH0_REALM="${AUTH0_REALM:-Username-Password-Authentication}"

if [[ -z "$AUTH0_CLIENT_ID" || -z "$AUTH0_CLIENT_SECRET" || -z "$AUTH0_PASSWORD" ]]; then
  echo "Uso: $0 <client_id> <client_secret> <password> [username] [ruta]" >&2
  echo "  (o exportá AUTH0_CLIENT_ID / AUTH0_CLIENT_SECRET / AUTH0_PASSWORD / AUTH0_USERNAME antes de correrlo)" >&2
  exit 1
fi

echo "== 1. Pidiendo token a Auth0 (${AUTH0_DOMAIN}) para ${AUTH0_USERNAME} ==" >&2

set +e
RESPONSE="$(python3 - "$AUTH0_DOMAIN" "$AUTH0_CLIENT_ID" "$AUTH0_CLIENT_SECRET" "$AUTH0_USERNAME" "$AUTH0_PASSWORD" "$AUTH0_AUDIENCE" "$AUTH0_REALM" <<'PY'
import sys, json, urllib.request, urllib.error

domain, client_id, client_secret, username, password, audience, realm = sys.argv[1:8]
body = json.dumps({
    "client_id": client_id,
    "client_secret": client_secret,
    "grant_type": "http://auth0.com/oauth/grant-type/password-realm",
    "username": username,
    "password": password,
    "audience": audience,
    "scope": "openid profile email",
    "realm": realm,
}).encode()

req = urllib.request.Request(
    f"https://{domain}/oauth/token",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode())
    sys.exit(2)
PY
)"
STATUS=$?
set -e

echo "$RESPONSE" | python3 -m json.tool >&2 2>/dev/null || echo "$RESPONSE" >&2

if [[ $STATUS -ne 0 ]]; then
  echo "== Auth0 devolvió un error (ver JSON arriba). Abortando. ==" >&2
  exit 1
fi

TOKEN="$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")"

if [[ -z "$TOKEN" ]]; then
  echo "== No vino access_token en la respuesta. Ver JSON arriba. ==" >&2
  exit 1
fi

echo "== 2. Token OK. Probando ${GATEWAY_URL}${GATEWAY_ROUTE} ==" >&2
curl -i -H "Authorization: Bearer $TOKEN" "${GATEWAY_URL}${GATEWAY_ROUTE}"
echo
