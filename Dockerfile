# syntax=docker/dockerfile:1

# Build arguments
ARG PYTHON_VERSION=3.13
ARG STREAMLINK_VERSION=8.6.2

# ---------------------------------------------------------------------------
# Builder: compile the streamlink wheel and all of its dependencies
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS builder

ARG STREAMLINK_VERSION

# git is required by versioningit to derive the version number from a tag.
# The other packages are the build requirements declared in pyproject.toml.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy only what is needed to build the package. The docs/, tests/ and
# completions/ trees are not required for a wheel build.
COPY pyproject.toml setup.py MANIFEST.in README.md LICENSE ./
COPY build_backend/ ./build_backend/
COPY src/ ./src/

# versioningit derives the version from a git tag, and this build context has no
# .git directory (see .dockerignore). Recreating a tagged repository is what
# makes versioningit emit a *static* version string into streamlink/_version.py
# via its onbuild hook. Without this, the built wheel would import versioningit
# at runtime, which is not installed in the runtime stage.
#
# The .gitignore keeps the build artifacts (egg-info, build/) out of the
# commit, otherwise the tree counts as dirty and the version comes out as
# "8.6.2+0.g<hash>.dirty" instead of a clean "8.6.2".
RUN printf '*.egg-info/\nbuild/\ndist/\n__pycache__/\n*.py[cod]\n' > .gitignore \
 && git init -q . \
 && git config --global user.email "build@local" \
 && git config --global user.name "build" \
 && git add -A \
 && git commit -qm "docker build" \
 && git tag -a "v${STREAMLINK_VERSION}" -m "${STREAMLINK_VERSION}"

# The "decompress" extra enables brotli/zstd compressed HLS segments.
RUN pip wheel --no-cache-dir --wheel-dir /wheels ".[decompress]"

# ---------------------------------------------------------------------------
# Runtime: the actual container
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS runtime

# ffmpeg segments the stream into HLS, nginx serves it to Jellyfin.
# gosu is used to drop root privileges to a dynamic UID/GID at runtime.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg nginx-extras gosu \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels "streamlink[decompress]" \
 && rm -rf /wheels

WORKDIR /srv/www

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV STREAM_URL="" \
    STREAM_QUALITY="best" \
    CHANNEL_NAME="Stream" \
    HLS_DIR="/srv/www/hls" \
    RECORD_DIR="/records" \
    HLS_TIME="4" \
    HLS_LIST_SIZE="6" \
    RETRY_STREAMS="10" \
    RESTART_DELAY="5" \
    FIFO_PATH="/tmp/streamlink.fifo"

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
