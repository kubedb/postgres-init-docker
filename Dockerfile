FROM busybox

COPY ./scripts /scripts
ENV SSL_MODE ""
ENV CLUSTER_AUTH_MODE ""

ENTRYPOINT ["/scripts/run.sh"]