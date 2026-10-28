# ADR-002: Rol staff y acceso al backoffice de la plataforma

- **Estado:** Aceptado para el MVP (prototipo sin endpoints). Las reglas de la §4 aplican a los endpoints de
  backoffice que se agreguen después.
- **Fecha:** 2026-10-28
- **Alcance:** Auth0 (Action de login, `app_metadata`), API Gateway (Kong, `auth0_validator.lua`), servicios
  con endpoints de staff (Auth-User, Server-Roles, Notification-Audit), Discordia-WebApp (web y mobile)
- **Relacionado:** ADR-001 de este repo (validación de identidad y propagación de `X-User-Role`), ADR-002 de
  Auth-User-Service (suspensión de usuarios y corte de sesiones)

---

## 1. Contexto

El backoffice de administración (suspender y reactivar usuarios, listar y suspender o eliminar servidores,
expedientes de investigación) está en el front como **MVP**: web y mobile muestran la pantalla con datos de
ejemplo y todas las acciones deshabilitadas ("próximamente"). Los endpoints son tareas aparte.

La pantalla tiene que verla solo el staff de la plataforma. Varias piezas ya existían antes de este ADR:

- La Action de login ([`auth0/post-login-action.js`](../auth0/post-login-action.js)) lee `app_metadata.role` y lo
  pone en el **access token** como `https://discordia.app/role`. Si no hay rol, pone `"user"`.
- [`auth0_validator.lua`](../auth0_validator.lua) verifica el token, lee ese claim (con `"user"` por defecto),
  responde 403 si la ruta exige un rol que el token no tiene y propaga `X-User-Role` al servicio. Antes de
  validar borra los headers `X-User-*` que mande el cliente.
- [`kong.yml`](../kong.yml) ya exige `validate("staff", false)` en `/api/v1/audit` y `/api/v1/metrics`.

## 2. Decisión

| # | Tema | Decisión |
|---|------|----------|
| 1 | Fuente del rol | `app_metadata.role` de Auth0, con valores `"user"` o `"staff"`. Solo se cambia desde el Dashboard o la Management API. **Nunca** `user_metadata`: el usuario puede editar el suyo. |
| 2 | Transporte | Claim `https://discordia.app/role` del access token, el que emite la Action. No se agrega otro claim ni otro nombre de rol. |
| 3 | Autorización | La hace **solo el backend**. Kong exige `validate("staff", false)` en cada ruta de staff y el servicio vuelve a chequear `X-User-Role == "staff"` (defensa en profundidad). |
| 4 | Front | Lee el mismo claim del access token, sin verificar la firma, **solo para mostrar u ocultar** el backoffice (`packages/core/src/auth/roles.ts`: `useIsPlatformStaff`). No decide permisos y no lleva datos reales. |

Que web y mobile lean el claim del access token, y no del ID token, garantiza que la interfaz muestre lo mismo
que el Gateway va a permitir.

## 3. Por qué ocultar la pantalla en el front no protege nada

Todo el código del front se descarga en el navegador o en el teléfono, y ahí manda el usuario. Cualquiera puede
mostrar el backoffice sin ser staff:

- editando el JS descargado (Chrome → Sources → Overrides) para que `useIsPlatformStaff()` devuelva `true`;
- con un breakpoint en esa función, cambiando el valor a mano;
- con React DevTools, cambiando el estado de los componentes;
- armando un token falso con `role: "staff"` y guardándolo en `sessionStorage` (la web guarda ahí el token y el
  front no verifica la firma).

**Hoy no expone nada:** la pantalla solo muestra datos de ejemplo que ya vienen en el JS.

**Con datos reales tampoco, si se cumple la §4:** los datos llegan solo por la API. Con el token falso, Kong
verifica la firma contra Auth0 y responde 401. Con un token real de un usuario común, responde 403. Quien fuerce
la pantalla ve el esqueleto vacío o con errores.

## 4. Reglas para los endpoints del backoffice

Checklist para cada PR que agregue un endpoint de staff:

