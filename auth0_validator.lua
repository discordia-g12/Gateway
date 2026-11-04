local openidc = require "resty.openidc"
local ok_http, http = pcall(require, "resty.http")
local ok_json, cjson = pcall(require, "cjson.safe")

-- Verifica los access tokens emitidos por Auth0 para las rutas del Gateway.

local M = {}

local AUTH0_DOMAIN = os.getenv("AUTH0_DOMAIN")
local AUTH0_AUDIENCE = os.getenv("AUTH0_AUDIENCE")
local AUTH0_ROLE_CLAIM = os.getenv("AUTH0_ROLE_CLAIM") or "https://discordia.app/role"
local AUTH0_EMAIL_CLAIM = os.getenv("AUTH0_EMAIL_CLAIM") or "https://discordia.app/email"
local AUTH0_EMAIL_VERIFIED_CLAIM = os.getenv("AUTH0_EMAIL_VERIFIED_CLAIM") or "https://discordia.app/email_verified"
local AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL")
if not AUTH_SERVICE_URL or AUTH_SERVICE_URL == "" then
  AUTH_SERVICE_URL = "http://auth-service:8000"
end

local ISSUER = AUTH0_DOMAIN and ("https://" .. AUTH0_DOMAIN .. "/") or nil
local JWKS_URI = AUTH0_DOMAIN and ("https://" .. AUTH0_DOMAIN .. "/.well-known/jwks.json") or nil

local IDENTITY_HEADERS = {
  "X-User-Id",
  "X-User-Email",
  "X-User-Email-Verified",
  "X-User-Role",
}

function M.strip_identity_headers()
  for _, name in ipairs(IDENTITY_HEADERS) do
    kong.service.request.clear_header(name)
  end
end

local function reject(status, detail)
  kong.log.warn("[auth0_validator] ", detail)
  local titles = {
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [500] = "Internal Server Error",
  }
  local problem = {
    ["type"] = "about:blank",
    title = titles[status] or "Error",
    status = status,
    detail = detail,
    instance = kong.request.get_path(),
  }
  return kong.response.exit(status, problem, {["Content-Type"] = "application/problem+json"})
end

local function extract_bearer_token(allow_query_arg)
  local auth_header = kong.request.get_header("Authorization")
  if auth_header then
    local token = string.match(auth_header, "^Bearer%s+(.+)$")
    if token then
      return token
    end
  end
  -- allow_query_arg solo debe venir en true desde las rutas WebSocket: el
  -- handshake de WebSocket del navegador no puede mandar headers custom.
  if allow_query_arg then
    return kong.request.get_query_arg("token")
  end
  return nil
end

local function resolve_email_verified(claims)
  local value = claims[AUTH0_EMAIL_VERIFIED_CLAIM]
  if value == nil then
    value = claims.email_verified
  end
  if value == true or value == "true" then
    return "true"
  end
  return "false"
end

local function resolve_canonical_user_id(sub, email, verified_str)
  if not email or email == "" or verified_str ~= "true" then
    return sub
  end

  local dict = ngx and ngx.shared and ngx.shared.jwks or nil
  local cache_key = "uid:" .. tostring(sub) .. ":" .. tostring(email)
  if dict then
    local cached = dict:get(cache_key)
    if cached and cached ~= "" then
      return cached
    end
  end

  if not ok_http or not http or not ok_json or not cjson then
    return sub
  end

  local httpc = http.new()
  if not httpc then
    return sub
  end
  httpc:set_timeout(1500)

  local url = AUTH_SERVICE_URL .. "/api/v1/users/resolve-identity"
  local res, err = httpc:request_uri(url, {
    method = "GET",
    headers = {
      ["X-User-Id"] = tostring(sub),
      ["X-User-Email"] = tostring(email),
      ["X-User-Email-Verified"] = tostring(verified_str),
    },
  })

  if not res or res.status ~= 200 or not res.body then
    if err then
      kong.log.warn("[auth0_validator] resolve-identity failed: ", tostring(err))
    end
    return sub
  end

  local data = cjson.decode(res.body)
  if data and type(data.user_id) == "string" and data.user_id ~= "" then
    if dict and data.found == true then
      dict:set(cache_key, data.user_id, 300)
    end
    return data.user_id
  end

  return sub
