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

log() {
    printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

if [ -z "$STREAM_URL" ]; then
    log "ERROR: STREAM_URL is not set."
    log "Set it in Dockhand under the stack's environment variables, for example:"
    log "  STREAM_URL=https://live.vkvideo.ru/CHANNEL"
    exit 1
fi

mkdir -p "$HLS_DIR" "$RECORD_DIR" || {
    log "ERROR: cannot create $HLS_DIR / $RECORD_DIR"
    exit 1
}

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

nginx -g 'daemon off;' &
nginx_pid=$!
log "nginx started (pid $nginx_pid)"

# ---------------------------------------------------------------------------
# The stream pipeline
# ---------------------------------------------------------------------------

attempt=0
while :; do
    attempt=$((attempt + 1))
    log "starting streamlink (attempt $attempt)"

    # A unique file name per attempt. streamlink asks for confirmation before
    # overwriting an existing file and, without a TTY, that prompt turns into
    # an error and a non-zero exit. The attempt counter keeps the name unique
    # even when two attempts start within the same second.
    stamp="$(date -u '+%Y%m%d-%H%M%S')"
    record_file="$RECORD_DIR/stream-$stamp-$attempt.ts"

    # The stream is passed to ffmpeg through a FIFO rather than a plain pipe.
    # That way both process ids are known explicitly and can be terminated
    # individually on shutdown, without relying on process groups.
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

    # --stdout writes the raw stream to stdout, which is redirected into the
    # fifo and consumed by ffmpeg.
    # --record tees the very same bytes into the recording file.
    # --retry-streams keeps streamlink retrying while the channel is offline
    # instead of exiting immediately.
    streamlink \
        --stdout \
        --record="$record_file" \
        --retry-streams "$RETRY_STREAMS" \
        --loglevel info \
        $STREAMLINK_ARGS \
        "$STREAM_URL" "$STREAM_QUALITY" > "$FIFO_PATH" &
    streamlink_pid=$!

    # Wait for streamlink to finish. If it exits, ffmpeg sees the end of the
    # fifo and exits as well. The pipeline is then restarted, so that the
    # container recovers when the channel goes offline and comes back online.
    wait "$streamlink_pid"
    pipeline_status=$?
    streamlink_pid=""

    # Make sure ffmpeg is gone before the next attempt starts.
    kill -TERM "$ffmpeg_pid" 2>/dev/null
    wait "$ffmpeg_pid" 2>/dev/null
    ffmpeg_pid=""
    rm -f "$FIFO_PATH"

    if [ "$shutting_down" -eq 1 ]; then
        break
    fi

    log "pipeline exited with status $pipeline_status; restarting in $RESTART_DELAY"
    # Sleep in the background and wait for it, so that a SIGTERM arriving
    # during the delay is handled immediately instead of after the delay.
    sleep "$RESTART_DELAY" &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=""
done