1. **Ruta propia en Kong con `validate("staff", false)`**, por ejemplo bajo `/api/v1/admin/*` en cada servicio.
   Nunca dejar un endpoint de staff dentro de una ruta que use `validate(nil, ...)`: cualquier usuario
   autenticado llegaría a él.
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
5. **Nada de datos reales en el front.** Los datos de ejemplo de `packages/core/src/admin/backoffice.ts` se
   reemplazan por hooks de React Query contra la API, no por datos fijos.
6. **Registro de auditoría de cada acción de staff**: quién, qué, sobre quién, el motivo y la fecha. Es la base
   del expediente y la forma de detectar abusos del propio staff. Va por el Outbox (ADR-005 de Auth-User) hacia
   Notification-Audit.
7. **El front muestra bien un 401 o un 403** ("sin permiso"), como la sección Baneos de los ajustes del servidor.
8. **Tests:** sin token da 401, con rol `user` da 403 y con `staff` da 200, para cada ruta nueva. En el Gateway,
   en `tests/test_auth0_validator.py`, que ya cubre el header `X-User-Role` falsificado. En cada servicio, el
   chequeo propio de la regla 2.
9. **Suspender un usuario** sigue el ADR-002 de Auth-User-Service: bloqueo en Auth0, lista de bloqueados en
   Redis consultada desde `auth0_validator.lua`, `is_suspended` y el evento `user.suspended`. Sin la lista de
   bloqueados, el suspendido sigue usando su token hasta que vence.

## 5. Configuración de Auth0

- Asignar `app_metadata.role = "staff"` a las cuentas de staff.
- La Action tiene que estar desplegada y agregada al flujo de Login. Si no, todos quedan como `"user"`.
- Access token de vida corta (5 a 15 minutos, como pide el ADR-002 de Auth-User). El rol queda fijo en el token:
  si se le saca `staff` a alguien, lo conserva hasta que el token venza o se le revoquen las sesiones.
- Recomendado: pedir MFA a las cuentas staff desde la Action (si el rol es `staff`, `api.multifactor.enable('any')`).
- Credenciales M2M de la Management API con permisos mínimos (las usa Auth-User para bloquear usuarios).

## 6. Alternativas descartadas

- **Roles de Auth0 (RBAC) en un claim nuevo (`https://discordia.app/roles`, lista).** El Gateway ya funcionaba
  con `app_metadata.role` y un solo claim. Dos esquemas en paralelo hacen que el front y Kong puedan no coincidir.
- **Leer el rol del ID token en el front.** El ID token no es lo que valida Kong: la interfaz podría mostrar algo
  que el Gateway rechaza, o al revés.
- **Endpoint `/me` con el rol.** Agrega una llamada al arrancar para algo que ya trae el token.

## 7. Consecuencias

- Un solo lugar define quién es staff (`app_metadata.role`) y un solo lugar lo hace cumplir (Kong y el servicio).
- El front lee el rol al iniciar la sesión. Un cambio de rol se ve en la interfaz al volver a iniciar sesión.
- Las cuentas staff dependen de que la Action esté desplegada: es lo primero a revisar si un staff no ve el
  backoffice.

## 8. Estado de implementación

| Pieza | Estado |
|-------|--------|
| `app_metadata.role` → claim `https://discordia.app/role` en la Action | Implementado |
| `auth0_validator.lua`: rol requerido, `X-User-Role`, borrado de headers del cliente | Implementado (con tests) |
| Rutas staff `/api/v1/audit` y `/api/v1/metrics` | Implementado |
| Front: backoffice MVP visible solo para `staff` (web y mobile) | Implementado |
| Asignar `staff` a las cuentas del equipo en Auth0 | Pendiente |
| Vida corta del access token y MFA para staff | Pendiente |
| Endpoints de backoffice (usuarios, servidores, expedientes) | Pendiente (tareas aparte, con la §4) |
| Chequeo de rol en cada servicio (regla 2) | Pendiente (con los endpoints) |
| Verificar que los Security Groups cierren los puertos de los servicios (regla 3) | Pendiente |
| Registro de auditoría de acciones de staff (regla 6) | Pendiente |
