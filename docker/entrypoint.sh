#!/bin/bash
#
# Container entrypoint.
#
# Turns a single environment variable (STREAM_URL) into a running pipeline:
#
#   streamlink --> stdout --> ffmpeg --> HLS segments --> nginx --> Jellyfin
#              \-> --record --> recording on the NAS dataset
#
# Both the recording and the HLS output come from the same upstream connection:
# streamlink tees the stream to its --record file and to stdout, and ffmpeg
# segments the stdout stream into HLS.

set -uo pipefail

# ---------------------------------------------------------------------------
# User Identity Setup
# ---------------------------------------------------------------------------

# Get UID/GID from environment variables, default to 1000.
USER_ID="${UID:-1000}"
GROUP_ID="${GID:-1000}"

log() {
    printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

log "Configuring container for UID: $USER_ID, GID: $GROUP_ID"

if [ "$USER_ID" = "0" ]; then
    log "Running as root (UID 0), skipping user creation."
    # We set a flag to tell gosu to skip
    SUDO_USER_REQUIRED=0
else
    # Create the group and user dynamically.
    groupadd -g "$GROUP_ID" streamlink_user || true
    useradd -u "$USER_ID" -g "$GROUP_ID" -m -s /usr/sbin/nologin streamlink_user || true
    SUDO_USER_REQUIRED=1
fi

# Ensure shared directories exist and are owned by the dynamic user.
mkdir -p /srv/www/hls /records
chown -R "$USER_ID:$GROUP_ID" /srv/www /records

# ---------------------------------------------------------------------------
# Application Configuration
# ---------------------------------------------------------------------------

STREAM_URL="${STREAM_URL:-}"
STREAM_QUALITY="${STREAM_QUALITY:-best}"
CHANNEL_NAME="${CHANNEL_NAME:-Stream}"
HLS_DIR="${HLS_DIR:-/srv/www/hls}"
RECORD_DIR="${RECORD_DIR:-/records}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"
RETRY_STREAMS="${RETRY_STREAMS:-10}"
# Seconds to wait before restarting a pipeline that exited.
RESTART_DELAY="${RESTART_DELAY:-5}"
# Named pipe that connects streamlink's stdout to ffmpeg's input.
FIFO_PATH="${FIFO_PATH:-/tmp/streamlink.fifo}"
# Extra arguments appended to the streamlink command line.
STREAMLINK_ARGS="${STREAMLINK_ARGS:-}"

if [ -z "$STREAM_URL" ]; then
    log "ERROR: STREAM_URL is not set."
    log "Set it in your environment variables, for example:"
    log "  STREAM_URL=https://live.vkvideo.ru/CHANNEL"
    exit 1
fi

# nginx reads the channel name from this file at request time, so it can be
# changed without restarting nginx. Quotes and backslashes are stripped,
# because the name is embedded in an nginx config file.
safe_channel_name="${CHANNEL_NAME//[\"\\\\]/}"
cat > /tmp/nginx-channel.conf <<EOF
set \$channel_name "$safe_channel_name";
EOF

log "STREAM_URL=$STREAM_URL"
log "quality=$STREAM_QUALITY channel=$CHANNEL_NAME"

# ---------------------------------------------------------------------------
# Process supervision
# ---------------------------------------------------------------------------

nginx_pid=""
streamlink_pid=""
ffmpeg_pid=""
sleep_pid=""
shutting_down=0

cleanup() {
    shutting_down=1
    log "shutting down"
    # Terminate both ends of the pipeline, so that neither streamlink nor
    # ffmpeg outlives the container.
    [ -n "$streamlink_pid" ] && kill -TERM "$streamlink_pid" 2>/dev/null
    [ -n "$ffmpeg_pid" ] && kill -TERM "$ffmpeg_pid" 2>/dev/null
    [ -n "$sleep_pid" ] && kill -TERM "$sleep_pid" 2>/dev/null
    [ -n "$nginx_pid" ] && kill -TERM "$nginx_pid" 2>/dev/null
    wait 2>/dev/null
    log "stopped"
    exit 0
}

trap cleanup TERM INT

if [ "$SUDO_USER_REQUIRED" = "1" ]; then
    # Use gosu to wrap the entire supervision loop as the dynamic user.
    # This ensures nginx, ffmpeg, and streamlink all run as the correct UID.
    RUN_CMD="gosu streamlink_user bash"
else
    # Run as root
    RUN_CMD="bash"
fi

exec $RUN_CMD <<'EOF'
    # We need to re-import the variables and functions inside the heredoc
    # since gosu/bash starts a new shell.
    set -uo pipefail

    # Re-calculate variables inside the user shell
    STREAM_URL="${STREAM_URL:-}"
    STREAM_QUALITY="${STREAM_QUALITY:-best}"
    CHANNEL_NAME="${CHANNEL_NAME:-Stream}"
    HLS_DIR="${HLS_DIR:-/srv/www/hls}"
    RECORD_DIR="${RECORD_DIR:-/records}"
    HLS_TIME="${HLS_TIME:-4}"
    HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"
    RETRY_STREAMS="${RETRY_STREAMS:-10}"
    RESTART_DELAY="${RESTART_DELAY:-5}"
    FIFO_PATH="${FIFO_PATH:-/tmp/streamlink.fifo}"
    STREAMLINK_ARGS="${STREAMLINK_ARGS:-}"

    log() {
        printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
    }

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
    shutting_down=0
    nginx_pid=""
    streamlink_pid=""
    ffmpeg_pid=""
    sleep_pid=""

    nginx -g 'daemon off;' &
    nginx_pid=$!
    log "nginx started (pid $nginx_pid)"

    attempt=0
    while :; do
        attempt=$((attempt + 1))
        log "starting streamlink (attempt $attempt)"

        stamp="$(date -u '+%Y%m%d-%H%M%S')"
        # Sanitize channel name for filename (remove spaces and special characters)
        safe_filename_channel="${CHANNEL_NAME//[^a-zA-Z0-9_-]/_}"
        # Use quality and channel name in the filename for better organization.
        record_file="$RECORD_DIR/${safe_filename_channel}_${STREAM_QUALITY}_$stamp-$attempt.ts"

        rm -f "$FIFO_PATH"
        mkfifo "$FIFO_PATH" || {
            log "ERROR: cannot create fifo $FIFO_PATH"
            break
        }

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

        streamlink \
            --stdout \
            --record="$record_file" \
            --retry-streams "$RETRY_STREAMS" \
            --loglevel info \
            $STREAMLINK_ARGS \
            "$STREAM_URL" "$STREAM_QUALITY" > "$FIFO_PATH" &
        streamlink_pid=$!

        wait "$streamlink_pid"
        pipeline_status=$?
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
EOF
