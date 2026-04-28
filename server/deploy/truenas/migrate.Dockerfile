# Migration runner image: goose + the migrations directory.
# Build context is `server/`. Used by docker-compose `migrate` profile.

FROM golang:1.25-alpine AS build
RUN go install github.com/pressly/goose/v3/cmd/goose@latest

FROM alpine:3.20
COPY --from=build /go/bin/goose /usr/local/bin/goose
WORKDIR /migrations
COPY migrations /migrations
# Use shell form so $DATABASE_URL expands at container runtime.
ENTRYPOINT ["/bin/sh", "-c", "goose -dir /migrations postgres \"$DATABASE_URL\" \"$@\"", "--"]
CMD ["up"]
