"""Tests del validador con kong/openidc mockeados (runtime Lua vía lupa).

Uso: pip install lupa pytest && pytest tests/
"""
from pathlib import Path

import pytest
from lupa import LuaRuntime

VALIDATOR = (Path(__file__).parent.parent / "auth0_validator.lua").read_text()
ISS = "https://tenant.auth0.com/"
AUD = "https://api.discordia.com"

HARNESS = r"""
local env = {AUTH0_DOMAIN="tenant.auth0.com", AUTH0_AUDIENCE="https://api.discordia.com"}
os.getenv = function(k) return env[k] end

state = {}
function reset(method, req_headers, claims, verify_err)
  state = {method=method, req_headers=req_headers or {}, upstream={}, exit=nil,
           claims=claims, verify_err=verify_err,
           suspended={}, redis_down=false, redis_queries={}, logged_errors=0}
  -- lo que llega del cliente arranca también en la request al upstream
  for k, v in pairs(state.req_headers) do state.upstream[k] = v end
end

-- Redis falso: state.suspended son las claves que existen, state.redis_queries lo que se consultó
package.preload["resty.redis"] = function()
  local client = {}
  client.__index = client
  function client.set_timeouts() end
  function client:connect()
    if state.redis_down then return nil, "connection refused" end
    return true
  end
  function client:exists(...)
    local count = 0
    for _, key in ipairs({...}) do
      table.insert(state.redis_queries, key)
      if state.suspended[key] then count = count + 1 end
    end
    return count
  end
  function client.set_keepalive() return true end
  function client.close() return true end
  return { new = function() return setmetatable({}, client) end }
end

package.preload["resty.openidc"] = function()
  return { jwt_verify = function(token, opts)
    if state.verify_err then return nil, state.verify_err end
    return state.claims, nil
  end }
end

kong = {
  log = { warn=function() end, err=function() state.logged_errors = state.logged_errors + 1 end },
  request = {
    get_method=function() return state.method end,
    get_header=function(n) return state.req_headers[n] end,
    get_query_arg=function() return nil end,
    get_path=function() return "/api/v1/users/me" end,
  },
  response = { exit=function(status, body) state.exit = {status=status, body=body}; return end },
  service = { request = {
    set_header=function(n, v) state.upstream[n] = v end,
    clear_header=function(n) state.upstream[n] = nil end,
  } },
}
"""


@pytest.fixture
def lua():
    rt = LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    mod = rt.execute(VALIDATOR)
    return rt, mod


def run(lua, *, method="GET", headers=None, claims=None, verify_err=None, role=None, suspended=(), redis_down=False):
    rt, mod = lua
    t = lambda d: rt.table_from(d) if d is not None else None  # noqa: E731
    rt.globals().reset(method, t(headers or {}), t(claims), verify_err)
    st = rt.globals().state
    st["suspended"] = rt.table_from({key: True for key in suspended})
    st["redis_down"] = redis_down
    mod.validate(role, False)
    exit_ = st.exit
    return dict(st.upstream), (exit_.status if exit_ else None)


def last_exit(lua):
    rt, _ = lua
    return rt.globals().state.exit


def claims(**extra):
    base = {"iss": ISS, "aud": AUD, "sub": "auth0|real"}
    base.update(extra)
    return base


SPOOF = {
    "Authorization": "Bearer x",
    "X-User-Id": "auth0|attacker",
    "X-User-Email": "victim@discordia.com",
    "X-User-Email-Verified": "true",
    "X-User-Role": "staff",
}


def test_spoofed_email_is_stripped_when_token_has_no_email(lua):
    up, status = run(lua, headers=SPOOF, claims=claims())
    assert status is None
    assert up["X-User-Id"] == "auth0|real"
    assert "X-User-Email" not in up  # el header del cliente NO sobrevive
    assert up["X-User-Email-Verified"] == "false"
    assert up["X-User-Role"] == "user"


def test_verified_namespaced_claims_are_propagated(lua):
    c = claims(**{"https://discordia.app/email": "me@d.com", "https://discordia.app/email_verified": True})
    up, _ = run(lua, headers=SPOOF, claims=c)
    assert up["X-User-Email"] == "me@d.com"
    assert up["X-User-Email-Verified"] == "true"


def test_unverified_email_propagates_false(lua):
    c = claims(**{"https://discordia.app/email": "me@d.com", "https://discordia.app/email_verified": False})
    up, _ = run(lua, headers=SPOOF, claims=c)
    assert up["X-User-Email"] == "me@d.com"
    assert up["X-User-Email-Verified"] == "false"


