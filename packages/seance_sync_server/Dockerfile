# Séance sync server — build the single static-ish binary, then a slim runtime.
# Build context is the REPOSITORY ROOT (so the pub workspace resolves):
#   docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .

# ---- build stage ----
FROM dart:stable AS build
WORKDIR /app

# Copy workspace + member manifests first for dependency-layer caching.
COPY pubspec.yaml pubspec.lock analysis_options.yaml ./
COPY packages/seance_protocol/pubspec.yaml packages/seance_protocol/pubspec.yaml
COPY packages/seance_core/pubspec.yaml packages/seance_core/pubspec.yaml
COPY packages/seance_sync_server/pubspec.yaml packages/seance_sync_server/pubspec.yaml
RUN dart pub get

# Copy sources and compile to a native executable.
COPY packages/seance_protocol packages/seance_protocol
COPY packages/seance_core packages/seance_core
COPY packages/seance_sync_server packages/seance_sync_server
RUN dart pub get
RUN dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart \
      -o /app/seance-sync

# ---- runtime stage ----
FROM debian:stable-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/seance-sync /usr/local/bin/seance-sync

# Sensible, locked-down defaults. Override via env or CLI flags.
ENV SEANCE_BIND=0.0.0.0 \
    SEANCE_PORT=8787 \
    SEANCE_DB_PATH=/data/seance.sqlite \
    SEANCE_OPEN_REGISTRATION=false
RUN mkdir -p /data
VOLUME /data
EXPOSE 8787

# Run as a non-root user.
RUN useradd --system --uid 10001 seance && chown -R seance /data
USER seance

ENTRYPOINT ["/usr/local/bin/seance-sync"]
