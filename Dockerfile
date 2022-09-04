FROM alpine

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
	&& apk add --update ca-certificates curl

RUN curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
	&& chmod +x tini
RUN wget -c https://github.com/wal-g/wal-g/releases/download/v2.0.1/wal-g-pg-ubuntu-20.04-amd64.tar.gz -O - | tar -xz \
    && chmod +x wal-g-pg-ubuntu-20.04-amd64 \
    && mv wal-g-pg-ubuntu-20.04-amd64 wal-g

FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/postgres-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
COPY --from=0 /tini /tmp/scripts/tini
COPY --from=0 /wal-g /tmp/scripts/wal-g
COPY role_scripts /tmp/role_scripts

ENTRYPOINT ["/init_scripts/run.sh"]
