# CGO_ENABLED=0 works because modernc.org/sqlite is pure Go (no cgo required).
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pawletd ./cmd/pawletd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/pawletd /pawletd
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/pawletd"]
