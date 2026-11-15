"""Chequeos estáticos de kong.yml: rutas internas, rutas de staff y métricas (ADR-002 y ADR-003).

Uso: pip install pyyaml pytest && pytest tests/
"""
import re
from pathlib import Path

import pytest
import yaml

CONFIG = yaml.safe_load((Path(__file__).parent.parent / "kong.yml").read_text())
PRIVATE_RANGES = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.1"}
INTERNAL_READYZ = {
    "auth": "${AUTH_SERVICE_URL}/readyz",
    "server-roles": "${SERVER_ROLES_URL}/readyz",
    "chat": "${CHAT_ENGINE_URL}/readyz",
    "voice": "${VOICE_SIGNALING_URL}/readyz",
    "notification": "${NOTIFICATION_URL}/readyz",
    "payments": "${PAYMENTS_URL}/readyz",
}


def routes():
    for service in CONFIG["services"]:
        for route in service.get("routes", []):
            yield service, route


def plugin(route, name):
    return next((p for p in route.get("plugins", []) if p["name"] == name), None)


def access_code(route):
    pre = plugin(route, "pre-function")
    return pre["config"]["access"] if pre else []


def route_matching(path):
    """Ruta cuyo path (prefijo o regex de Kong) matchea `path`."""
    found = []
    for service, route in routes():
        for p in route.get("paths", []):
            if p.startswith("~"):
                if re.fullmatch(p[1:].rstrip("$"), path):
                    found.append((service, route))
            elif path.startswith(p):
                found.append((service, route))
    return found


@pytest.mark.parametrize("name,url", INTERNAL_READYZ.items())
def test_internal_readyz_routes_are_private_and_exact(name, url):
    matches = route_matching(f"/internal/readyz/{name}")
    assert len(matches) == 1, f"/internal/readyz/{name}: se esperaba una ruta, hay {len(matches)}"
    service, route = matches[0]

    assert service["url"] == url
    assert service["retries"] == 0
    assert all(service[t] <= 2000 for t in ("connect_timeout", "read_timeout", "write_timeout"))

    assert route["paths"] == [f"~/internal/readyz/{name}$"]  # path exacto, no prefijo
    assert route["strip_path"] is True
    assert route["methods"] == ["GET"]

    ip = plugin(route, "ip-restriction")
    assert ip is not None, "falta ip-restriction"
    assert set(ip["config"]["allow"]) == PRIVATE_RANGES
    assert "deny" not in ip["config"]
    assert ip["config"]["status"] == 403
    assert access_code(route) == ['require("auth0_validator").strip_identity_headers()']


def test_internal_paths_only_on_internal_routes():
    for _, route in routes():
        for p in route.get("paths", []):
            if "/internal/" in p:
                assert plugin(route, "ip-restriction"), f"{route['name']} expone {p} sin ip-restriction"


def test_admin_status_requires_staff():
    matches = route_matching("/api/v1/admin/status")
    assert len(matches) == 1
    service, route = matches[0]
    assert service["name"] == "notification-audit-service"
    assert route["strip_path"] is False
    assert access_code(route) == ['require("auth0_validator").validate("staff", false)']


@pytest.mark.parametrize(
    "path", ["/api/v1/admin/incidents", "/api/v1/admin/incidents/0b7c6c1e-1f1a-4c2e-9d55-1f2a3b4c5d6e/resolve"]
)
def test_admin_incidents_requires_staff(path):
    matches = route_matching(path)
    assert len(matches) == 1
    service, route = matches[0]
    assert service["name"] == "notification-audit-service"
    assert route["name"] == "admin-incidents"
    assert route["strip_path"] is False
    assert route["methods"] == ["GET", "POST", "OPTIONS"]
    assert access_code(route) == ['require("auth0_validator").validate("staff", false)']


def test_admin_metrics_requires_staff():
    # Métricas globales del backoffice: GET con ?from&to y OPTIONS para el preflight de CORS.
    matches = route_matching("/api/v1/admin/metrics")
    assert len(matches) == 1
    service, route = matches[0]
    assert service["name"] == "notification-audit-service"
    assert route["name"] == "admin-metrics"
    assert route["strip_path"] is False
    assert route["methods"] == ["GET", "OPTIONS"]
    assert access_code(route) == ['require("auth0_validator").validate("staff", false)']


def test_public_status_still_carries_incidents_without_identity():
    # El aviso de incidentes sale en /api/v1/status: pública, sin X-User-* del cliente.
    matches = route_matching("/api/v1/status")
    assert len(matches) == 1
    _, route = matches[0]
    assert access_code(route) == ['require("auth0_validator").strip_identity_headers()']


