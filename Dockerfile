FROM tianon/toybox:0.8.4

COPY ./scripts /scripts

ENTRYPOINT ["/scripts/run.sh"]