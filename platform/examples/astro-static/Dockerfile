# syntax=docker/dockerfile:1.7
FROM node:24.21.0-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
ARG SHIP_VERSION=dev
ENV PUBLIC_SHIP_VERSION=${SHIP_VERSION} ASTRO_TELEMETRY_DISABLED=1
RUN npm run build

# Runtime: static-web-server (Apache-2.0/MIT, ~5 MB, no shell), non-root, /health for the kamal-proxy gate.
FROM joseluisq/static-web-server:2.44.0
COPY --from=build /src/dist /public
USER 65534:65534
EXPOSE 8080
CMD ["--port", "8080", "--root", "/public", "--health", "--log-level", "warn", "--compression", "true", "--cache-control-headers", "true"]
