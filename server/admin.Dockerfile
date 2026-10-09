# Build context is the repository root: the image needs dashboard/ and server/.
#   docker build -f server/admin.Dockerfile .
# The .dockerignore file (admin.Dockerfile.dockerignore) requires BuildKit.

FROM node:24-alpine AS web
WORKDIR /web
COPY dashboard/package.json dashboard/package-lock.json ./
RUN npm ci
COPY dashboard/ ./
RUN npm run build

# CGO_ENABLED=0 works because modernc.org/sqlite is pure Go.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
# The SPA is embedded into the binary; only .gitkeep is committed there.
COPY --from=web /web/dist/ ./internal/admin/web/dist/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pawlet-admin ./cmd/pawlet-admin

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/pawlet-admin /pawlet-admin
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/pawlet-admin"]
