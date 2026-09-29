#!/usr/bin/env python3
"""
Protocol-accurate mock of an OpenAI-compatible /chat/completions endpoint.

Used to integration-test AIService end to end without a real provider:
streaming SSE, JSON mode, providers that ignore `stream`, providers that
reject `response_format`, and providers that fail so the fallback chain runs.

Routes (path prefix selects behaviour):
  /v1/...            well-behaved provider
  /nojson/v1/...     returns 400 when response_format is present
  /nostream/v1/...   ignores stream:true and replies with a single JSON body
  /flaky/v1/...      always 500, to exercise the fallback provider
  /ratelimit/v1/...  returns 429
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANSWER_TEXT = "Lead with the pilot, then talk about annual pricing."
SCRIPT_QUOTE = "guidance topic 192 covers objection number 27 in detail"


def chat_completion():
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": 0,
        "model": "mock-model",
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": ANSWER_TEXT},
            "finish_reason": "stop",
        }],
    }


def structured_object():
    return {
        "answer": ANSWER_TEXT,
        "script_quote": SCRIPT_QUOTE,
    }


def sse_frames(payload_object, words):
    """Yield raw SSE bytes for a streamed response, chunk by word."""
    yield b'data: {"choices":[{"delta":{"role":"assistant"},"index":0}]}\n\n'
    for index, word in enumerate(words):
        piece = word if index == 0 else " " + word
        frame = {
            "choices": [{
                "delta": {"content": piece},
                "index": 0,
                "finish_reason": None,
            }]
        }
        yield ("data: " + json.dumps(frame) + "\n\n").encode()
    yield b'data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}\n\n'
    yield b"data: [DONE]\n\n"


def structured_sse_frames(payload):
    """Stream a JSON object in small pieces so the extractor sees real fragments."""
    text = json.dumps(payload)
    chunk_size = 12
    for start in range(0, len(text), chunk_size):
        frame = {"choices": [{"delta": {"content": text[start:start + chunk_size]}}]}
        yield ("data: " + json.dumps(frame) + "\n\n").encode()
    yield b"data: [DONE]\n\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # keep the harness output readable

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}

        path = self.path
        wants_json = body.get("response_format") is not None
        wants_stream = bool(body.get("stream"))

        def send(code, payload):
            data = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        if path.startswith("/flaky/"):
            send(500, {"error": {"message": "mock provider is down"}})
            return

        if path.startswith("/ratelimit/"):
            send(429, {"error": {"message": "rate limited"}})
            return

        if path.startswith("/nojson/") and wants_json:
            send(400, {"error": {"message": "response_format is not supported"}})
            return

        # Providers that ignore `stream:true` return a normal completion body.
        if path.startswith("/nostream/") or not wants_stream:
            if wants_json:
                send(200, structured_object())
            else:
                send(200, chat_completion())
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        if wants_json:
            for chunk in structured_sse_frames(structured_object()):
                self.wfile.write(chunk)
        else:
            for chunk in sse_frames(chat_completion(), ANSWER_TEXT.split()):
                self.wfile.write(chunk)
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8931
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock provider listening on 127.0.0.1:{port}", flush=True)
    server.serve_forever()
