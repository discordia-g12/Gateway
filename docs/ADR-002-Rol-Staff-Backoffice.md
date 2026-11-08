# ADR-002: Rol staff y acceso al backoffice de la plataforma

- **Estado:** Aceptado. Backoffice en etapa 0: la app existe y todas sus funciones dicen "próximamente"
  hasta tener su endpoint. Las reglas de la §4 aplican a cada endpoint de staff que se agregue.
- **Alcance:** Auth0 (Action de login, `app_metadata`, aplicaciones), API Gateway (Kong, `auth0_validator.lua`),
  servicios con endpoints de staff (Auth-User, Server-Roles, Notification-Audit), Discordia-WebApp
  (`apps/backoffice` y el link desde `apps/web`), Terraform (Cloudflare Pages y DNS)
- **Relacionado:** ADR-001 de este repo (validación de identidad y propagación de `X-User-Role`), ADR-002 de
  Auth-User-Service (suspensión de usuarios y corte de sesiones)

---

## 1. Contexto

La consigna pide un **backoffice web** como componente aparte del cliente web, para el staff de la
plataforma: suspender y reactivar usuarios, listar, suspender y eliminar servidores, expedientes de
investigación, métricas globales y estado de la plataforma e incidentes. El staff es un rol global,
independiente de los roles de cada servidor, y el grupo tiene que dar un mecanismo para otorgarlo por
fuera de la interfaz (para que el corrector pueda entrar).

Publicada en `backoffice.discordia.lol` y construida por etapas: cada función se ve con su
forma final, deshabilitada con "próximamente", hasta que exista su endpoint de staff.

Varias piezas ya existían antes de este ADR:

- La Action de login ([`auth0/post-login-action.js`](../auth0/post-login-action.js)) lee `app_metadata.role` y lo
  pone en el **access token** como `https://discordia.app/role`. Si no hay rol, pone `"user"`.
- [`auth0_validator.lua`](../auth0_validator.lua) verifica el token, lee ese claim (con `"user"` por defecto),
  responde 403 si la ruta exige un rol que el token no tiene y propaga `X-User-Role` al servicio. Antes de
  validar borra los headers `X-User-*` que mande el cliente.
- [`kong.yml`](../kong.yml) ya exige `validate("staff", false)` en `/api/v1/audit` y `/api/v1/metrics`.

## 2. Decisión

| # | Tema | Decisión |
|---|------|----------|
| 1 | Fuente del rol | `app_metadata.role` de Auth0, con valores `"user"` o `"staff"`. Solo se cambia desde el Dashboard o la Management API: es el mecanismo "por fuera de la interfaz" que pide la consigna. **Nunca** `user_metadata`: el usuario puede editar el suyo. |
| 2 | Transporte | Claim `https://discordia.app/role` del access token, el que emite la Action. No se agrega otro claim ni otro nombre de rol. |
| 3 | Autorización | La hace **solo el backend**. Kong exige `validate("staff", false)` en cada ruta de staff y el servicio vuelve a chequear `X-User-Role == "staff"` (defensa en profundidad). |
| 4 | App | `apps/backoffice` en el monorepo de Discordia-WebApp, en **`backoffice.discordia.lol`** (proyecto de Cloudflare Pages propio). Comparte `@discordia/core`, `@discordia/tokens` y el catálogo de componentes de la web, así que tiene la misma estética. Solo web: no hay backoffice en mobile. |
| 5 | Login | **Aplicación de Auth0 propia** ("Discordia Backoffice") con Universal Login. La Action rechaza el login de esa aplicación si el rol no es `staff` (`api.access.deny("staff_only")`, secret `BACKOFFICE_CLIENT_ID`). Misma API (audience) que la web: Kong valida el token igual. |
| 6 | Interfaz | El backoffice lee el claim del access token, sin verificar la firma, **solo para mostrar o no** su contenido; si no es staff, muestra "sin acceso". El token vive en memoria (no en `sessionStorage`). Nunca trae datos reales en el código: todo llega por la API. |
| 7 | Web | El menú de usuario de la web muestra el link "backoffice ↗" solo al staff (`useIsPlatformStaff` de `packages/core/src/auth/roles.ts`). Es un atajo; no da acceso a nada. |

Leer el claim del access token, y no del ID token, garantiza que la interfaz muestre lo mismo que el
Gateway va a permitir.

### Por qué un dominio aparte

