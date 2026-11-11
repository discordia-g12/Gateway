# Discordia — API Gateway

Kong 3.4 en modo DB-less (configuración declarativa): punto de entrada único para el tráfico de los
clientes. Valida los access tokens de Auth0 (RS256 contra la JWKS, con caché y rotación de claves),
inyecta la identidad verificada en headers `X-User-*`, aplica autorización por rol, rate limiting y CORS,
y hace proxy a los microservicios.

Decisiones de diseño: [`docs/ADR-001-API-Gateway.md`](docs/ADR-001-API-Gateway.md),
[`docs/ADR-002-Rol-Staff-Backoffice.md`](docs/ADR-002-Rol-Staff-Backoffice.md) y
[`docs/ADR-003-Rutas-Internas-y-Metricas.md`](docs/ADR-003-Rutas-Internas-y-Metricas.md).

## Requisitos

- Docker.
- Python 3.12 o superior, solo para los tests.
- Un tenant de Auth0 con una API registrada. Los valores del tenant de desarrollo ya están en `.env.example`.

## Levantarlo en local

El Gateway no tiene base de datos: necesita solo su Redis (contadores de rate limiting). Kong busca a Redis
con el nombre `redis` (fijo en `kong.yml`), así que los dos van en una misma red de Docker y Redis lleva
ese alias.

```bash
cp .env.example .env
docker build -t discordia-gateway .

docker network create discordia-gateway
docker run -d --name gateway-redis --network discordia-gateway --network-alias redis redis:7-alpine
docker run -d --name gateway --network discordia-gateway --env-file .env \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  -p 8000:8000 -p 127.0.0.1:8001:8001 -p 127.0.0.1:8100:8100 discordia-gateway
```

Probarlo:

```bash
curl -i localhost:8000/livez                  # 200 {"status":"OK","service":"API Gateway"}
curl -i localhost:8000/api/v1/users/me        # 401 Missing token
curl -s localhost:8001/routes | head -c 300   # Admin API: rutas cargadas
curl -s localhost:8100/metrics | head          # Status API: métricas de Prometheus
```

Sin los servicios corriendo, una ruta con token válido responde `503`: Kong no encuentra el destino. Para
apuntar a un servicio que corre en el host, pasar su URL al arrancar (ver la tabla de variables), por
ejemplo `-e CHAT_ENGINE_URL=http://host.docker.internal:3000`.

Kong carga la configuración al arrancar: después de cambiar `kong.yml`, un `.lua` o `nginx/`, reconstruir
la imagen y recrear el contenedor:

```bash
docker rm -f gateway && docker build -t discordia-gateway . && docker run ...   # el mismo run de arriba
```

Bajar todo: `docker rm -f gateway gateway-redis && docker network rm discordia-gateway`.

### Con el resto del sistema

Para levantar el Gateway junto con todos los servicios, usar el compose del orquestador
(`discordia-orchestrator/deploy/docker-compose.yml`, profile `local`). Ahí el Gateway escucha en
`localhost:8000` (HTTP) y `localhost:8443` (TLS autofirmado), y le llega a cada servicio por su nombre o
por la IP del host.

## Cómo arranca

`kong.yml` es una **plantilla**: los destinos de los servicios (`url: ${CHAT_ENGINE_URL}`, etc.) los completa
`render-config.sh`, que es el entrypoint de la imagen. Si queda alguna variable sin completar, el contenedor
no arranca. La imagen trae `kong.yml`, los módulos `.lua` y `nginx/`: cada nodo corre exactamente lo que se
probó.

## Variables de entorno

