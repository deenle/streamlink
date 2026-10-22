# Running streamlink on TrueNAS with Dockhand

This container runs streamlink, serves the stream as an HLS playlist for Jellyfin's
Live TV (M3U) tuner, and records the stream to your NAS at the same time.

```
                    ┌── stdout ──→ ffmpeg ──→ HLS segments ──→ nginx ──→ Jellyfin
STREAM_URL ──→ streamlink ──┤
                    └── --record ──→ recording .ts on your dataset
```

Both outputs come from a single upstream connection.

## Deploying

1. Push this repository to your Git server and add it in Dockhand as a **git stack**.
2. Point the stack at `docker-compose.yml` and enable **"Build images on deploy"**,
   so the image is rebuilt from the `Dockerfile` in this repository.
3. In the stack's **environment variables**, set the stream link:

   ```
   STREAM_URL=https://live.vkvideo.ru/CHANNEL
   ```

   That is the only value you have to set. Optionally:

   | Variable        | Default   | Meaning                                              |
   |-----------------|-----------|------------------------------------------------------|
   | `STREAM_URL`    | *(none)*  | The stream to watch. **Required.**                    |
   | `STREAM_QUALITY`| `best`    | Quality, e.g. `best`, `worst`, `720p`.                |
   | `CHANNEL_NAME`  | `Stream`  | Channel name shown in Jellyfin's guide.               |
   | `RECORDINGS_DIR`| `./recordings` | Host path for recordings. Point at a dataset.   |
   | `HOST_PORT`     | `8097`    | Host port that Jellyfin connects to. Not 8096 — that is Jellyfin's own port. |

4. Deploy. In Jellyfin, add a **Live TV → M3U** source pointing at
   `http://<truenas-ip>:<HOST_PORT>/playlist.m3u8`.

The URL in the M3U playlist is generated from the `Host` header of the request, so it
always matches the address Jellyfin used to reach the container.

## Notes

- The recording lands in `RECORDINGS_DIR` as `stream-<timestamp>-<n>.ts` (MPEG-TS).
  A new file is started whenever the stream reconnects.
- The container restarts the stream automatically when the channel goes offline and
  comes back, so a permanent container restart is not needed.
- `streamlink` is built from this repository, so any change to the plugins in
  `src/streamlink/plugins/` is picked up by the next image build. The plugin metadata
  and its checksum are regenerated during the build.

## Building the image by hand

```sh
docker build -t streamlink-vk:local .
docker run --rm -e STREAM_URL=https://live.vkvideo.ru/CHANNEL \
    -v "$PWD/recordings:/records" -p 8097:8080 streamlink-vk:local
```

## Troubleshooting

- `ERROR: STREAM_URL is not set.` — the environment variable did not reach the
  container. In Dockhand, variables set in the environment panel are *not* injected
  automatically; the compose file maps them explicitly with `environment:`.
- The channel does not appear in Jellyfin — check the container log for
  "Found matching plugin" and confirm that `playlist.m3u8` is reachable from the
  Jellyfin host.
- The stream is not recorded — check that `RECORDINGS_DIR` is writable by the
  container user (uid/gid `1000` by default; set `UID`/`GID` in the compose file's
  build args to match the owner of the dataset).
