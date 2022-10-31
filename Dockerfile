FROM golang:alpine AS builder

ARG TARGETOS
ARG TARGETARCH

ENV WALG_VERSION=v2.0.1

ENV _build_deps="wget cmake git build-base bash curl xz-dev lzo-dev"

RUN set -ex  \
     && apk add --no-cache $_build_deps

RUN set -ex \
    && cd / \
    && curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
	&& chmod +x tini

RUN set -ex  \
     && git clone https://github.com/wal-g/wal-g/  $GOPATH/src/wal-g \
     && cd $GOPATH/src/wal-g/ \
     && git checkout $WALG_VERSION \
     && make pg_clean \
     && make deps \
     && make pg_build \
     && install main/pg/wal-g / \
     && /wal-g --help \
     && chmod +x /wal-g
#RUN wget -c https://github.com/wal-g/wal-g/releases/download/v2.0.1/wal-g-pg-ubuntu-20.04-amd64.tar.gz -O - | tar -xz \
# && chmod +x wal-g-pg-ubuntu-20.04-amd64 \
# && mv wal-g-pg-ubuntu-20.04-amd64 /usr/local/bin/wal-g

FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/postgres-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
COPY --from=builder /tini /tmp/scripts/tini
COPY --from=builder /wal-g /tmp/scripts/wal-g
COPY role_scripts /tmp/role_scripts

ENTRYPOINT ["/init_scripts/run.sh"]

