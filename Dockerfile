FROM alpine:latest

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
ENV PV /var/pv
VOLUME ["$PV"]
RUN chown -R 70:70 /var/pv

COPY tini /tmp/scripts/tini
ENTRYPOINT ["/init_scripts/run.sh"]
