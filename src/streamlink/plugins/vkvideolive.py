"""
$description Russian live-streaming platform for gaming and esports, owned by VKontakte. Formerly called vkplay.
$url live.vkvideo.ru
$url live.vkplay.ru
$url vkplay.live
$type live, vod
$metadata id
$metadata author
$metadata category
$metadata title
"""

import re

from streamlink.logger import getLogger
from streamlink.plugin import Plugin, PluginError, pluginmatcher
from streamlink.plugin.api import validate
from streamlink.stream.hls import HLSStream
from streamlink.stream.http import HTTPStream


log = getLogger(__name__)


@pluginmatcher(
    name="slot",
    pattern=re.compile(
        r"https?://(?:live\.vk(?:video|play)\.ru|vkplay\.live)/(?P<channel_name>[\w.-]+)/stream/(?P<slot_name>[^/?#]+)",
    ),
)
@pluginmatcher(
    name="default",
    pattern=re.compile(
        r"https?://(?:live\.vk(?:video|play)\.ru|vkplay\.live)/(?P<channel_name>\w+)(?:/?$|(?P<vod>/record/[^?#]+))",
    ),
)
class VKvideolive(Plugin):
    API_URL = "https://api.live.vkvideo.ru/v1"

    _WEIGHTS = {
        "quad_hd": 5,
        "full_hd": 4,
        "high": 3,
        "medium": 2,
        "low": 1,
    }

    @classmethod
    def stream_weight(cls, stream: str) -> tuple[float, str]:
        if stream in cls._WEIGHTS:
            return cls._WEIGHTS[stream], "vkvideolive"

        return super().stream_weight(stream)

    # The player URLs of a single stream: a list of (type, url) tuples
    _schema_player_urls = [
        validate.all(
            {
                "type": str,
                "url": validate.any("", validate.url()),
            },
            validate.union_get("type", "url"),
        ),
    ]

    # A single stream of a channel or of a stream slot: a (vid, player URLs) tuple.
    # Some responses only include the "sharedPlayerUrls" list, so fall back to it.
    _schema_stream = validate.any(
        validate.all(
            {
                "vid": str,
                "playerUrls": _schema_player_urls,
            },
            validate.union_get("vid", "playerUrls"),
        ),
        validate.all(
            {
                "vid": str,
                "sharedPlayerUrls": _schema_player_urls,
            },
            validate.union_get("vid", "sharedPlayerUrls"),
        ),
    )

    # The list of streams of a channel or of a stream slot
    _schema_streams = validate.any(
        [
            _schema_stream,
        ],
        [],
    )

    # The category of a channel or of a stream slot
    _schema_category = validate.all(
        {
            "title": str,
        },
        validate.get("title"),
    )

    def _query_api(self, channel_name, vod):
        schema_data = validate.all(
            {
                validate.optional("category"): self._schema_category,
                "title": str,
                "data": self._schema_streams,
            },
            validate.union_get(
                "category",
                "title",
                ("data", 0),
            ),
        )
        schema_response = validate.any(
            validate.all(
                {"error": str, "error_description": str},
                validate.get("error_description"),
            ),
            schema_data,
        )
        if not vod:
            schema = schema_response
        else:
            schema = validate.all(
                {"data": {"record": schema_response}},
                validate.get(("data", "record")),
            )

        data = self.session.http.get(
            f"{self.API_URL}/blog/{channel_name}/public_video_stream{vod}",
            headers={"Referer": self.url},
            acceptable_status=(200, 404),
            schema=validate.Schema(
                validate.parse_json(),
                schema,
            ),
        )
        if isinstance(data, str):
            raise PluginError(f"VKvideo API error: {data}")

        return data

    def _query_slot_api(self, channel_name, slot_name):
        schema_data = validate.all(
            {
                validate.optional("category"): self._schema_category,
                "title": str,
                validate.optional("user"): validate.none_or_all(
                    {
                        validate.optional("nick"): str,
                    },
                    validate.get("nick"),
                ),
                "data": self._schema_streams,
            },
            validate.union_get(
                "category",
                "title",
                "user",
                ("data", 0),
            ),
        )
        # The stream slot API wraps the stream data in a "data" object
        schema_response = validate.any(
            validate.all(
                {"error": str, "error_description": str},
                validate.get("error_description"),
            ),
            validate.all(
                {
                    "data": {
                        "stream": schema_data,
                    },
                },
                validate.get(("data", "stream")),
            ),
        )

        data = self.session.http.get(
            f"{self.API_URL}/channel/{channel_name}/stream/slot/{slot_name}",
            # The web client requests stream slots with the "layer" source
            params={"from": "layer"},
            headers={"Referer": self.url},
            acceptable_status=(200, 400, 403, 404),
            schema=validate.Schema(
                validate.parse_json(),
                schema_response,
            ),
        )
        if isinstance(data, str):
            raise PluginError(f"VKvideo API error: {data}")

        return data

    def _get_live_streams(self, streams):
        for streamtype, streamurl in streams:
            if streamurl and streamtype == "live_hls":
                yield from HLSStream.parse_variant_playlist(self.session, streamurl).items()

    def _get_slot_streams(self):
        match = self.matches["slot"]
        channel_name = match["channel_name"]
        slot_name = match["slot_name"]
        log.debug(f"Channel name: {channel_name}")
        log.debug(f"Slot name: {slot_name}")

        category, title, author, streamdata = self._query_slot_api(
            channel_name=channel_name,
            slot_name=slot_name,
        )

        self.category = category
        self.title = title
        self.author = author or channel_name

        if not streamdata:
            return

        self.id, streams = streamdata

        yield from self._get_live_streams(streams)

    def _get_streams(self):
        if self.matches["slot"]:
            yield from self._get_slot_streams()
            return

        match = self.matches["default"]
        self.author = match["channel_name"]
        log.debug(f"Channel name: {self.author}")
        vod = match["vod"] or ""
        log.debug(f"VOD: {vod}")

        data = self._query_api(channel_name=self.author, vod=vod)

        self.category, self.title, streamdata = data
        if not streamdata:
            return

        self.id, streams = streamdata

        if not vod:
            yield from self._get_live_streams(streams)
        else:
            for streamtype, streamurl in streams:
                if streamurl and streamtype in self._WEIGHTS:
                    yield streamtype, HTTPStream(self.session, streamurl)


__plugin__ = VKvideolive
