# CGO_ENABLED=0 works because modernc.org/sqlite is pure Go (no cgo required).
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pawletd ./cmd/pawletd
RUN mkdir -p /data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/pawletd /pawletd
# Ship /data owned by nonroot. Docker initialises a named volume from the
# image's directory, ownership included; without this the volume is created
# root-owned and SQLite cannot create the database file (error 14).
COPY --from=build --chown=65532:65532 /data /data
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/pawletd"]
