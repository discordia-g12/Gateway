# Discordia — API Gateway

Kong 3.4 en modo DB-less (configuración declarativa): punto de entrada único para el tráfico de
clientes. Valida los access tokens de Auth0 (RS256 contra la JWKS, con cache y rotación de claves),
inyecta la identidad verificada en headers `X-User-*`, aplica autorización por rol en el perímetro y
hace proxy a los microservicios.

Ver [`docs/ADR-001-API-Gateway.md`](docs/ADR-001-API-Gateway.md) para las decisiones de diseño.

## Cómo se ejecuta

Este repo **no tiene `docker-compose.yml` propio**: el Gateway corre desde `discordia-orchestrator`
como servicio `gateway` (contenedor `discordia-gateway`), junto a su Redis (`gateway-redis`, con el
alias de red `redis`) en la red `discordia-net`. El orquestador monta como volúmenes `kong.yml`, los
módulos `.lua` y los archivos de `nginx/`, y carga `Gateway/.env`.

```bash
# Desde discordia-orchestrator
cp Gateway/.env.example Gateway/.env
docker compose up -d gateway          # levanta también gateway-redis

docker compose logs -f gateway        # logs
docker compose restart gateway        # tras cambiar kong.yml, un .lua o .env
docker compose down
```

Kong corre en modo DB-less: todo cambio en `kong.yml` o en los módulos `.lua` requiere reiniciar.

## Variables de entorno

Se definen en `.env` (copiado de `.env.example`).

| Variable | Default | Descripción |
|----------|---------|-------------|
| `AUTH0_DOMAIN` | — (requerida) | Dominio del tenant, hoy `dev-dppme5iaqg60gkmo.us.auth0.com`. De él se derivan el issuer (`https://<dominio>/`) y la JWKS (`/.well-known/jwks.json`). |
| `AUTH0_AUDIENCE` | — (requerida) | Identifier de la API en Auth0 (`https://api.discordia.com`). Tiene que coincidir con el `audience` que piden web y mobile. Si falta alguna de las dos variables requeridas, las rutas protegidas responden `500 Gateway misconfigured`. |
| `AUTH0_ROLE_CLAIM` | `https://discordia.app/role` | Claim namespaced con el rol (`user` / `staff`). |
| `AUTH0_EMAIL_CLAIM` | `https://discordia.app/email` | Claim namespaced con el email. Si no viene, se usa `email` como fallback. |
| `AUTH0_EMAIL_VERIFIED_CLAIM` | `https://discordia.app/email_verified` | Claim namespaced de verificación. Si no viene, se usa `email_verified` como fallback. |
| `REDIS_HOST` / `REDIS_PORT` | `redis` / `6379` | **Kong no las lee:** los plugins de `rate-limiting` tienen `redis_host: redis` fijo en `kong.yml`. |

Los nombres de los claims tienen que coincidir con los que setea la Action de Auth0
(`auth0/post-login-action.js`).

> Cada variable que un módulo Lua lea con `os.getenv()` debe declararse en `nginx/main-env.conf`
> (una directiva `env` por variable, cargada con `KONG_NGINX_MAIN_INCLUDE`). Si no está declarada,
> `os.getenv()` devuelve `nil` aunque la variable exista en el contenedor.

## Archivos

| Archivo | Propósito |
|---------|-----------|
| `kong.yml` | Servicios, rutas y plugins (declarativo) |
| `auth0_validator.lua` | Verificación del JWT, mapeo de claims a headers y autorización por rol |
| `gateway_health.lua` | `/livez` y `/readyz` propios del Gateway |
| `auth0/post-login-action.js` | Action del Login flow de Auth0. Se despliega en el dashboard de Auth0, no en Kong |
| `auth0/password-reset.md` | Runbook: configuración manual del tenant de Auth0 para el recupero de contraseña |
| `auth0/change-password-email.html` | Plantilla del email de recupero (se pega en Auth0 → Email Templates → Change Password) |
| `nginx/main-env.conf` | Directivas `env` para que las variables sean visibles desde Lua |
| `nginx/shared-dicts.conf` | Zonas de memoria compartida (`discovery`, `jwks`) usadas por `lua-resty-openidc` para cachear la JWKS |
| `Dockerfile` | `kong:3.4` + `lua-resty-openidc` 1.7.6-3 (instala `lua-resty-session` como dependencia) y certificados CA |
| `scripts/test-auth-token.sh` | Pide un token real a Auth0 y lo prueba contra una ruta del Gateway |
| `tests/test_auth0_validator.py` | Tests unitarios del validador |

## Puertos

| Puerto | Descripción |
|--------|-------------|
| `8000` | Proxy: todo el tráfico de clientes entra por acá |
| `8001` | Admin API de Kong. Solo para desarrollo local; no exponer en producción |

## Autenticación e identidad

- Las rutas protegidas exigen `Authorization: Bearer <access_token>`, emitido por Auth0 para `AUTH0_AUDIENCE`.
- El validador comprueba la firma RS256 contra la JWKS (cacheada 3600 s), además de `exp`, `iss` y `aud` y la presencia de `sub`.
- **Antes de validar**, Kong elimina los headers `X-User-*` que mande el cliente. Lo hace en todas las rutas, incluidas `/api/v1/status` y los preflight `OPTIONS`.
- Después de validar, inyecta hacia el upstream:

| Header | Valor |
|--------|-------|
| `X-User-Id` | claim `sub` |
| `X-User-Email` | claim de email. Si el token no lo trae, el header no se envía |
| `X-User-Email-Verified` | `"true"` solo si el claim es el booleano `true` (o `"true"`); en cualquier otro caso `"false"` |
| `X-User-Role` | claim de rol, o `"user"` por defecto |

