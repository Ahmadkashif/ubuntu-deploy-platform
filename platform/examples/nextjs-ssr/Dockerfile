# syntax=docker/dockerfile:1.7
FROM node:24.21.0-alpine AS build
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
ARG SHIP_VERSION=dev
ENV SHIP_VERSION=${SHIP_VERSION}
RUN npm run build

# Runtime: Node 24 LTS, standalone server only; npm/yarn removed (not needed at runtime, and their bundled deps
# are the usual source of scanner findings). Non-root, read-only rootfs friendly (.next/cache is a tmpfs).
FROM node:24.21.0-alpine
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 HOSTNAME=0.0.0.0 PORT=3000
COPY --from=build --chown=node:node /src/.next/standalone ./
COPY --from=build --chown=node:node /src/.next/static ./.next/static
COPY --from=build --chown=node:node /src/public ./public
USER node
EXPOSE 3000
CMD ["node", "server.js"]
