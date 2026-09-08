# Discordia — API Gateway

Kong 3.4 (DB-less, modo declarativo) — punto de entrada único para todo el tráfico de clientes de Discordia. Valida access tokens JWT de Auth0 (RS256, JWKS con rotación de claves), inyecta `X-User-Id` / `X-User-Role`, y hace proxy a seis microservicios backend.

## Prerrequisitos

- [Docker](https://docs.docker.com/get-docker/) ≥ 24
- [Docker Compose](https://docs.docker.com/compose/) ≥ 2.20 (incluido en Docker Desktop)

No se requiere ningún runtime adicional — Kong corre completamente en Docker.

## Setup local

```bash
cp .env.example .env
# Completar AUTH0_DOMAIN y AUTH0_AUDIENCE con los valores del tenant de
# Auth0 del equipo (ver sección "Autenticación" más abajo)
docker compose up -d
```

## Comandos de ejecución

```bash
# Iniciar gateway
docker compose up -d

# Ver logs en tiempo real
docker compose logs -f kong

# Reiniciar después de cambios en kong.yml, en los módulos .lua o en .env
docker compose restart kong

# Detener
docker compose down
```
---

## Variables de entorno

Definidas en `.env` (copiado de `.env.example`):

| Variable | Default | Descripción |
|----------|---------|-------------|
| `AUTH0_DOMAIN` | — (requerida) | Dominio del tenant de Auth0, ej. `discordia-dev.us.auth0.com`. Se usan para derivar `issuer` y la URL de la JWKS. |
| `AUTH0_AUDIENCE` | — (requerida) | Identifier de la API registrada en Auth0. Debe coincidir con el `audience` que piden los clientes (mobile/web) al solicitar el token. |
| `AUTH0_ROLE_CLAIM` | `https://discordia.app/role` | Nombre del claim custom namespaced donde Auth0 publica el rol del usuario (`user` / `staff`), seteado vía una Auth0 Action en el login flow. |
| `REDIS_HOST` | `redis` | Host del store usado por los plugins de `rate-limiting`. |
| `REDIS_PORT` | `6379` | Puerto de Redis. |

Toda la configuración de rutas, plugins y timeouts vive en `kong.yml` — no se requieren variables de entorno adicionales para Kong en sí.

## Configuración

| Archivo | Propósito |
|---------|-----------|
| `.env` | Configuración de Auth0 y Redis |
| `kong.yml` | Servicios, rutas y plugins (declarativo, único ambiente por ahora) |
| `auth0_validator.lua` | Verificación de JWT contra la JWKS de Auth0, mapeo de claims a headers y autorización por rol |
| `gateway_health.lua` | `/livez` y `/readyz` propios del Gateway (no delegan a ningún microservicio) |
| `nginx/shared-dicts.conf` | Zonas de memoria compartida (`discovery`, `jwks`) que necesita `lua-resty-openidc` para cachear la JWKS |
| `Dockerfile` | Imagen de Kong con `lua-resty-openidc` y `lua-resty-session` instalados |

## Puertos

| Puerto | Descripción |
|--------|-------------|
| `8000` | Proxy — todo el tráfico de clientes entra aquí |
| `8001` | Kong Admin API (solo local, no exponer en producción) |

Los microservicios backend (`auth-service:8000`, `chat-service:3000`, `voice-service:3001`, `server-core:8001`, `payments-service:8002`, `notification-service:8003`) son upstreams internos de la red `discordia-net` — no se exponen a través de este `docker-compose.yml`. Ver el repositorio de cada servicio para sus puertos de host en desarrollo local.

## Autenticación

Las rutas protegidas requieren el header `Authorization: Bearer <token>` con un access token JWT válido de Auth0.

- Token emitido por `https://{AUTH0_DOMAIN}/`
- Audience: el valor de `AUTH0_AUDIENCE`
- Kong valida firma RS256 contra la JWKS de Auth0 (con cache y soporte de rotación de claves vía `lua-resty-openidc`) y el claim `exp`
- Kong inyecta `X-User-Id` (valor = claim `sub` del JWT) y `X-User-Role` (valor = claim de rol custom) en cada request reenviado
- Las rutas de WebSocket (`/ws/chat`, `/ws/voice`) también aceptan el token por query string (`?token=`), ya que el handshake WS del navegador no admite headers custom. El resto de las rutas solo lo acepta por header.

Ver [`docs/ADR-001-API-Gateway.md`](docs/ADR-001-API-Gateway.md) para el detalle de esta decisión.

## Contrato de API (OpenAPI)

Pendiente. La especificación OpenAPI 3.0 de los endpoints expuestos por el gateway todavía no está publicada en este repositorio — es un ítem abierto del RNF de documentación del proyecto. Hasta que exista, la fuente de verdad de rutas es `kong.yml` y la tabla de la siguiente sección.

## Referencia de rutas

Todas las rutas se acceden vía `http://localhost:8000`.

### Auth & User Service — upstream `auth-service:8000`

| Método | Path | Auth |
|--------|------|------|
| `GET` | `/api/v1/users` | **JWT requerido** |
| `POST` | `/api/v1/users` | **JWT requerido** |
| `PATCH` | `/api/v1/users` | **JWT requerido** |

> Login, registro, recuperación de contraseña, 2FA y sesión no pasan por el Gateway: son responsabilidad de Auth0.

### Chat Engine Service — upstream `chat-service:3000`

| Método | Path | Auth |
|--------|------|------|
| `GET`/`POST` | `/api/v1/messages` | **JWT requerido** |
| `GET` (upgrade) | `/ws/chat` | **JWT requerido** (header o `?token=`) |

### Voice Signaling Service — upstream `voice-service:3001`

| Método | Path | Auth |
|--------|------|------|
| `GET`/`POST` | `/api/v1/voice` | **JWT requerido** |
| `GET` (upgrade) | `/ws/voice` | **JWT requerido** (header o `?token=`) |

### Server Core Service — upstream `server-core:8001`

| Método | Path | Auth |
|--------|------|------|
| `*` | `/api/v1/servers` | **JWT requerido** |
| `*` | `/api/v1/channels` | **JWT requerido** |
| `*` | `/api/v1/roles` | **JWT requerido** |
| `*` | `/api/v1/moderation` | **JWT requerido** |

### Payments & Monetization Service — upstream `payments-service:8002`

| Método | Path | Auth | Notas |
|--------|------|------|-------|
| `*` | `/api/v1/payments` | **JWT requerido** | Rate-limit 20/min además del global |
| `*` | `/api/v1/points` | **JWT requerido** | Rate-limit 20/min además del global |
| `*` | `/api/v1/boosts` | **JWT requerido** | Rate-limit 20/min además del global |

### Notification, Audit & Metrics Service — upstream `notification-service:8003`

| Método | Path | Auth |
|--------|------|------|
| `*` | `/api/v1/notifications` | **JWT requerido** |
| `*` | `/api/v1/audit` | **JWT requerido — solo `role: staff`** |
| `*` | `/api/v1/metrics` | **JWT requerido — solo `role: staff`** |
| `GET` | `/api/v1/status` | Pública |

### Gateway (self)

| Método | Path | Auth |
|--------|------|------|
| `GET` | `/livez` | Pública — liveness del propio Kong, sin I/O |
| `GET` | `/readyz` | Pública — verifica conectividad a Redis |

## Testing

No hay unit tests para el gateway — la configuración es declarativa. La verificación se hace contra la instancia viva.

### Verificar que Kong arrancó correctamente

```bash
# Health check de Kong vía Admin API
curl http://localhost:8001/

# Ver todos los servicios configurados
curl http://localhost:8001/services

# Ver todas las rutas
curl http://localhost:8001/routes
```

### Probar rutas públicas

```bash
# Liveness / readiness del Gateway
curl http://localhost:8000/livez
curl http://localhost:8000/readyz

# Estado agregado de la plataforma
curl http://localhost:8000/api/v1/status
```

### Probar rutas protegidas

```bash
# 1. Obtener un access token de Auth0 (Resource Owner Password Grant,
#    solo para pruebas locales -- no usar este grant type desde apps cliente)
TOKEN=$(curl -s --request POST \
  --url "https://${AUTH0_DOMAIN}/oauth/token" \
  --header "Content-Type: application/json" \
  --data "{
    \"client_id\": \"<AUTH0_TEST_CLIENT_ID>\",
    \"grant_type\": \"password\",
    \"username\": \"tester@discordia.com\",
    \"password\": \"<password>\",
    \"audience\": \"${AUTH0_AUDIENCE}\",
    \"scope\": \"openid profile email\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. Usar el token
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/users
```

### Verificar que el JWT es rechazado en rutas protegidas

```bash
# Debe devolver 401
curl -i http://localhost:8000/api/v1/users

# Debe devolver 401 con token inválido
curl -i -H "Authorization: Bearer invalid.token.here" http://localhost:8000/api/v1/users

# Debe devolver 403 si el usuario no tiene role: staff
curl -i -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/audit
```

## Actualizar configuración

Kong corre en modo DB-less: cualquier cambio en `kong.yml` o en los módulos `.lua` requiere reinicio:

```bash
docker compose restart kong
```

## Dependencias relevantes

| Dependencia | Versión | Rol |
|-------------|---------|-----|
| Kong Gateway | 3.4 | API Gateway (DB-less, declarativo) |
| Auth0 | — | Identity provider (RS256 JWT, JWKS con rotación de claves) |
| `lua-resty-openidc` | latest (luarocks) | Verificación de JWT contra JWKS remota, con cache y soporte de rotación |
| Redis | 7-alpine | Store compartido para los plugins de `rate-limiting` |
