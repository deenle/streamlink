import pytest

from streamlink.exceptions import PluginError
from streamlink.plugins.vkvideolive import VKvideolive
from tests.plugins import PluginCanHandleUrl
from tests.resources import text


class TestPluginCanHandleUrlVKvideolive(PluginCanHandleUrl):
    __plugin__ = VKvideolive

    should_match_groups = [
        # live
        (("default", "https://live.vkvideo.ru/CHANNEL"), {"channel_name": "CHANNEL"}),
        (("default", "https://live.vkplay.ru/CHANNEL"), {"channel_name": "CHANNEL"}),
        (("default", "https://vkplay.live/CHANNEL"), {"channel_name": "CHANNEL"}),
        # VOD
        (("default", "https://live.vkvideo.ru/CHANNEL/record/VOD"), {"channel_name": "CHANNEL", "vod": "/record/VOD"}),
        (("default", "https://live.vkplay.ru/CHANNEL/record/VOD"), {"channel_name": "CHANNEL", "vod": "/record/VOD"}),
        (("default", "https://vkplay.live/CHANNEL/record/VOD"), {"channel_name": "CHANNEL", "vod": "/record/VOD"}),
        # live stream slot
        (("slot", "https://live.vkvideo.ru/CHANNEL/stream/sl_123456"), {"channel_name": "CHANNEL", "slot_name": "sl_123456"}),
        (("slot", "https://live.vkplay.ru/CHANNEL/stream/sl_123456"), {"channel_name": "CHANNEL", "slot_name": "sl_123456"}),
        (("slot", "https://vkplay.live/CHANNEL/stream/sl_123456"), {"channel_name": "CHANNEL", "slot_name": "sl_123456"}),
        # live stream slot of the channel's default slot
        (("slot", "https://live.vkvideo.ru/CHANNEL/stream/default"), {"channel_name": "CHANNEL", "slot_name": "default"}),
    ]

    should_not_match = [
        "https://live.vkvideo.ru/",
        "https://live.vkplay.ru/",
        "https://vkplay.live/",
        "https://support.vkplay.ru/vkp_live",
        "https://vkplay.live/app/settings/edit",
        "https://vkplay.live/app/settings/external-apps",
    ]


@pytest.fixture()
def multivariant_playlist() -> str:
    with text("hls/test_simple_multivariant.m3u8") as fh:
        return fh.read()


def test_get_streams_slot(session, requests_mock, multivariant_playlist):
    requests_mock.get(
        "https://api.live.vkvideo.ru/v1/channel/channel12345678/stream/slot/sl_123456",
        json={
            "data": {
                "stream": {
                    "category": {
                        "title": "Category",
                    },
                    "title": "Title",
                    "user": {
                        "nick": "Nick",
                    },
                    "data": [
                        {
                            "vid": "1234",
                            "playerUrls": [
                                {
                                    "type": "live_hls",
                                    "url": "https://mocked/live.m3u8",
                                },
                            ],
                        },
                    ],
                },
            },
        },
    )
    requests_mock.get("https://mocked/live.m3u8", text=multivariant_playlist)

    plugin = VKvideolive(session, "https://live.vkvideo.ru/channel12345678/stream/sl_123456")
    streams = plugin.streams()

    assert plugin.id == "1234"
    assert plugin.author == "Nick"
    assert plugin.title == "Title"
    assert plugin.category == "Category"

    assert list(streams.keys()) == ["720p", "1080p", "worst", "best"]

    request = requests_mock.request_history[0]
    assert request.qs == {"from": ["layer"]}


def test_get_streams_slot_error(session, requests_mock):
    requests_mock.get(
        "https://api.live.vkvideo.ru/v1/channel/channel12345678/stream/slot/sl_123456",
        status_code=404,
        json={
            "error": "not_found",
            "error_description": "Not found",
        },
    )

    plugin = VKvideolive(session, "https://live.vkvideo.ru/channel12345678/stream/sl_123456")

    with pytest.raises(PluginError, match=r"^VKvideo API error: Not found$"):
        plugin.streams()


def test_get_streams_slot_forbidden(session, requests_mock):
    """Channels with restricted access return a 403 status code"""
    requests_mock.get(
        "https://api.live.vkvideo.ru/v1/channel/channel12345678/stream/slot/sl_123456",
        status_code=403,
        json={
            "error": "forbidden",
            "error_description": "Access denied",
        },
    )

    plugin = VKvideolive(session, "https://live.vkvideo.ru/channel12345678/stream/sl_123456")

    with pytest.raises(PluginError, match=r"^VKvideo API error: Access denied$"):
        plugin.streams()


def test_get_streams_slot_shared_player_urls(session, requests_mock, multivariant_playlist):
    """Some responses only include the sharedPlayerUrls list"""
    requests_mock.get(
        "https://api.live.vkvideo.ru/v1/channel/channel12345678/stream/slot/sl_123456",
        json={
            "data": {
                "stream": {
                    "title": "Title",
                    "data": [
                        {
                            "vid": "1234",
                            "sharedPlayerUrls": [
                                {
                                    "type": "live_hls",
                                    "url": "https://mocked/live.m3u8",
                                },
                            ],
                        },
                    ],
                },
            },
        },
    )
    requests_mock.get("https://mocked/live.m3u8", text=multivariant_playlist)

    plugin = VKvideolive(session, "https://live.vkvideo.ru/channel12345678/stream/sl_123456")
    streams = plugin.streams()

    assert plugin.id == "1234"
    assert list(streams.keys()) == ["720p", "1080p", "worst", "best"]


def test_get_streams_slot_offline(session, requests_mock):
    """A slot of an offline channel has no stream data"""
    requests_mock.get(
        "https://api.live.vkvideo.ru/v1/channel/channel12345678/stream/slot/sl_123456",
        json={
            "data": {
                "stream": {
                    "title": "Title",
                    "data": [],
                },
            },
        },
    )

    plugin = VKvideolive(session, "https://live.vkvideo.ru/channel12345678/stream/sl_123456")

    assert plugin.streams() == {}
