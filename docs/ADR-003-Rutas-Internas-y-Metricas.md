# ADR-003: Rutas internas de readiness y métricas RED del Gateway

- **Estado:** Aceptado
- **Fecha:** 2026-11-03
- **Alcance:** API Gateway (`kong.yml`, `Dockerfile`), Notification-Audit-Metrics (consumidor de las rutas
  internas y dueño de `/api/v1/admin/status`), Security Groups del orquestador (`infra/terraform`)
- **Relacionado:** ADR-001 (Kong DB-less), ADR-002 (rol staff y rutas de backoffice)

---

## 1. Contexto

Notification-Audit-Metrics (nodo realtime) arma el estado de la plataforma para el backoffice: sondea el
`/readyz` de cada servicio cada pocos segundos (~28 pedidos por minuto en total). El problema es llegar a
todos:

- Auth-User y Server-Roles corren en el nodo edge y Auth **no se publica** fuera de la red de Docker de edge.
- Payments (nodo infra) solo acepta tráfico desde edge.
- Kong ya llega a todos: es el único lugar desde donde se ve la plataforma entera.

Además faltaban métricas del tráfico que entra: cuántos pedidos, cuántos errores y con qué latencia, por
servicio y ruta (RED). Kong es el punto por el que pasa todo.

## 2. Decisión

| # | Tema | Decisión |
|---|------|----------|
| 1 | Readiness | Una ruta por servicio en el proxy de Kong: `/internal/readyz/{auth,server-roles,chat,voice,notification,payments}` → `${X_URL}/readyz`. Cada una en un servicio Kong propio (timeouts de 2 s, `retries: 0`), solo `GET`, path exacto (regex con `$`) y `strip_path: true`. |
| 2 | Acceso | Plugin `ip-restriction` en cada ruta con `allow` = rangos privados (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) y `127.0.0.1`; cualquier otra IP recibe `403`. Además `strip_identity_headers()`, como en toda ruta pública. |
| 3 | Estado para staff | `/api/v1/admin/status` → Notification-Audit, con `validate("staff", false)` (checklist de ADR-002 §4). |
| 4 | Métricas | Plugin global `prometheus` (incluido en Kong 3.4), leído **solo** desde el Status API (`KONG_STATUS_LISTEN=0.0.0.0:8100`, `/metrics`). Ninguna ruta del proxy expone `/metrics`. |

Con `strip_path: true`, una ruta regex y el servicio con path `/readyz`, el upstream recibe exactamente
`/readyz` (más la query string, si viene). Se fija `path_handling: v0`: cuando se despoja el path completo,
v0 y v1 dan el mismo resultado; la diferencia entre los dos solo aparece con un sufijo, y el `$` lo impide
(`/internal/readyz/auth/`, `/internal/readyz/authx` o `.../auth/foo` no matchean y dan 404 de Kong).

## 3. Por qué la ruta interna es segura

- En producción el 443 de edge solo acepta conexiones desde los rangos de Cloudflare (Security Group).
- Kong toma la IP del cliente de `CF-Connecting-IP` porque `KONG_TRUSTED_IPS` son los rangos de Cloudflare
  (`deploy/gateway.env`). Esa IP es la del usuario en internet: **siempre pública**, así que `ip-restriction`
  responde `403`.
- El cliente no puede falsificar `CF-Connecting-IP`: Cloudflare lo pisa con la IP real de la conexión.
- Una conexión directa desde la VPC (Notification en realtime) no viene de una IP de confianza: Kong ignora
  cualquier `CF-Connecting-IP` que traiga y usa la IP privada del nodo, que está en `allow`.
- En local no hay `KONG_TRUSTED_IPS`: llegan las IPs de la red de Docker, que son privadas.

Condición: Kong tiene que ver como origen la IP de Cloudflare y no una de Docker. Hoy Docker publica el 443 con
DNAT (iptables) y conserva la IP de origen; si en algún momento entrara por el `docker-proxy` (por ejemplo IPv6
o hairpin), el origen sería `172.x`, privado, y la ruta quedaría abierta. Es la misma condición que ya necesita
el rate limiting por IP, y se verifica mirando la IP del cliente en el log de Kong o pidiendo
`https://api.discordia.lol/internal/readyz/auth` desde afuera: tiene que dar `403`.

Lo que se expone igual es poco: `/readyz` de cada servicio, sin datos de usuarios.

## 4. Métricas y cardinalidad

```yaml
- name: prometheus
  config:
    per_consumer: false          # no hay consumers de Kong; con usuarios sería una serie por persona
    status_code_metrics: true    # kong_http_requests_total{service,route,code,source}
    latency_metrics: true        # kong_request_latency_ms, kong_upstream_latency_ms, kong_kong_latency_ms
    bandwidth_metrics: false
    upstream_health_metrics: false  # no hay upstreams declarados
```

Los labels son `service`, `route`, `code` y `source` (más `consumer`, siempre vacío): unas 20 rutas por un
puñado de códigos, acotado. No se agregan labels por path ni por usuario.

El Status API (8100) no es el proxy: no tiene rutas, ni auth, ni pasa por Cloudflare. La imagen trae
`KONG_STATUS_LISTEN=0.0.0.0:8100` y `EXPOSE 8100` para que funcione sola; el compose de deploy publica el
puerto y el Security Group de edge lo abre solo para el nodo infra (Prometheus).

## 5. Dependencias en el orquestador

| Pieza | Dónde |
|-------|-------|
| Regla de SG **realtime → edge 443** (Notification llama a Kong por la IP privada de edge) | `infra/terraform` |
| Regla de SG **infra → edge 8100** (Prometheus scrapea el Status API) | `infra/terraform` |
| `KONG_STATUS_LISTEN` y el puerto 8100 publicado en `gateway` | `deploy/docker-compose.yml` |
| Job de scrape de `<edge>:8100/metrics` | `observability` |

Notification llama a `https://<IP privada de edge>/internal/readyz/...`: el certificado es el Origin
Certificate de Cloudflare (no coincide con la IP), así que ese cliente tiene que fijar ese certificado como CA
de confianza o aceptar el nombre del certificado; no desactivar la verificación de TLS en general.

## 6. Alternativas descartadas

- **Publicar Auth y Payments a la VPC para que Notification los consulte directo.** Abre puertos de servicios
  que hoy solo ve Kong y va contra la regla 3 de ADR-002 (los servicios solo aceptan tráfico de Kong).
- **Abrir un puerto por servicio entre nodos.** Más reglas de SG que mantener y cada servicio vuelve a ser
  alcanzable sin Kong.
- **Un listener aparte de Kong solo para lo interno.** Otro puerto y otra regla de SG, y Kong no ata rutas a un
  listener: las rutas internas seguirían respondiendo también en el 443. La `ip-restriction` hace falta igual.
- **Exponer `/metrics` por una ruta del proxy con auth.** Cualquier error en la ruta lo publica a internet; el
  Status API no tiene ese riesgo.

## 7. Consecuencias

- Un servicio colgado aparece como caído a los 2 s (sin reintentos) y no frena el sondeo.
- El sondeo cuenta para el rate limiting global (300/min por IP, la del nodo realtime): ~28/min no molesta. Si
  se suman sondeos, darle a estas rutas un límite propio.
- Las rutas internas también generan métricas en Prometheus (`route="internal-readyz-*"`); se pueden filtrar
  en los dashboards.
- Agregar un servicio nuevo implica sumar su ruta `internal-readyz-*` y el test en `tests/test_kong_config.py`
  lo cubre.
