import io
import struct
import sys
import types
import unittest
from unittest.mock import patch


class EncodedPacketTests(unittest.TestCase):
    def test_reads_one_h264_access_unit(self):
        from rocam_video import CODEC_H264, HEADER, PacketReader

        payload = b"\x00\x00\x00\x01\x67\x64\x00\x1f"
        stream = io.BytesIO(HEADER.pack(b"RCV1", CODEC_H264, 1, 0, len(payload), 1280, 720, 7, 1234) + payload)
        packet = PacketReader(stream).read()
        self.assertEqual(packet.codec, CODEC_H264)
        self.assertTrue(packet.keyframe)
        self.assertEqual((packet.width, packet.height, packet.sequence, packet.pts_us), (1280, 720, 7, 1234))
        self.assertEqual(packet.payload, payload)

    def test_rejects_invalid_packet_before_payload_allocation(self):
        from rocam_video import CODEC_H264, HEADER, VideoFormatError, read_packet

        bad = HEADER.pack(b"RCV1", CODEC_H264, 4, 0, 16 * 1024 * 1024 + 1, 1, 1, 1, 0)
        with self.assertRaises(VideoFormatError):
            read_packet(io.BytesIO(bad))

    def test_rejects_invalid_dimensions_and_truncated_payload(self):
        from rocam_video import CODEC_HEVC, HEADER, VideoFormatError, read_packet

        cases = (
            HEADER.pack(b"RCV1", CODEC_HEVC, 1, 0, 1, 0, 720, 1, 0),
            HEADER.pack(b"RCV1", CODEC_HEVC, 1, 1, 4, 1280, 720, 1, 0) + b"x",
        )
        for stream in cases:
            with self.subTest(stream=stream):
                with self.assertRaises(VideoFormatError):
                    read_packet(io.BytesIO(stream))

    def test_decoder_discards_delta_after_gap_until_keyframe(self):
        from rocam_video import AVDecoder, CODEC_H264, FLAG_KEYFRAME, VideoPacket

        decoder = AVDecoder()
        seen = []

        class Context:
            def decode(self, _packet):
                seen.append(True)
                return []

        def create(packet):
            decoder._context = Context()
            decoder._codec = packet.codec
            decoder._dimensions = (packet.width, packet.height)

        decoder._new_context = create
        key = VideoPacket(CODEC_H264, FLAG_KEYFRAME, 2, 2, 1, 0, b"x")
        delta_after_gap = VideoPacket(CODEC_H264, 0, 2, 2, 3, 0, b"x")
        new_key = VideoPacket(CODEC_H264, FLAG_KEYFRAME, 2, 2, 4, 0, b"x")
        # This is a control-flow test; PyAV remains optional for the base install.
        with patch.dict(sys.modules, {"av": types.SimpleNamespace(Packet=lambda data: data)}):
            decoder.decode(key)
            decoder.decode(delta_after_gap)
            decoder.decode(new_key)
        self.assertEqual(len(seen), 2)


if __name__ == "__main__":
    unittest.main()