end

-- require_role: opcional (ej. "staff") para rutas de backoffice/audit.
-- allow_query_arg: true únicamente en las rutas de WebSocket.
function M.validate(require_role, allow_query_arg)
  M.strip_identity_headers()

  -- Las peticiones preflight de CORS (OPTIONS) son enviadas por el navegador sin headers
  -- de autenticación. Deben retornar inmediatamente para que el plugin de CORS de Kong
  -- las responda con 200/204 y los headers Access-Control-Allow-*.
  if kong.request.get_method() == "OPTIONS" then
    return
  end

  if not ISSUER or not JWKS_URI or not AUTH0_AUDIENCE then
    kong.log.err("[auth0_validator] faltan AUTH0_DOMAIN / AUTH0_AUDIENCE")
    return reject(500, "Gateway misconfigured")
  end

  local token = extract_bearer_token(allow_query_arg)
  if not token then
    return reject(401, "Missing token")
  end

  -- lua-resty-openidc solo busca la clave pública en la JWKS cuando
  -- opts.discovery es una tabla (o una URL de discovery a resolver) — un
  -- campo suelto "jwks_uri" en el nivel superior de opts es ignorado en
  -- silencio, dejando la verificación de firma sin clave (de ahí el
  -- confuso "No trusted certs loaded" que en realidad no tenía nada que
  -- ver con certificados).
  local claims, err = openidc.jwt_verify(token, {
    discovery = { jwks_uri = JWKS_URI },
    jwk_expires_in = 3600,
  })

  if err or not claims then
    return reject(401, "Invalid or expired token: " .. tostring(err))
  end

  -- bearer_jwt_verify no valida el issuer por su cuenta (solo lo hace en
  -- el flujo completo de login vía openidc.authenticate), así que lo
  -- chequeamos acá a mano.
  if claims.iss ~= ISSUER then
    return reject(401, "Token issuer mismatch")
  end

  -- Auth0 solo emite un JWT (en vez de un token opaco) cuando la app
  -- cliente pidió el token especificando "audience" en la request de
  -- autorización. Si este chequeo falla de forma sistemática, típicamente
  -- el cliente no está mandando el audience correcto.
  local aud_ok = false
  local aud = claims.aud
  if type(aud) == "table" then
    for _, a in ipairs(aud) do
      if a == AUTH0_AUDIENCE then aud_ok = true end
    end
  elseif aud == AUTH0_AUDIENCE then
    aud_ok = true
  end
  if not aud_ok then
    return reject(401, "Token audience mismatch")
  end

  if not claims.sub then
    return reject(401, "Token missing 'sub' claim")
  end

  local role = claims[AUTH0_ROLE_CLAIM] or "user"

  if require_role and role ~= require_role then
    return reject(403, "Forbidden: " .. require_role .. " only")
  end

  -- El access token de una API custom (audience != OIDC estándar) NO trae
  -- el claim "email" aunque el cliente haya pedido el scope "email": ese
  -- scope solo afecta al ID token. Por eso primero buscamos el claim
  -- namespaced que agrega la Auth0 Action del login flow, y sólo si no
  -- está, caemos al claim estándar "email" (por si algún día cambia el
  -- flujo de emisión y sí llega directo).
  local email = claims[AUTH0_EMAIL_CLAIM] or claims.email
  local verified_str = resolve_email_verified(claims)
  local canonical_id = resolve_canonical_user_id(tostring(claims.sub), email, verified_str)

  kong.service.request.set_header("X-User-Id", canonical_id)
  if email then
    kong.service.request.set_header("X-User-Email", tostring(email))
  else
    kong.log.warn("[auth0_validator] token sin claim de email (", AUTH0_EMAIL_CLAIM, "); X-User-Email no se propaga")
  end
  kong.service.request.set_header("X-User-Email-Verified", verified_str)
  kong.service.request.set_header("X-User-Role", tostring(role))
end

return M