| Variable | Default | Descripción |
|----------|---------|-------------|
| `AUTH0_DOMAIN` | — (requerida) | Dominio del tenant (`dev-dppme5iaqg60gkmo.us.auth0.com`). De él salen el issuer (`https://<dominio>/`) y la JWKS (`/.well-known/jwks.json`) |
| `AUTH0_AUDIENCE` | — (requerida) | Identifier de la API en Auth0 (`https://api.discordia.com`). Tiene que coincidir con el `audience` que piden web y mobile. Si falta alguna de las dos, las rutas protegidas responden `500 Gateway misconfigured` |
| `AUTH0_ROLE_CLAIM` | `https://discordia.app/role` | Claim con el rol (`user` o `staff`) |
| `AUTH0_EMAIL_CLAIM` | `https://discordia.app/email` | Claim con el email. Si no viene, se usa `email` |
| `AUTH0_EMAIL_VERIFIED_CLAIM` | `https://discordia.app/email_verified` | Claim de verificación. Si no viene, se usa `email_verified` |
| `GATEWAY_REDIS_HOST` / `GATEWAY_REDIS_PORT` | `redis` / `6379` | Redis donde Auth-User guarda las cuentas suspendidas (el mismo del rate limiting). Kong rechaza con `403` (`account-suspended`) un token de una cuenta suspendida aunque siga vigente. Si Redis no responde, deja pasar y lo registra en el log |
| `AUTH_SERVICE_URL` | `http://auth-service:8000` | Destino de Auth-User-Service |
| `SERVER_ROLES_URL` | `http://server-roles-service:8080` | Destino de Server-Roles-Core-Service |
| `CHAT_ENGINE_URL` | `http://chat-engine-service:3000` | Destino de Chat-Engine-Service |
| `VOICE_SIGNALING_URL` | `http://voice-signaling-service:8080` | Destino de Voice-Signaling-Session-Service |
| `NOTIFICATION_URL` | `http://notification-service:3000` | Destino de Notification-Audit-Metrics-Service |
| `PAYMENTS_URL` | `http://payments-service:8000` | Destino de Payments-Monetization-Service |
| `LIVEKIT_SIGNALING_URL` | `http://livekit:7880` | Señalización de LiveKit (ruta `/livekit`) |

Variables propias de Kong que conviene conocer:

| Variable | Default de la imagen | Para qué |
|---|---|---|
| `KONG_PROXY_LISTEN` | `0.0.0.0:8000, 0.0.0.0:8443 ssl` | Puertos del proxy. Sin certificado propio, Kong genera uno autofirmado para el 8443 |
| `KONG_ADMIN_LISTEN` | `127.0.0.1:8001` | Admin API. En producción no sale del contenedor |
| `KONG_STATUS_LISTEN` | `0.0.0.0:8100` | Status API: `/status` y `/metrics` (Prometheus). No es el proxy; en producción solo lo alcanza el nodo infra |
| `KONG_SSL_CERT` / `KONG_SSL_CERT_KEY` | — | Solo producción: Origin Certificate de Cloudflare |
| `KONG_TRUSTED_IPS` / `KONG_REAL_IP_HEADER` | — | Solo producción: los rangos de Cloudflare y `CF-Connecting-IP`, para que el rate limiting vea la IP real del usuario |

`REDIS_HOST` y `REDIS_PORT` (en `.env.example`) **no se usan**: los plugins de rate limiting tienen
`redis_host: redis` fijo en `kong.yml`.

Los nombres de los claims tienen que coincidir con los que agrega la Action de Auth0
(`auth0/post-login-action.js`). Cada variable que un módulo Lua lee con `os.getenv()` tiene que estar
declarada en `nginx/main-env.conf`: si no, `os.getenv()` devuelve `nil` aunque la variable exista en el
contenedor.

## Autenticación e identidad

- Las rutas protegidas exigen `Authorization: Bearer <access_token>`, emitido por Auth0 para `AUTH0_AUDIENCE`.
- El validador comprueba la firma RS256 contra la JWKS (en caché 3600 s), `exp`, `iss`, `aud` y que exista `sub`.
- **Antes de validar**, Kong borra los headers `X-User-*` que mande el cliente, en todas las rutas
  (incluidas las públicas y los preflight `OPTIONS`).
