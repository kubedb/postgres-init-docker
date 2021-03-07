FROM busybox

COPY ./scripts /scripts

ENTRYPOINT ["/scripts/run.sh"]