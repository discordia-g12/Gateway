FROM kong:3.4
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      lua5.1 luarocks ca-certificates \
 && update-ca-certificates \
 && /usr/bin/luarocks install --tree=/usr/local lua-resty-openidc 1.7.6-3
USER kong
