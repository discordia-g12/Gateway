#!/bin/sh
# Completa los destinos de kong.yml (plantilla) con variables de entorno y arranca Kong.
# Los defaults son los nombres del compose local (todo en una misma red de Docker); en producción
# cada nodo los pisa con las IPs privadas de los otros nodos (ver deploy/edge/.env.example).
set -eu

: "${AUTH_SERVICE_URL:=http://auth-service:8000}"
: "${SERVER_ROLES_URL:=http://server-roles-service:8080}"
: "${PAYMENTS_URL:=http://payments-service:8000}"
: "${CHAT_ENGINE_URL:=http://chat-engine-service:3000}"
: "${VOICE_SIGNALING_URL:=http://voice-signaling-service:8080}"
: "${NOTIFICATION_URL:=http://notification-service:3000}"
: "${LIVEKIT_SIGNALING_URL:=http://livekit:7880}"

TEMPLATE=/etc/kong/kong.yml.tmpl
OUTPUT="${KONG_DECLARATIVE_CONFIG:-/tmp/kong.yml}"

sed \
  -e "s|\${AUTH_SERVICE_URL}|${AUTH_SERVICE_URL}|g" \
  -e "s|\${SERVER_ROLES_URL}|${SERVER_ROLES_URL}|g" \
  -e "s|\${PAYMENTS_URL}|${PAYMENTS_URL}|g" \
  -e "s|\${CHAT_ENGINE_URL}|${CHAT_ENGINE_URL}|g" \
  -e "s|\${VOICE_SIGNALING_URL}|${VOICE_SIGNALING_URL}|g" \
  -e "s|\${NOTIFICATION_URL}|${NOTIFICATION_URL}|g" \
  -e "s|\${LIVEKIT_SIGNALING_URL}|${LIVEKIT_SIGNALING_URL}|g" \
  "$TEMPLATE" > "$OUTPUT"

# Si queda alguna variable sin completar no arranca. Solo se miran líneas que no son comentarios
# (el encabezado de kong.yml menciona ${...}).
if grep -n '^[^#]*\${' "$OUTPUT"; then
  echo "render-config: quedaron variables sin completar en $OUTPUT" >&2
  exit 1
fi

exec /docker-entrypoint.sh "$@"