- La Action de Auth0 deniega el login a usuarios con el email sin verificar, así que en condiciones normales no llegan tokens con `email_verified = false`.
- Las rutas `/api/v1/audit` y `/api/v1/metrics` exigen `role = staff`; si no, responden `403`.
- Las rutas WebSocket aceptan el token también por query string (`?token=`), porque el handshake del navegador no permite headers custom. Las rutas REST lo aceptan solo por header.
- Los errores (`401`, `403`, `500`) se devuelven en RFC 7807 (`application/problem+json`).

Login, registro, verificación de email y MFA no pasan por el Gateway: son de Auth0. El recupero de
contraseña se **dispara** por el Gateway (`POST /api/v1/auth/password-reset`, pública y con límite por
IP) para aplicar límites propios, pero el email y la página donde se elige la nueva contraseña son de
Auth0 (ver `auth0/password-reset.md`).

## Referencia de rutas

Todas se acceden vía `http://localhost:8000`. Upstreams según `kong.yml`.

| Path | Upstream | `strip_path` | Auth |
|------|----------|--------------|------|
| `/api/v1/users` (hoy: `GET` y `POST` `/api/v1/users/me`) | `auth-service:8000` | no | JWT |
| `/api/v1/auth/password-reset` (`POST`) | `auth-service:8000` | no | **Pública** (strip de `X-User-*`) + rate limit propio: 5/min y 30/h por IP |
| `/api/v1/chat` (REST) | `chat-engine-service:3000` | **sí** | JWT |
| `/api/v1/chat` con `Upgrade: websocket` | `chat-engine-service:3000` | **sí** | JWT (header o `?token=`) |
| `/api/v1/voice` | `voice-service:3001` | no | JWT |
| `/ws/voice` | `voice-service:3001` | no | JWT (header o `?token=`) |
| `/api/v1/servers`, `/api/v1/channels`, `/api/v1/roles`, `/api/v1/moderation`, `/api/v1/invites` | `server-roles-service:8080` | no | JWT |
| `/api/v1/payments`, `/api/v1/points`, `/api/v1/boosts` | `payments-service:8002` | no | JWT + rate limit de 20/min además del global |
| `/api/v1/notifications` | `notification-service:8003` | no | JWT |
| `/api/v1/audit`, `/api/v1/metrics` | `notification-service:8003` | no | JWT + `role = staff` |
| `/api/v1/status` | `notification-service:8003` | no | Pública (con strip de `X-User-*`) |
| `/livez`, `/readyz` | Gateway (respuesta propia) | — | Pública |

`/livez` y `/readyz` responden `200` desde el propio Kong, sin consultar dependencias. `/readyz`
todavía no verifica Redis.

### Plugins globales

| Plugin | Configuración |
|--------|---------------|
| `cors` | Orígenes `https://app.discordia.com`, `http://localhost:5173` y el host EC2 de desarrollo; expone `X-Correlation-ID` y `Retry-After` |
| `rate-limiting` | 300 requests/min por IP, contador en Redis. Las rutas con su propio `rate-limiting` (pagos, recupero de contraseña) usan el suyo en lugar de este |
| `correlation-id` | `X-Correlation-ID` (UUID), devuelto también al cliente |
| `request-size-limiting` | 50 MB |

## Testing

### Tests unitarios del validador

Ejecutan `auth0_validator.lua` en un runtime Lua embebido (`lupa`), con `kong` y `resty.openidc`
mockeados. Cubren el strip de headers falsificados, la propagación de claims, el fail-closed de
`email_verified`, el rechazo de tokens inválidos o ausentes, el preflight `OPTIONS` y la autorización
de `staff`.

```bash
pip install lupa pytest
pytest tests/
```

### Pruebas contra la instancia viva

```bash
# Kong arrancó y cargó la configuración
curl http://localhost:8001/
curl http://localhost:8001/routes

# Rutas públicas
curl http://localhost:8000/livez
curl http://localhost:8000/api/v1/status

# Sin token o con token inválido → 401
curl -i http://localhost:8000/api/v1/users/me
curl -i -H "Authorization: Bearer invalid.token.here" http://localhost:8000/api/v1/users/me
```

Con un token real, `scripts/test-auth-token.sh` pide el token a Auth0 (grant `password-realm`, solo
para pruebas locales) y llama a una ruta del Gateway. La app `discordia` es un *confidential client*,
así que requiere `client_secret`.

```bash
./scripts/test-auth-token.sh <client_id> <client_secret> <password> tester@discordia.com /api/v1/users/me

# Con un usuario sin role=staff → 403
./scripts/test-auth-token.sh <client_id> <client_secret> <password> tester@discordia.com /api/v1/audit
```

Sin argumento de ruta, el script usa `/api/v1/users`, que en `auth-user-service` responde `404`:
conviene pasar la ruta explícitamente.

## Contrato de API (OpenAPI)

Pendiente: la especificación OpenAPI 3.0 del Gateway todavía no está publicada. Mientras tanto, la
fuente de verdad de rutas es `kong.yml`, y cada servicio expone su propio Swagger (por ejemplo,
`auth-user-service` en `http://localhost:8004/docs`).

## Dependencias

| Dependencia | Versión | Rol |
|-------------|---------|-----|
| Kong Gateway | 3.4 | API Gateway (DB-less) |
| `lua-resty-openidc` | 1.7.6-3 | Verificación de JWT contra la JWKS remota, con cache |
| Redis | 7-alpine | Contadores de `rate-limiting` |
| Auth0 | — | Identity provider (RS256, JWKS con rotación) |
