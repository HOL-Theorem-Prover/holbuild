# The remote-exec coordinator and worker. Build from this directory:
#   docker build -t holbuild-remote-exec .
# See README.md for running it.

ARG PYTHON_IMAGE=python:3.14-slim-trixie

FROM ${PYTHON_IMAGE} AS polyml
# The same Poly/ML as holbuild's CI.
ARG POLYML_REPO=https://github.com/sequent-dev-bot/polyml.git
ARG POLYML_TAG=v5.9.2-seq6
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

WORKDIR /opt/remote-exec
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-default-groups
COPY alembic.ini entrypoint.sh ./
COPY remote_exec remote_exec/
# tini reaps the processes holbuild orphans, which the worker as PID 1 would leave as zombies.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/remote-exec/entrypoint.sh"]
