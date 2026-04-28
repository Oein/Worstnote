# Multi-stage build for the Notee API server.
# Build: docker build -f server/deploy/Dockerfile -t notee-api:dev server

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/notee-api ./cmd/notee-api

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/notee-api /notee-api
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/notee-api"]
