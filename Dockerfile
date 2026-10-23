# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.13
ARG STREAMLINK_VERSION=8.6.2

# ---------------------------------------------------------------------------
# Builder: compile the streamlink wheel and all of its dependencies
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine AS builder

ARG STREAMLINK_VERSION

RUN apk add --no-cache git

WORKDIR /src

COPY pyproject.toml setup.py MANIFEST.in README.md LICENSE ./
COPY build_backend/ ./build_backend/
COPY src/ ./src/

RUN printf '*.egg-info/\nbuild/\ndist/\n__pycache__/\n*.py[cod]\n' > .gitignore \
 && git init -q . \
 && git config --global user.email "build@local" \
 && git config --global user.name "build" \
 && git add -A \
 && git commit -qm "docker build" \
 && git tag -a "v${STREAMLINK_VERSION}" -m "${STREAMLINK_VERSION}"

RUN pip wheel --no-cache-dir --wheel-dir /wheels ".[decompress]"

# ---------------------------------------------------------------------------
# Runtime: the actual container
# ---------------------------------------------------------------------------

FROM python:${PYTHON_VERSION}-alpine AS runtime

RUN apk add --no-cache ffmpeg nginx su-exec

# Create a default user/group (UID 1000, GID 1000)
# This can be overridden at runtime with PUID/PGID env vars
RUN addgroup -g 1000 streamlink \
 && adduser -D -u 1000 -G streamlink -s /sbin/nologin streamlink

COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels "streamlink[decompress]" \
 && rm -rf /wheels

WORKDIR /srv/www

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /srv/www/hls /records /tmp/streamlink \
 && chown -R 1000:1000 /srv/www /records /tmp/streamlink

ENV STREAM_URL="" \
    STREAM_QUALITY="best" \
    CHANNEL_NAME="Stream" \
    HLS_DIR="/srv/www/hls" \
    RECORD_DIR="/records" \
    HLS_TIME="4" \
    HLS_LIST_SIZE="6" \
    RETRY_STREAMS="10" \
    RESTART_DELAY="5" \
    FIFO_PATH="/tmp/streamlink.fifo" \
    PUID=1000 \
    PGID=1000

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
