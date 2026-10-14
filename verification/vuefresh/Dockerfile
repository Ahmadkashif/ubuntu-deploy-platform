# syntax=docker/dockerfile:1
# Build stage: install pinned deps from the committed lockfile and build the SPA
FROM node:24.21.0-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
ARG SHIP_VERSION=dev
ENV VITE_SHIP_VERSION=$SHIP_VERSION
RUN npm run build && printf '%s\n' "$SHIP_VERSION" > dist/version.txt

# Runtime: static-web-server (scratch-based image: no OS packages for the scan gate to flag;
# the -alpine variant failed the critical-CVE gate on libssl3/libcrypto3 3.5.7-r0), non-root,
# one port, /health, SPA fallback
FROM joseluisq/static-web-server:2.44.1
ARG SHIP_VERSION=dev
LABEL org.opencontainers.image.version=$SHIP_VERSION
COPY --from=build /src/dist /public
USER 1000:1000
EXPOSE 8081
ENV SERVER_PORT=8081 \
    SERVER_ROOT=/public \
    SERVER_HEALTH=true \
    SERVER_FALLBACK_PAGE=/public/index.html
CMD ["--port", "8081", "--root", "/public", "--health", "--page-fallback", "/public/index.html"]