def test_admin_routes_never_accept_any_authenticated_user():
    # ADR-002 §4.1: un endpoint de staff nunca puede quedar en una ruta con validate(nil, ...)
    for _, route in routes():
        if any("/api/v1/admin" in p for p in route.get("paths", [])):
            code = " ".join(access_code(route))
            assert 'validate("staff"' in code, f"{route['name']} no exige staff"
            assert "validate(nil" not in code


def test_prometheus_only_global():
    # Las métricas salen por el Status API (:8100), nunca por una ruta o servicio del proxy
    for service in CONFIG["services"]:
        assert not plugin(service, "prometheus"), f"prometheus en el servicio {service['name']}"
        for route in service.get("routes", []):
            assert not plugin(route, "prometheus"), f"prometheus en la ruta {route['name']}"

    prom = [p for p in CONFIG["plugins"] if p["name"] == "prometheus"]
    assert len(prom) == 1
    assert prom[0]["config"]["per_consumer"] is False  # cardinalidad: sin label por consumer


def test_no_route_exposes_metrics_path():
    assert not route_matching("/metrics")


def test_admin_users_routes_to_auth_and_requires_staff():
    for path in ("/api/v1/admin/users/suspensions", "/api/v1/admin/users/suspended", "/api/v1/admin/users/x/suspension"):
        matches = route_matching(path)
        assert len(matches) == 1, f"{path}: se esperaba una ruta, hay {len(matches)}"
        service, route = matches[0]
        assert service["name"] == "auth-user-service"
        assert route["strip_path"] is False
        assert set(route["methods"]) == {"GET", "POST", "DELETE", "OPTIONS"}
        assert access_code(route) == ['require("auth0_validator").validate("staff", false)']


def test_admin_servers_routes_to_server_roles_and_requires_staff():
    for path in (
        "/api/v1/admin/servers/suspended",
        "/api/v1/admin/servers/0b6f6c1e-4b5a-4c3e-9d2a-1f2e3d4c5b6a",
        "/api/v1/admin/servers/0b6f6c1e-4b5a-4c3e-9d2a-1f2e3d4c5b6a/suspension",
    ):
        matches = route_matching(path)
        assert len(matches) == 1, f"{path}: se esperaba una ruta, hay {len(matches)}"
        service, route = matches[0]
        assert service["name"] == "server-core-service"
        assert route["strip_path"] is False
        assert set(route["methods"]) == {"GET", "POST", "DELETE", "OPTIONS"}
        assert access_code(route) == ['require("auth0_validator").validate("staff", false)']


def test_member_routes_never_catch_admin_paths():
    # /api/v1/servers (validate(nil)) no puede tomar /api/v1/admin/servers: el prefijo es distinto
    for _, route in routes():
        if route["name"] == "server-core-routes":
            assert not any(p.startswith("/api/v1/admin") for p in route["paths"])
def test_server_audit_logs_routes_to_notification_service():
    path = "/api/v1/servers/0b7c6c1e-1f1a-4c2e-9d55-1f2a3b4c5d6e/audit-logs"
    # Filtrar por regex routes
    found = [
        (s, r) for s, r in routes()
        if any(p.startswith("~") and re.search(p[1:].rstrip("$"), path) for p in r.get("paths", []))
    ]
    assert len(found) == 1
    service, route = found[0]
    assert service["name"] == "notification-audit-service"
    assert route["name"] == "server-audit-logs"
    assert route["strip_path"] is False
    assert route["regex_priority"] == 100
    assert set(route["methods"]) == {"GET", "OPTIONS"}
    assert access_code(route) == ['require("auth0_validator").validate(nil, false)']


def test_server_activity_metrics_routes_to_notification_service_without_shadowing_member_growth():
    metrics_path = "/api/v1/servers/0b7c6c1e-1f1a-4c2e-9d55-1f2a3b4c5d6e/metrics"
    growth_path = f"{metrics_path}/member-growth"

    found_metrics = [
        (s, r) for s, r in routes()
        if any(p.startswith("~") and re.search(p[1:], metrics_path) for p in r.get("paths", []))
    ]
    assert len(found_metrics) == 1
    service, route = found_metrics[0]
    assert service["name"] == "notification-audit-service"
    assert route["name"] == "server-activity-metrics"
    assert route["strip_path"] is False
    assert route["regex_priority"] == 100
    assert set(route["methods"]) == {"GET", "OPTIONS"}
    assert access_code(route) == ['require("auth0_validator").validate(nil, false)']

    shadowed_growth = [
        r["name"] for _, r in routes()
        if any(p.startswith("~") and re.search(p[1:], growth_path) for p in r.get("paths", []))
    ]
    assert "server-activity-metrics" not in shadowed_growth