- Después de validar, le pasa al servicio:

| Header | Valor |
|--------|-------|
| `X-User-Id` | claim `sub` |
| `X-User-Email` | claim de email. Si el token no lo trae, no se envía |
| `X-User-Email-Verified` | `"true"` solo si el claim es `true` (o `"true"`); si no, `"false"` |
| `X-User-Role` | claim de rol, o `"user"` por defecto |

- Las rutas WebSocket aceptan el token también por query string (`?token=`), porque el handshake del
  navegador no permite headers propios. Las REST lo aceptan solo por header.
- Los errores (`401`, `403`, `500`) salen en RFC 7807 (`application/problem+json`).
- Login, registro, verificación de email y MFA son de Auth0, no pasan por el Gateway. La Action de Auth0
  rechaza el login con el email sin verificar, y el login del backoffice a quien no es staff (secret
  `BACKOFFICE_CLIENT_ID`, ver [ADR-002](docs/ADR-002-Rol-Staff-Backoffice.md)).

## Rutas

| Path | Servicio | `strip_path` | Auth |
|------|----------|--------------|------|
| `/api/v1/users`, `/api/v1/profile` | Auth-User | no | JWT |
| `/api/v1/admin/users` | Auth-User | no | JWT + `role = staff` (si no, `403`). Suspender, reactivar y listar cuentas suspendidas |
| `/api/v1/admin/servers` | Server-Roles | no | JWT + `role = staff` (si no, `403`). Suspender y levantar la suspensión de servidores, y listar los suspendidos |
| `/api/v1/auth/password-reset` | Auth-User | no | **Pública** + 5/min y 30/h por IP |
| `/api/v1/servers`, `/channels`, `/roles`, `/moderation`, `/invites` | Server-Roles | no | JWT |
| `/api/v1/chat` (REST y WebSocket) | Chat-Engine | **sí** | JWT (WebSocket: header o `?token=`) |
| `/api/v1/voice` | Voice-Signaling | no | JWT |
| `/ws/voice` | Voice-Signaling | no | JWT (header o `?token=`) |
| `/livekit` | LiveKit | **sí** | Sin JWT: LiveKit valida su propio token, que firma Voice-Signaling |
| `/api/v1/payments`, `/points`, `/boosts` | Payments | no | JWT + 20/min |
| `/api/v1/notifications` | Notification | no | JWT |
| `/api/v1/servers/:id/audit-logs` | Notification | no | JWT. Registro de auditoría de moderación (HU 61). Prioridad regex sobre Server-Roles |
| `/api/v1/audit`, `/api/v1/metrics` | Notification | no | JWT + `role = staff` (si no, `403`) |
| `/api/v1/admin/status` | Notification | no | JWT + `role = staff` (si no, `403`) |
| `/api/v1/admin/incidents` | Notification | no | JWT + `role = staff` (si no, `403`). Publicar, listar y resolver incidentes (`GET`, `POST`) |
| `/api/v1/status` | Notification | no | Pública. Estado combinado e incidentes activos |
| `/livez`, `/readyz` | el Gateway | — | Pública |
| `/internal/readyz/{auth,server-roles,chat,voice,notification,payments}` | el `/readyz` de cada servicio | **sí** (llega `/readyz`) | Solo IPs privadas (`ip-restriction`, si no `403`). Solo `GET`, path exacto |

`/livez` y `/readyz` los responde Kong sin consultar dependencias: `/readyz` todavía no verifica Redis.

Las rutas `/internal/readyz/*` son para que Notification-Audit-Metrics sondee el estado de cada servicio a
través de Kong (timeouts de 2 s, sin reintentos). Detrás de Cloudflare la IP del cliente es siempre pública,
así que desde internet dan `403`. Ver ADR-003.

Plugins globales:

