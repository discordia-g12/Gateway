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