- **Aislamiento del navegador:** otro origen no comparte almacenamiento ni cookies con
  `app.discordia.lol`. Un XSS en la web (por ejemplo, en el contenido de un mensaje) no llega a la sesión de
  un staff en el backoffice.
- **Rechazo en Auth0:** con su propia aplicación, un usuario común ni siquiera obtiene un token para el
  backoffice. Se puede exigir MFA solo ahí.
- **Headers más estrictos:** `apps/backoffice/public/_headers` pone `noindex`, `frame-ancestors 'none'` y una
  CSP que solo permite la API y Auth0.
- **Deploy independiente:** un cambio en el backoffice no toca la app de los usuarios.

## 3. Por qué ocultar la pantalla en el front no protege nada

Todo el código del front se descarga en el navegador, y ahí manda el usuario. Cualquiera puede ver la
interfaz del backoffice sin ser staff:

- editando el JS descargado (Chrome → Sources → Overrides) para que el chequeo de rol dé `true`;
- con un breakpoint, cambiando el valor a mano;
- con React DevTools, cambiando el estado de la sesión;
- en desarrollo, con el modo mock.

**Hoy no expone nada:** el backoffice no tiene datos; sus listados están vacíos.

**Con datos reales tampoco, si se cumple la §4:** los datos llegan solo por la API. Con un token falso, Kong
verifica la firma contra Auth0 y responde 401. Con un token real de un usuario común, responde 403. Quien
fuerce la pantalla ve el esqueleto vacío o con errores.

## 4. Reglas para los endpoints del backoffice

Checklist para cada PR que agregue un endpoint de staff:

1. **Ruta propia en Kong con `validate("staff", false)`**, por ejemplo `/api/v1/admin/users` hacia Auth-User y
   `/api/v1/admin/servers` hacia Server-Roles. Nunca dejar un endpoint de staff dentro de una ruta que use
   `validate(nil, ...)`: cualquier usuario autenticado llegaría a él.
2. **El servicio también chequea el rol**: rechaza con 403 si `X-User-Role != "staff"` (en Auth-User, una
   dependencia en `app/api/deps.py`). Así un error en `kong.yml` no abre el backoffice.
3. **Los servicios solo aceptan tráfico de Kong.** Kong borra los `X-User-*` del cliente, pero quien llegue
   directo a un servicio puede mandar `X-User-Role: staff`.
   - En desarrollo, `docker-compose.yml` publica los puertos de los servicios (8004, 8002, 8003, 3000, 3001):
     cualquiera en la red local puede saltarse Kong.
   - En producción, `deploy/docker-compose.yml` también publica puertos y confía en los Security Groups
     ("solo Kong"). Hay que verificar en `infra/terraform` que estén cerrados a todo lo demás.
4. **Nada de datos de staff en endpoints comunes**, por ejemplo el email o el estado de suspensión de otros
   usuarios en `/api/v1/users`, "total, el front no lo muestra".
5. **Nada de datos reales en el front.** Cada función se conecta con un hook de React Query contra la API, y
   se habilita pasándola a `'ready'` en `apps/backoffice/src/features.ts`.
6. **Registro de auditoría de cada acción de staff**: quién, qué, sobre quién, el motivo y la fecha. Es la base
   del expediente y la forma de detectar abusos del propio staff. Va por el Outbox (ADR-005 de Auth-User) hacia
   Notification-Audit.
7. **El front muestra bien un 401 o un 403** ("sin permiso"), y los estados de carga y de error que pide la
   consigna para la capa de presentación.
8. **Tests:** sin token da 401, con rol `user` da 403 y con `staff` da 200, para cada ruta nueva. En el Gateway,
   en `tests/test_auth0_validator.py`, que ya cubre el header `X-User-Role` falsificado. En cada servicio, el
   chequeo propio de la regla 2.
9. **Suspender un usuario** sigue el ADR-002 de Auth-User-Service: bloqueo en Auth0, lista de bloqueados en
   Redis consultada desde `auth0_validator.lua`, `is_suspended` y el evento `user.suspended`. Sin la lista de
   bloqueados, el suspendido sigue usando su token hasta que vence.

## 5. Configuración de Auth0

- Asignar `app_metadata.role = "staff"` a las cuentas de staff (y a la del corrector). El rol se lee al
  iniciar sesión: hay que salir y volver a entrar.
