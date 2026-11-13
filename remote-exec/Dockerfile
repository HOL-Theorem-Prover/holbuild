# The remote-exec coordinator and worker. Build from this directory:
#   docker build -t holbuild-remote-exec .
# See README.md for running it.

ARG PYTHON_IMAGE=python:3.14-slim-trixie

FROM ${PYTHON_IMAGE} AS polyml
# The workers' Poly/ML, also release.yml's POLYML_TAG. It stays on seq7
# while CI (setup-polyml) is on seq8: a worker Poly change makes every
# shared heap cold at once, so it waits until clients send releases that
# publish each cold heap once (0.14.38+).
ARG POLYML_REPO=https://github.com/sequent-dev-bot/polyml.git
ARG POLYML_TAG=v5.9.2-seq7
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates git libgmp-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone -b "$POLYML_TAG" --depth 1 "$POLYML_REPO" /src/polyml \
 && cd /src/polyml \
 && ./configure --prefix=/opt/polyml \
 && make -j"$(nproc)" \
 && make install

FROM ${PYTHON_IMAGE}
# A C toolchain and GMP for polyc, which builds holbuild and HOL; git, curl and zstd for holbuild itself.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates curl git libgmp-dev libseccomp2 tini zstd \
 && rm -rf /var/lib/apt/lists/*
COPY --from=polyml /opt/polyml /opt/polyml
COPY --from=ghcr.io/astral-sh/uv:0.13.4 /uv /usr/local/bin/uv
# The worker's temporary files (the cache credential, action results) stay out
# of /tmp, which sandboxed HOL processes may write: Poly/ML puts its own there.
ENV PATH=/opt/remote-exec/.venv/bin:/opt/polyml/bin:$PATH \
    HOLBUILD_CACHE=/var/cache/holbuild \
    TMPDIR=/var/tmp \
    UV_PYTHON_DOWNLOADS=never

# With HOLBUILD_VERSION set (say 0.14.37), the image bakes that release where
# the worker looks first, so a fresh host doesn't build it before its first
# action (README "holbuild releases"). It is built as the worker builds one:
# the tag's source archive, compiled where it runs from.
ARG HOLBUILD_VERSION=
RUN if [ -n "$HOLBUILD_VERSION" ]; then \
      dir=/opt/holbuild-baked/v$HOLBUILD_VERSION \
   && mkdir -p "$dir" \
   && curl -fsSL "https://github.com/HOL-Theorem-Prover/holbuild/archive/refs/tags/v$HOLBUILD_VERSION.tar.gz" \
      | tar xz --strip-components=1 -C "$dir" \
   && make -C "$dir" bin/holbuild; \
    fi

WORKDIR /opt/remote-exec
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-default-groups
COPY alembic.ini entrypoint.sh ./
COPY remote_exec remote_exec/
# tini reaps the processes holbuild orphans, which the worker as PID 1 would leave as zombies.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/remote-exec/entrypoint.sh"]
