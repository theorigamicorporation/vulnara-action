FROM alpine:3.20

RUN apk add --no-cache bash curl jq tar ca-certificates

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
