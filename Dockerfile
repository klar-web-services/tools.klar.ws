# Read-only proxy in front of the release bucket. CI pushes it to GHCR once the
# tests pass. Set S3_ORIGIN at runtime: the bucket URL, e.g.
# https://<bucket>.<s3-endpoint-host>
FROM nginx:1.30.6-alpine-slim@sha256:f65ed258206d1eb6c4eb6141111715a2cf94ac0a4ec9675fc2da186f7aadb163

ENV S3_CACHE_VALID=1m \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    NGINX_ENVSUBST_FILTER='^(S3_|NGINX_LOCAL_RESOLVERS$)'

COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --chmod=755 nginx/05-tools-proxy.sh /docker-entrypoint.d/05-tools-proxy.sh

# The reverse proxy only routes to healthy containers, so check early after
# start (start-interval) to keep redeploys to a few seconds.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s --start-interval=2s \
    CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

LABEL org.opencontainers.image.source=https://github.com/klar-web-services/tools.klar.ws
