FROM golang:alpine AS builder

ARG TARGETOS
ARG TARGETARCH

ENV WALG_VERSION="release-v2023.11.30"

ENV _build_deps="wget cmake git build-base bash curl xz-dev lzo-dev"

RUN set -ex  \
     && apk add --no-cache $_build_deps

RUN set -ex \
    && cd / \
    && curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
	&& chmod +x tini

RUN set -x \
  && git clone https://github.com/kubedb/wal-g.git \
  && cd wal-g \
  && git checkout $(WALG_VERSION) \
  && CGO_ENABLED=0 go build -v -o /wal-g ./main/pg/main.go

FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/postgres-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init_scripts /init_scripts
COPY --from=builder /tini /tmp/scripts/tini
COPY --from=builder /wal-g /tmp/scripts/wal-g
COPY role_scripts /tmp/role_scripts

ENTRYPOINT ["/init_scripts/run.sh"]
