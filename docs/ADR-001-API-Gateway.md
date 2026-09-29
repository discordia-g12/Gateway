# ADR 001: Arquitectura del API Gateway (Kong en modo DB-less) y validaciÃ³n de identidad con Auth0

## Contexto del problema

El proyecto Discordia se basa en una arquitectura de microservicios y
requiere un punto de entrada Ãºnico (API Gateway) que enrute el trÃ¡fico hacia
los distintos servicios backend (Server Core, Chat, Voice, Payments,
Notification & Audit), gestionando aspectos transversales como CORS, Rate
Limiting, Observabilidad (Correlation IDs) y validaciÃ³n de autenticaciÃ³n.

Esta decisiÃ³n cubre dos preguntas relacionadas:

1. **Modelo de despliegue de Kong**: usar una base de datos de respaldo
   (tÃ­picamente PostgreSQL) para persistir configuraciÃ³n, o usar el modo
   DB-less con configuraciÃ³n declarativa, dado que las rutas y servicios del
   sistema son estÃ¡ticos y conocidos de antemano.
2. **GestiÃ³n de identidad y validaciÃ³n de tokens**: quiÃ©n emite las
   credenciales de los usuarios finales y cÃ³mo el Gateway verifica esos
   tokens antes de reenviar la peticiÃ³n a los servicios downstream,
   incluyendo la propagaciÃ³n de identidad (`X-User-Id`) y rol
   (`X-User-Role`) hacia esos servicios.

## DecisiÃ³n tomada

### 1. Kong Gateway en modo DB-less

Toda la configuraciÃ³n del Gateway (servicios, rutas, plugins globales y por
ruta) reside en un Ãºnico archivo declarativo `kong.yml` versionado en Git.

### 2. Auth0 como Identity Provider externo

La gestiÃ³n de identidad de usuarios finales (registro, login, recuperaciÃ³n
de contraseÃ±a, autenticaciÃ³n multifactor, gestiÃ³n de sesiÃ³n y emisiÃ³n de
tokens) se delega completamente a **Auth0**. El sistema no almacena
contraseÃ±as ni credenciales de ningÃºn tipo: Auth0 es la Ãºnica fuente de
verdad para autenticaciÃ³n, y los servicios backend de Discordia identifican
a un usuario exclusivamente por el claim `sub` de un access token de Auth0
ya verificado.

Auth0 emite access tokens **RS256**, firmados con una clave privada propia
y verificables contra una JSON Web Key Set (JWKS) pÃºblica, publicada en
`https://{AUTH0_DOMAIN}/.well-known/jwks.json` y con rotaciÃ³n periÃ³dica de
claves gestionada por Auth0.

La verificaciÃ³n de estos tokens en el Gateway se implementa mediante un
mÃ³dulo Lua (`auth0_validator.lua`), ejecutado como `pre-function` en cada
ruta protegida, construido sobre **`lua-resty-openidc`** â€” la librerÃ­a de
referencia del ecosistema OpenResty para verificaciÃ³n de JWT contra JWKS
remotas con soporte de cache y rotaciÃ³n de claves. El mÃ³dulo:

- Verifica la firma del token exclusivamente contra la JWKS de Auth0 (sin
  ningÃºn secreto compartido).
- Valida `iss` (issuer, derivado del dominio del tenant de Auth0) y `aud`
  (audience, el identificador de la API registrada en Auth0).
- Extrae el claim `sub` y un claim custom namespaced
  (`https://discordia.app/role`, configurado vÃ­a una Auth0 Action en el
  login flow) y los propaga como `X-User-Id` / `X-User-Role` a los
  servicios backend.
- Aplica autorizaciÃ³n por rol a nivel de ruta, rechazando con 403 a quien
  no tenga `role: "staff"` en las rutas de backoffice
  (`/api/v1/audit`, `/api/v1/metrics`).

El dominio de Auth0, el audience y el nombre del claim de rol se configuran
por variables de entorno (`AUTH0_DOMAIN`, `AUTH0_AUDIENCE`,
`AUTH0_ROLE_CLAIM`), sin valores hardcodeados en `kong.yml` ni en el cÃ³digo
Lua.

Los endpoints de WebSocket (`/ws/chat`, `/ws/voice`) aceptan el token por
query string (`?token=`) ademÃ¡s del header `Authorization`, ya que el
handshake de WebSocket del navegador no admite headers custom. El resto de
las rutas REST solo acepta el token vÃ­a header â€” nunca por query string,
para no exponer credenciales en access logs, historial del navegador o
headers `Referer`.

## Alternativas descartadas

- **Kong con PostgreSQL (Modo Tradicional):** Descartado. AÃ±ade carga
  operacional (mantenimiento, backups, migraciones de una DB extra) e
  incrementa la superficie de fallo del Gateway. No se requieren consumers
  dinÃ¡micos ni credenciales gestionadas por Kong, por lo que una base de
  datos adicional es innecesaria.

