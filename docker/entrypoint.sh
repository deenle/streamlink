#!/bin/bash
#
# Container entrypoint.
#
# Turns a single environment variable (STREAM_URL) into a running pipeline:
#   streamlink --> stdout --> ffmpeg --> HLS segments --> nginx --> Jellyfin
#              \-> --record --> recording on the NAS dataset

set -uo pipefail

# ---------------------------------------------------------------------------
# Global Configuration & Defaults
# ---------------------------------------------------------------------------

USER_ID="${UID:-1000}"
GROUP_ID="${GID:-1000}"
STREAM_URL="${STREAM_URL:-}"
STREAM_QUALITY="${STREAM_QUALITY:-best}"
CHANNEL_NAME="${CHANNEL_NAME:-Stream}"
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
HLS_DIR="${HLS_DIR:-/srv/www/hls}"
RECORD_DIR="/records"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"
RETRY_STREAMS="${RETRY_STREAMS:-10}"
RESTART_DELAY="${RESTART_DELAY:-5}"
FIFO_PATH="${FIFO_PATH:-/tmp/streamlink.fifo}"
STREAMLINK_ARGS="${STREAMLINK_ARGS:-}"
ENABLE_RECORDING="${ENABLE_RECORDING:-true}"

log() {
    printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# ---------------------------------------------------------------------------
# Pipeline Logic (Runs as unprivileged user)
# ---------------------------------------------------------------------------

start_pipeline() {
    local nginx_pid=""
    local streamlink_pid=""
    local ffmpeg_pid=""
    local sleep_pid=""
    local shutting_down=0

    cleanup() {
        shutting_down=1
        log "shutting down"
        [ -n "$streamlink_pid" ] && kill -TERM "$streamlink_pid" 2>/dev/null
        [ -n "$ffmpeg_pid" ] && kill -TERM "$ffmpeg_pid" 2>/dev/null
        [ -n "$sleep_pid" ] && kill -TERM "$sleep_pid" 2>/dev/null
        [ -n "$nginx_pid" ] && kill -TERM "$nginx_pid" 2>/dev/null
        wait 2>/dev/null
        log "stopped"
        exit 0
    }

    trap cleanup TERM INT

    # Start nginx in background
    nginx -g 'daemon off;' &
    nginx_pid=$!
    log "nginx started (pid $nginx_pid)"

    # Derive a safe filename from the STREAM_URL
    # This removes http(s):// and replaces all non-alphanumeric chars with underscores
    local url_safe_name
    url_safe_name=$(echo "$STREAM_URL" | sed -E 's|^https?://||; s|[^a-zA-Z0-9_-]|_|g')

    local attempt=0
    while :; do
        attempt=$((attempt + 1))
        log "starting streamlink (attempt $attempt)"

        local stamp
        stamp="$(date -u '+%Y%m%d-%H%M%S')"
        local record_file="$RECORD_DIR/${url_safe_name}_${STREAM_QUALITY}_$stamp-$attempt.ts"

        rm -f "$FIFO_PATH"
        mkfifo "$FIFO_PATH" || {
            log "ERROR: cannot create fifo $FIFO_PATH"
            break
        }

        # Start ffmpeg to consume the FIFO and output HLS
        ffmpeg -hide_banner -loglevel warning -i "$FIFO_PATH" -c copy \
            -f hls \
            -hls_time "$HLS_TIME" \
            -hls_list_size "$HLS_LIST_SIZE" \
            -hls_delete_threshold 1 \
            -hls_flags delete_segments+omit_endlist+independent_segments \
            -hls_start_number_source epoch \
            -hls_segment_filename "$HLS_DIR/seg_%05d.ts" \
            "$HLS_DIR/live.m3u8" &
        ffmpeg_pid=$!

        local record_args=""
        if [ "$ENABLE_RECORDING" = "true" ]; then
            record_args="--record=\"$record_file\""
        fi

        # Start streamlink to fill the FIFO
        streamlink \
            --stdout \
            $record_args \
            --retry-streams "$RETRY_STREAMS" \
            --loglevel info \
            $STREAMLINK_ARGS \
            "$STREAM_URL" "$STREAM_QUALITY" > "$FIFO_PATH" &
        streamlink_pid=$!

        wait "$streamlink_pid"
        local pipeline_status=$?
        streamlink_pid=""

        kill -TERM "$ffmpeg_pid" 2>/dev/null
        wait "$ffmpeg_pid" 2>/dev/null
        ffmpeg_pid=""
        rm -f "$FIFO_PATH"

        if [ "$shutting_down" -eq 1 ]; then
            break
        fi

        log "pipeline exited with status $pipeline_status; restarting in $RESTART_DELAY"
        sleep "$RESTART_DELAY" &
        sleep_pid=$!
        wait "$sleep_pid"
        sleep_pid=""
    done
}

# ---------------------------------------------------------------------------
# Root Setup & Execution Entrypoint
# ---------------------------------------------------------------------------

# If the first argument is 'start-pipeline', skip setup and run the logic
if [ "${1:-}" = "start-pipeline" ]; then
    start_pipeline
    exit 0
fi

log "Configuring container for UID: $USER_ID, GID: $GROUP_ID"

if [ "$USER_ID" = "0" ]; then
    log "Running as root, skipping user creation."
    SUDO_USER_REQUIRED=0
else
    groupadd -g "$GROUP_ID" streamlink_user || true
    useradd -u "$USER_ID" -g "$GROUP_ID" -m -s /usr/sbin/nologin streamlink_user || true
    SUDO_USER_REQUIRED=1
fi

mkdir -p /srv/www/hls /records
chown -R "$USER_ID:$GROUP_ID" /srv/www /records

# Validate required variables
if [ -z "$STREAM_URL" ]; then
    log "ERROR: STREAM_URL is not set."
    exit 1
fi

# Update nginx config and channel metadata
sed -i "s/listen 8080;/listen $CONTAINER_PORT;/" /etc/nginx/nginx.conf
safe_channel_name="${CHANNEL_NAME//[\"\\\\]/}"
echo "set \$channel_name \"$safe_channel_name\";" > /tmp/nginx-channel.conf

log "STREAM_URL=$STREAM_URL"
log "quality=$STREAM_QUALITY channel=$CHANNEL_NAME"

if [ "$SUDO_USER_REQUIRED" = "1" ]; then
    # Re-execute this script as the dynamic user, passing the start-pipeline flag
    exec gosu streamlink_user "$0" start-pipeline
else
    exec bash "$0" start-pipeline
fi