| Plugin | Configuración |
|--------|---------------|
| `cors` | Orígenes de la web (`https://app.discordia.lol`, `http://localhost:5173`) y del backoffice (`https://backoffice.discordia.lol`, `http://localhost:5174`); expone `X-Correlation-ID` y `Retry-After` |
| `rate-limiting` | 300 pedidos por minuto por IP, contados en Redis. Las rutas con su propio límite usan el suyo |
| `correlation-id` | `X-Correlation-ID` (UUID), devuelto también al cliente |
| `request-size-limiting` | 50 MB |
| `prometheus` | Métricas RED por servicio y ruta (código y latencia; sin consumer). Solo en el Status API, `:8100/metrics` |

## Tests

Los tests corren `auth0_validator.lua` en un runtime de Lua embebido (`lupa`), con `kong` y
`resty.openidc` simulados. Cubren el borrado de headers falsificados, la propagación de claims, el rechazo
de `email_verified` falso, tokens inválidos o ausentes, el preflight `OPTIONS` y la autorización de `staff`.
`tests/test_kong_config.py` revisa `kong.yml`: rutas internas con `ip-restriction` y path exacto, rutas
`/api/v1/admin/*` con `staff` y `prometheus` solo como plugin global.

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install lupa pytest pyyaml
pytest tests/
```

Con un token real, `scripts/test-auth-token.sh` pide el token a Auth0 (grant `password-realm`, solo para
pruebas locales) y llama a una ruta del Gateway. La app `discordia` de Auth0 es un *confidential client*, así
que necesita el `client_secret` (pedirlo al equipo; no se commitea):

```bash
./scripts/test-auth-token.sh <client_id> <client_secret> <password> tester@discordia.com /api/v1/users/me
./scripts/test-auth-token.sh <client_id> <client_secret> <password> tester@discordia.com /api/v1/audit   # 403 sin staff
```

## Archivos

| Archivo | Para qué |
|---------|----------|
| `kong.yml` | Servicios, rutas y plugins (declarativo). Plantilla: los destinos son variables |
| `render-config.sh` | Entrypoint de la imagen: completa los destinos de `kong.yml` y arranca Kong |
| `auth0_validator.lua` | Verificación del JWT, headers de identidad y autorización por rol |
| `gateway_health.lua` | `/livez` y `/readyz` del Gateway |
| `auth0/post-login-action.js` | Action del login de Auth0 (agrega los claims). Se carga en el dashboard de Auth0, no en Kong |
| `nginx/main-env.conf` | Directivas `env` para que las variables lleguen a Lua |
| `nginx/shared-dicts.conf` | Memoria compartida (`discovery`, `jwks`) donde `lua-resty-openidc` guarda la JWKS |
| `Dockerfile` | `kong:3.4` + `lua-resty-openidc` 1.7.6-3 y certificados CA |
| `scripts/test-auth-token.sh` | Pide un token real a Auth0 y lo prueba contra el Gateway |
| `tests/test_auth0_validator.py` | Tests del validador |
| `tests/test_kong_config.py` | Chequeos estáticos de `kong.yml` (rutas internas, staff, métricas) |

## CI/CD

`.github/workflows/ci.yml`:

1. `test`: los tests (validador y `kong.yml`) y un chequeo de que todas las variables de `kong.yml` tengan
   default en `render-config.sh`.
2. `docker`: construye la imagen y valida la configuración renderizada con `kong config parse`; en push a `main` o `develop` la publica como
   `ghcr.io/discordia-g12/gateway:<sha>` (y `:<rama>`).
3. `deploy`: en push a `main`, la despliega en el nodo **edge** con el workflow del orquestador (SSM; si no
   queda sana, vuelve sola a la versión anterior).

## Contrato de API

El Gateway no tiene OpenAPI propio: la fuente de verdad de las rutas es `kong.yml`, y cada servicio publica
su Swagger (ver el README de cada uno).