- La Action tiene que estar desplegada y agregada al flujo de Login. Si no, todos quedan como `"user"`.
- Aplicación **Discordia Backoffice** (Single Page Application):
  - Allowed Callback URLs: `http://localhost:5174/callback`, `https://backoffice.discordia.lol/callback`
  - Allowed Logout URLs y Allowed Web Origins: `http://localhost:5174`, `https://backoffice.discordia.lol`
  - Acceso a la API `https://api.discordia.com`
  - Su client ID, como secret `BACKOFFICE_CLIENT_ID` de la Action
- Access token de vida corta (5 a 15 minutos, como pide el ADR-002 de Auth-User). El rol queda fijo en el token:
  si se le saca `staff` a alguien, lo conserva hasta que el token venza o se le revoquen las sesiones.
- Recomendado: pedir MFA en el login del backoffice (en la Action, `api.multifactor.enable('any')` para esa
  aplicación), con algún factor habilitado en el tenant.
- Credenciales M2M de la Management API con permisos mínimos (las usa Auth-User para bloquear usuarios).

## 6. Alternativas descartadas

- **Pantalla dentro de la web (y de mobile).** Fue el primer prototipo. La consigna pide el backoffice como
  componente aparte, y compartir el origen con la app de los usuarios expone la sesión del staff a cualquier
  falla de la web.
- **Ruta `/admin` dentro de la web.** Misma desventaja de origen compartido, sin login propio en Auth0.
- **Repo aparte para el backoffice.** Duplicaría el cliente de la API, los tokens de diseño y los
  componentes. En el monorepo se comparten sin publicar paquetes.
- **Roles de Auth0 (RBAC) en un claim nuevo (`https://discordia.app/roles`, lista).** El Gateway ya funcionaba
  con `app_metadata.role` y un solo claim. Dos esquemas en paralelo hacen que el front y Kong puedan no coincidir.
- **Leer el rol del ID token en el front.** El ID token no es lo que valida Kong: la interfaz podría mostrar algo
  que el Gateway rechaza, o al revés.
- **Endpoint `/me` con el rol.** Agrega una llamada al arrancar para algo que ya trae el token.

## 7. Consecuencias

- Un solo lugar define quién es staff (`app_metadata.role`) y un solo lugar lo hace cumplir (Kong y el servicio).
- El backoffice lee el rol al iniciar la sesión. Un cambio de rol se ve al volver a entrar.
- Hay un segundo proyecto de Cloudflare Pages, una aplicación más en Auth0 y dos orígenes más en el CORS de
  Kong (`https://backoffice.discordia.lol` y `http://localhost:5174`).
- Las cuentas staff dependen de que la Action esté desplegada: es lo primero a revisar si un staff no ve el
  backoffice.

## 8. Estado de implementación

| Pieza | Estado |
|-------|--------|
| `app_metadata.role` → claim `https://discordia.app/role` en la Action | Implementado |
| `auth0_validator.lua`: rol requerido, `X-User-Role`, borrado de headers del cliente | Implementado (con tests) |
| Rutas staff `/api/v1/audit` y `/api/v1/metrics` | Implementado |
| App `apps/backoffice`, etapa 0 (todo "próximamente" salvo los links a Grafana) | Implementado |
| CORS de Kong para el backoffice | Implementado |
| Rechazo de no staff en la Action (`staff_only`) | Implementado; falta el secret `BACKOFFICE_CLIENT_ID` en Auth0 |
| Aplicación "Discordia Backoffice" en Auth0 | Pendiente |
| Proyecto de Pages y DNS de `backoffice.discordia.lol` (`infra/terraform/pages.tf`) | Escrito; falta `terraform apply` |
| Asignar `staff` a las cuentas del equipo y del corrector en Auth0 | Pendiente |
| Vida corta del access token y MFA para staff | Pendiente |
| Suspender y reactivar usuarios: ruta `/api/v1/admin/users` (staff) y rechazo de cuentas suspendidas en `auth0_validator.lua` (lista en Redis, ADR-002 de Auth-User) | Implementado (con tests) |
| Suspender servidores: ruta `/api/v1/admin/servers` (staff) hacia Server-Roles (ADR-002 de Server-Roles). El bloqueo del servidor lo hace Server-Roles, no Kong | Implementado (con tests) |
| Resto de los endpoints de backoffice (listado de usuarios, servidores, expedientes, métricas, incidentes) | Pendiente (por etapas, con la §4) |
| Chequeo de rol en cada servicio (regla 2) | Implementado en Auth-User (`require_staff`); pendiente en los demás, con sus endpoints |
| Verificar que los Security Groups cierren los puertos de los servicios (regla 3) | Pendiente |
| Registro de auditoría de acciones de staff (regla 6) | Pendiente |