- **Identidad gestionada internamente (Auth-User-Service como emisor
  propio):** Descartada. Implica mantener hashing de contraseÃ±as, tokens de
  recupero, 2FA y todo el ciclo de vida de credenciales dentro del sistema,
  con la superficie de riesgo de seguridad que eso conlleva. Delegar esto a
  un proveedor especializado reduce esa superficie y evita reimplementar
  funcionalidad de seguridad crÃ­tica (rotaciÃ³n de claves, protecciÃ³n contra
  fuerza bruta, MFA) que Auth0 ya provee de forma auditada.

- **Plugin `openid-connect` nativo de Kong:** Descartado. Es la integraciÃ³n
  "de fÃ¡brica" mÃ¡s directa con un IdP OIDC, pero es una feature exclusiva de
  Kong Enterprise â€” no estÃ¡ disponible en la ediciÃ³n Community usada en este
  proyecto.

- **Plugins comunitarios de terceros para OIDC (`kong-oidc`, entre otros):**
  Descartados. Resuelven el mismo problema con menos cÃ³digo propio, pero son
  paquetes de terceros con bajo volumen de uso y mantenimiento incierto.
  Dado que el equipo debe poder explicar y defender cualquier parte del
  cÃ³digo del proyecto, se prefiriÃ³ construir un mÃ³dulo propio, delgado y
  auditable, sobre una librerÃ­a de base ampliamente usada y madura
  (`lua-resty-openidc`) en vez de depender de un plugin empaquetado por
  terceros para toda la lÃ³gica de autorizaciÃ³n.

- **VerificaciÃ³n de JWKS y conversiÃ³n de claves escrita a mano:**
  Descartada. Implica reimplementar fetch, cacheo, rotaciÃ³n de claves y
  conversiÃ³n JWKâ†’PEM â€” lÃ³gica criptogrÃ¡ficamente sensible que
  `lua-resty-openidc` ya resuelve de forma madura y probada.

- **AutorizaciÃ³n por rol vÃ­a RBAC nativo de Auth0 (claim `permissions`):**
  Descartada por ahora en favor de un claim custom simple (`role`). El RBAC
  nativo de Auth0 (Roles + Permissions a nivel de API) es mÃ¡s granular pero
  agrega complejidad de configuraciÃ³n no justificada para el Ãºnico corte de
  autorizaciÃ³n que el sistema necesita hoy (usuario regular vs. staff de
  plataforma). Queda como alternativa a reevaluar si el modelo de
  autorizaciÃ³n necesita mÃ¡s de dos niveles.

## Consecuencias esperadas

- **ConfiguraciÃ³n como CÃ³digo (GitOps):** Los cambios en rutas, polÃ­ticas y
  configuraciÃ³n del validador se versionan en el repositorio, asegurando un
  entorno reproducible desplegable vÃ­a CI/CD.
- **Auth-User-Service reduce su alcance:** Pasa a gestionar exclusivamente
  datos de perfil propios de Discordia (avatar, biografÃ­a, estado
  personalizado), identificados por el `sub` de Auth0 como clave externa. No
  gestiona contraseÃ±as, tokens de sesiÃ³n ni MFA.
- **Dependencia de disponibilidad de Auth0:** La validaciÃ³n de tokens
  requiere que el Gateway pueda alcanzar el endpoint JWKS de Auth0. Se
  mitiga con el cache de `lua-resty-openidc` (TTL configurable), que permite
  seguir validando tokens ya vistos aunque Auth0 estÃ© temporalmente
  inalcanzable, siempre que no aparezca un `kid` nuevo no cacheado.
- **Los clientes deben solicitar el `audience` correcto:** Auth0 solo emite
  un JWT verificable (en lugar de un token opaco) cuando la aplicaciÃ³n
  cliente especifica el parÃ¡metro `audience` en la solicitud de
  autorizaciÃ³n. Esto es un contrato a coordinar con los equipos de mobile y
  web client.
- **Sin Rate Limiting por cuenta en el Gateway:** El plugin `rate-limiting`
  de Kong solo discrimina por IP. La protecciÃ³n contra fuerza bruta en login
  y MFA queda delegada a los mecanismos propios de Auth0 (Attack Protection,
  Brute-force Protection), no implementada en Discordia.
- **Sin revocaciÃ³n temprana de tokens:** La validaciÃ³n es estateless (sin
  consulta a Auth0 en cada request); un token comprometido sigue siendo
  vÃ¡lido hasta su expiraciÃ³n natural. Se mitiga manteniendo el `exp` de los
  access tokens corto (configurado en Auth0), con renovaciÃ³n vÃ­a refresh
  token gestionada directamente entre el cliente y Auth0, fuera del Gateway.
- **Cambio de claim de rol requiere coordinaciÃ³n:** El nombre del claim
  custom (`https://discordia.app/role`) debe mantenerse sincronizado entre
  la Auth0 Action que lo genera y la variable de entorno
  `AUTH0_ROLE_CLAIM` del Gateway.
