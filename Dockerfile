FROM crystallang/crystal:1.21-alpine AS builder
WORKDIR /build
COPY src ./src
RUN crystal build src/main.cr -o /contributor-mural --release --static --no-debug

FROM alpine:3.21
LABEL org.opencontainers.image.source="https://github.com/crystal-actions/contributor-mural"
LABEL org.opencontainers.image.description="Generate avatar-wall SVG art from GitHub users and contributors"
LABEL org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache git ca-certificates rsvg-convert font-dejavu
COPY --from=builder /contributor-mural /usr/local/bin/contributor-mural
ENTRYPOINT ["/usr/local/bin/contributor-mural"]