def test_standard_email_verified_claim_fallback(lua):
    up, _ = run(lua, headers={"Authorization": "Bearer x"}, claims=claims(email="s@d.com", email_verified=True))
    assert up["X-User-Email-Verified"] == "true"


@pytest.mark.parametrize("value", ["yes", 1, "True"])
def test_non_boolean_verified_values_fail_closed(lua, value):
    c = claims(**{"https://discordia.app/email_verified": value})
    up, _ = run(lua, headers={"Authorization": "Bearer x"}, claims=c)
    assert up["X-User-Email-Verified"] == "false"


def test_rejected_token_leaves_no_identity_headers(lua):
    up, status = run(lua, headers=SPOOF, verify_err="bad signature")
    assert status == 401
    assert not any(k.startswith("X-User-") for k in up)


def test_missing_token_leaves_no_identity_headers(lua):
    h = {k: v for k, v in SPOOF.items() if k != "Authorization"}
    up, status = run(lua, headers=h)
    assert status == 401
    assert not any(k.startswith("X-User-") for k in up)


def test_options_preflight_strips_headers(lua):
    up, status = run(lua, method="OPTIONS", headers=SPOOF)
    assert status is None
    assert not any(k.startswith("X-User-") for k in up)


def test_spoofed_staff_role_cannot_pass_staff_route(lua):
    up, status = run(lua, headers=SPOOF, claims=claims(), role="staff")
    assert status == 403


def test_strip_identity_headers_for_public_routes(lua):
    rt, mod = lua
    rt.globals().reset("GET", rt.table_from(SPOOF), None, None)
    mod.strip_identity_headers()
    up = dict(rt.globals().state.upstream)
    assert not any(k.startswith("X-User-") for k in up)
    assert up["Authorization"] == "Bearer x"


# ---------- Cuentas suspendidas (ADR-002 de Auth-User-Service) ----------

EMAIL_CLAIM = "https://discordia.app/email"


def test_suspended_identity_is_rejected_even_with_a_valid_token(lua):
    up, status = run(lua, headers=SPOOF, claims=claims(), suspended=["suspended:sub:auth0|real"])
    assert status == 403
    assert last_exit(lua).body["type"] == "https://discordia.app/problems/account-suspended"
    assert not any(k.startswith("X-User-") for k in up)


def test_suspended_email_is_rejected_for_a_new_federated_identity(lua):
    c = claims(sub="google-oauth2|new", **{EMAIL_CLAIM: "  Ana@Mail.COM "})
    _, status = run(lua, headers={"Authorization": "Bearer x"}, claims=c, suspended=["suspended:email:ana@mail.com"])
    assert status == 403


def test_suspension_is_checked_before_the_staff_role(lua):
    # Un staff suspendido tampoco entra al backoffice
    c = claims(**{"https://discordia.app/role": "staff"})
    _, status = run(lua, headers={"Authorization": "Bearer x"}, claims=c, role="staff",
                    suspended=["suspended:sub:auth0|real"])
    assert status == 403
    assert last_exit(lua).body["type"].endswith("/account-suspended")


def test_active_account_passes_and_both_keys_are_checked(lua):
    rt, _ = lua
    c = claims(**{EMAIL_CLAIM: "me@d.com"})
    up, status = run(lua, headers={"Authorization": "Bearer x"}, claims=c)
    assert status is None
    assert up["X-User-Id"] == "auth0|real"
    assert list(rt.globals().state.redis_queries.values()) == ["suspended:sub:auth0|real", "suspended:email:me@d.com"]


def test_without_email_only_the_identity_is_checked(lua):
    rt, _ = lua
    run(lua, headers={"Authorization": "Bearer x"}, claims=claims())
    assert list(rt.globals().state.redis_queries.values()) == ["suspended:sub:auth0|real"]


def test_redis_down_lets_the_request_through_and_logs(lua):
    rt, _ = lua
    up, status = run(lua, headers={"Authorization": "Bearer x"}, claims=claims(), redis_down=True)
    assert status is None
    assert up["X-User-Id"] == "auth0|real"
    assert rt.globals().state.logged_errors == 1


def test_rejected_tokens_never_reach_redis(lua):
    rt, _ = lua
    run(lua, headers=SPOOF, verify_err="bad signature")
    assert len(rt.globals().state.redis_queries) == 0


def test_preflight_never_reaches_redis(lua):
    rt, _ = lua
    run(lua, method="OPTIONS", headers=SPOOF)
    assert len(rt.globals().state.redis_queries) == 0
