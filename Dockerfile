FROM kong:3.4
USER root
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list 2>/dev/null || true \
    && apt-get update && apt-get install -y --no-install-recommends \
       lua5.1 luarocks ca-certificates \
    && update-ca-certificates \
    && /usr/bin/luarocks install --tree=/usr/local lua-resty-openidc 1.7.6-3

# La configuración va dentro de la imagen (antes se montaba como volumen): cada nodo corre
# exactamente lo que se probó. En local el compose puede seguir montándola encima para editar en vivo.
COPY kong.yml /etc/kong/kong.yml.tmpl
COPY auth0_validator.lua gateway_health.lua /usr/local/share/lua/5.1/
COPY nginx/shared-dicts.conf nginx/main-env.conf /etc/kong/
COPY render-config.sh /usr/local/bin/render-config.sh

# Configuración fija de Kong (igual en local y en producción); lo que cambia por ambiente va en el compose
ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/tmp/kong.yml \
    KONG_LUA_PACKAGE_PATH="/usr/local/share/lua/5.1/?.lua;;" \
    KONG_NGINX_HTTP_INCLUDE=/etc/kong/shared-dicts.conf \
    KONG_NGINX_MAIN_INCLUDE=/etc/kong/main-env.conf \
    KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=gateway_health,auth0_validator,resty.openidc \
    KONG_LUA_SSL_TRUSTED_CERTIFICATE=/etc/ssl/certs/ca-certificates.crt \
    KONG_LUA_SSL_VERIFY_DEPTH=5 \
    KONG_STATUS_LISTEN=0.0.0.0:8100

# Status API: /status y /metrics (plugin prometheus). No es el proxy: no se publica a internet; en
# producción solo lo alcanza el nodo infra (Prometheus) por Security Group. Ver ADR-003.
EXPOSE 8100

USER kong
ENTRYPOINT ["/usr/local/bin/render-config.sh"]
# Al definir ENTRYPOINT se pierde el CMD de la imagen base: se repite
CMD ["kong", "docker-start"]
