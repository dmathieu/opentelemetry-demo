# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

FROM traefik:v3.6

COPY ./src/frontend-proxy/traefik.yaml /etc/traefik/traefik.yaml
COPY ./src/frontend-proxy/dynamic.yaml /etc/traefik/dynamic.yaml

EXPOSE 8080
EXPOSE 10000
