local openidc = require "resty.openidc"

-- Verifica los access tokens emitidos por Auth0 para las rutas del Gateway.

local M = {}

local AUTH0_DOMAIN = os.getenv("AUTH0_DOMAIN")
local AUTH0_AUDIENCE = os.getenv("AUTH0_AUDIENCE")
local AUTH0_ROLE_CLAIM = os.getenv("AUTH0_ROLE_CLAIM") or "https://discordia.app/role"
local AUTH0_EMAIL_CLAIM = os.getenv("AUTH0_EMAIL_CLAIM") or "https://discordia.app/email"

local ISSUER = AUTH0_DOMAIN and ("https://" .. AUTH0_DOMAIN .. "/") or nil
local JWKS_URI = AUTH0_DOMAIN and ("https://" .. AUTH0_DOMAIN .. "/.well-known/jwks.json") or nil

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
  -- allow_query_arg solo debe venir en true desde las rutas /ws/*: el
  -- handshake de WebSocket del navegador no puede mandar headers custom.
  if allow_query_arg then
    return kong.request.get_query_arg("token")
  end
  return nil
end

-- require_role: opcional (ej. "staff") para rutas de backoffice/audit.
-- allow_query_arg: true únicamente en las rutas de WebSocket.
function M.validate(require_role, allow_query_arg)
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
  local claims, err = openidc.bearer_jwt_verify({
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

  kong.service.request.set_header("X-User-Id", tostring(claims.sub))
  if email then
    kong.service.request.set_header("X-User-Email", tostring(email))
  else
    kong.log.warn("[auth0_validator] token sin claim de email (", AUTH0_EMAIL_CLAIM, "); X-User-Email no se propaga")
  end
  kong.service.request.set_header("X-User-Role", tostring(role))
end

return M