# syntax=docker/dockerfile:1.7
# Edge image: Caddy + Coraza WAF (OWASP CRS loaded from pinned files) + CrowdSec bouncer (+AppSec) + rate limit.
# Distroless static base (no shell, no OS packages). All versions come from VERSIONS.env via build args.
ARG CADDY_BUILDER_IMAGE
ARG EDGE_BASE_IMAGE

FROM ${CADDY_BUILDER_IMAGE} AS build
ARG CADDY_VERSION
ARG CORAZA_CADDY_MODULE
ARG CROWDSEC_BOUNCER_HTTP_MODULE
ARG CROWDSEC_BOUNCER_APPSEC_MODULE
ARG RATELIMIT_MODULE
ARG CRS_VERSION
ARG CRS_SHA256
ENV CGO_ENABLED=0
# The builder sets XCADDY_SETCAP=1 (file capability on the binary) which breaks exec under
# cap_drop: [ALL] + no-new-privileges. Docker already lets containers bind <1024 (ip_unprivileged_port_start=0).
ENV XCADDY_SETCAP=0
RUN xcaddy build ${CADDY_VERSION} \
      --with ${CORAZA_CADDY_MODULE} \
      --with ${CROWDSEC_BOUNCER_HTTP_MODULE} \
      --with ${CROWDSEC_BOUNCER_APPSEC_MODULE} \
      --with ${RATELIMIT_MODULE} \
      --output /out/caddy \
 && /out/caddy list-modules > /out/modules.txt \
 && for m in http.handlers.waf http.handlers.crowdsec http.handlers.appsec http.handlers.rate_limit caddy.listeners.proxy_protocol; do \
      grep -qx "$m" /out/modules.txt || { echo "missing module $m"; exit 1; }; done
# OWASP CRS from the signed release asset, pinned by sha256 (fails the build on mismatch).
RUN wget -q -O /tmp/crs.tgz "https://github.com/coreruleset/coreruleset/releases/download/v${CRS_VERSION}/coreruleset-${CRS_VERSION}-minimal.tar.gz" \
 && echo "${CRS_SHA256}  /tmp/crs.tgz" | sha256sum -c - \
 && mkdir -p /out/coraza && tar -xzf /tmp/crs.tgz -C /out/coraza \
 && mv /out/coraza/coreruleset-${CRS_VERSION} /out/coraza/crs \
 && rm -rf /out/coraza/crs/docs /out/coraza/crs/rules/*.example
# Tiny static HTTP probe for healthchecks (distroless has no curl/wget).
COPY <<'GO' /hc/main.go
package main

import (
	"crypto/tls"
	"net/http"
	"os"
	"time"
)

func main() {
	c := http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	r, err := c.Get(os.Args[1])
	if err != nil || r.StatusCode >= 500 {
		os.Exit(1)
	}
}
GO
RUN cd /hc && go mod init hc >/dev/null 2>&1 && go build -trimpath -ldflags "-s -w" -o /out/httpcheck . \
 && mkdir -p /out/dirs/data /out/dirs/config /out/dirs/logs

FROM ${EDGE_BASE_IMAGE}
COPY --from=build /out/caddy /usr/bin/caddy
COPY --from=build /out/httpcheck /usr/bin/httpcheck
COPY --from=build /out/modules.txt /usr/share/caddy/modules.txt
COPY --from=build /out/coraza/crs /etc/coraza/crs
COPY --chown=65532:65532 --from=build /out/dirs/data /data
COPY --chown=65532:65532 --from=build /out/dirs/config /config
COPY --chown=65532:65532 --from=build /out/dirs/logs /var/log/caddy
COPY coraza.conf crs-setup.conf /etc/coraza/
ENV XDG_DATA_HOME=/data XDG_CONFIG_HOME=/config
USER 65532:65532
ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
