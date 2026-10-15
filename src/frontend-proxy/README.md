# Frontend Proxy Service

This service acts as a reverse proxy (Traefik) for the various user-facing web
interfaces.

## Modifying the Traefik Configuration

The static configuration lives in `traefik.yaml` and the routes in
`dynamic.yaml`, both in this directory. Add a router, middleware and service in
`dynamic.yaml` to expose a new interface.
