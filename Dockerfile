FROM alpine:latest

RUN apk add --no-cache bash
COPY scripts /tmp/scripts
COPY init_scripts /init_scripts

COPY tini /tmp/scripts/tini
ENTRYPOINT ["/init_scripts/run.sh"]
