# tinbox's server image, for Aiven Runtime or any container host. The first stage installs the Tin release named in
# TIN_VERSION (through ./tin) and builds the server; the second holds the binary and the CA certificates it needs to
# reach R2 and Postgres over TLS.
#   docker build -t tinbox .
#   docker run -p 8080:8080 -e DATABASE_URL=... -e TINBOX_S3_ENDPOINT=... tinbox
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY TIN_VERSION tin ./
# install the pinned Tin once, in its own layer, so a code change rebuilds without downloading it again
RUN ./tin version >/dev/null 2>&1 || ./tin help >/dev/null
COPY proto ./proto
COPY server ./server
RUN mkdir -p /out && ./tin build server/main.tin -o /out/tinbox

FROM debian:bookworm-slim
# the binary is static; it needs only the CA bundle, taken from the build stage
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN useradd --system --uid 10001 --home-dir /var/lib/tinbox --shell /usr/sbin/nologin tinbox \
	&& mkdir -p /var/lib/tinbox && chown tinbox /var/lib/tinbox
COPY --from=build /out/tinbox /usr/local/bin/tinbox
USER 10001
WORKDIR /var/lib/tinbox
ENV TINBOX_LISTEN=:8080
EXPOSE 8080
# run migrates the database first (migrate = true), so a fresh database needs no separate step
ENTRYPOINT ["/usr/local/bin/tinbox"]
CMD ["run"]
