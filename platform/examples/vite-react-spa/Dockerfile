# syntax=docker/dockerfile:1.7
FROM node:24.21.0-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
ARG SHIP_VERSION=dev
ENV SHIP_VERSION=${SHIP_VERSION}
RUN npm run build && printf '{"version":"%s"}\n' "$SHIP_VERSION" > dist/version.json

# Runtime: static-web-server with SPA fallback (deep links -> index.html), non-root, /health for the gate.
FROM joseluisq/static-web-server:2.44.0
COPY --from=build /src/dist /public
USER 65534:65534
EXPOSE 8080
CMD ["--port", "8080", "--root", "/public", "--page-fallback", "/public/index.html", "--health", "--log-level", "warn", "--compression", "true", "--cache-control-headers", "true"]
