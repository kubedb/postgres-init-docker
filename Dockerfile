FROM alpine:latest

RUN apk add --no-cache bash

COPY ./scripts /scripts

ENTRYPOINT ["/scripts/run.sh"]
