#!/usr/bin/env python3
"""Small HTTP server for BlueMagpie-TTS.

Run it with the venv where BlueMagpie-TTS already works:

    cd ~/dev/BlueMagpie-TTS
    source .venv/bin/activate
    python ~/dev/AniCompanion/Tools/blue_magpie_tts_server.py

AniCompanion calls:

    POST /v1/tts
    {"text": "...", "inference_timesteps": 5}

The response is audio/wav.
"""

from __future__ import annotations

import argparse
import itertools
import io
import json
import os
import time
import traceback
from json import JSONDecodeError
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import soundfile as sf
from huggingface_hub import snapshot_download
from transformers import PreTrainedTokenizerFast

from bluemagpie import BlueMagpieModel


class BlueMagpieSynthesizer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.backend = args.backend
        self.cfg_value = args.cfg_value
        self.inference_timesteps = args.inference_timesteps

        model_dir = args.model_dir or snapshot_download(
            "OpenFormosa/BlueMagpie-TTS",
            token=args.hf_token or os.environ.get("HF_TOKEN") or True,
        )
        tokenizer = PreTrainedTokenizerFast(tokenizer_file=os.path.join(model_dir, "tokenizer.json"))

        if self.backend == "mlx":
            from bluemagpie.mlx import BlueMagpieMLX

            self.model = BlueMagpieModel.from_local(model_dir, tokenizer=tokenizer, device="cpu")
            self.mlx_model = BlueMagpieMLX(self.model)
        else:
            self.model = BlueMagpieModel.from_local(model_dir, tokenizer=tokenizer, training=False, device=args.device)
            self.mlx_model = None

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate)

    def synthesize(self, payload: dict[str, Any]) -> bytes:
        text = str(payload.get("text", "")).strip()
        if not text:
            raise ValueError("Missing non-empty 'text'.")

        cfg_value = float(payload.get("cfg_value", self.cfg_value))
        inference_timesteps = max(1, min(12, int(payload.get("inference_timesteps", self.inference_timesteps))))
        seed = payload.get("seed")
        seed = None if seed is None else int(seed)

        if self.backend == "mlx":
            from bluemagpie.mlx import mlx_generate

            audio = mlx_generate(
                self.model,
                self.mlx_model,
                target_text=text,
                cfg_value=cfg_value,
                inference_timesteps=inference_timesteps,
                seed=seed,
            )
        else:
            audio = self.model.generate(
                target_text=text,
                cfg_value=cfg_value,
                inference_timesteps=inference_timesteps,
            )

        audio_np = audio.squeeze().detach().cpu().numpy()
        output = io.BytesIO()
        sf.write(output, audio_np, self.sample_rate, format="WAV", subtype="PCM_16")
        return output.getvalue()


class Handler(BaseHTTPRequestHandler):
    synthesizer: BlueMagpieSynthesizer
    request_ids = itertools.count(1)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "sample_rate": self.synthesizer.sample_rate})
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/v1/tts":
            self.send_json(404, {"error": "not_found"})
            return

        try:
            request_id = next(self.request_ids)
            length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(length)
            payload = json.loads(raw_body.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("JSON body must be an object.")
            text = str(payload.get("text", "")).strip()
            preview = text[:80].replace("\n", " ")
            started = time.monotonic()
            print(f"[BlueMagpie] request {request_id} start: {preview!r}", flush=True)
            audio = self.synthesizer.synthesize(payload)
            elapsed = time.monotonic() - started
            print(
                f"[BlueMagpie] request {request_id} done: {len(audio)} bytes in {elapsed:.2f}s",
                flush=True,
            )
        except JSONDecodeError as exc:
            print(f"[BlueMagpie] bad JSON: {exc}", flush=True)
            self.send_json(400, {"error": "Invalid JSON body."})
            return
        except ValueError as exc:
            print(f"[BlueMagpie] bad request: {exc}", flush=True)
            self.send_json(400, {"error": str(exc)})
            return
        except Exception as exc:
            traceback.print_exc()
            self.send_json(500, {"error": f"{type(exc).__name__}: {exc}"})
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(audio)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(audio)

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} - {fmt % args}")

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BlueMagpie-TTS HTTP server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--backend", choices=("mlx", "torch"), default="mlx")
    parser.add_argument("--device", default="cpu", help="Torch backend device: cpu, cuda, or mps")
    parser.add_argument("--model-dir", default=os.environ.get("BLUEMAGPIE_MODEL_DIR", ""))
    parser.add_argument("--hf-token", default=os.environ.get("HF_TOKEN", ""))
    parser.add_argument("--cfg-value", type=float, default=2.8)
    parser.add_argument("--inference-timesteps", type=int, default=9)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    print("Loading BlueMagpie-TTS model...")
    Handler.synthesizer = BlueMagpieSynthesizer(args)
    server = HTTPServer((args.host, args.port), Handler)
    print(f"BlueMagpie-TTS server listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
