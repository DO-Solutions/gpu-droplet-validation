FROM alpine:3.20
RUN apk add --no-cache bash jq
COPY containers/tap-reporter/tap-reporter.sh /tap-reporter.sh
RUN chmod +x /tap-reporter.sh
ENTRYPOINT ["/tap-reporter.sh"]
