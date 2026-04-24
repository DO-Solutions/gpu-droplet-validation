FROM alpine:3.20
RUN apk add --no-cache bash jq
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/test-mock/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
