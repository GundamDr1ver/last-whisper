#!/usr/bin/env python3
"""Download the default model with size/SHA-256 verification. No Python inference runtime."""
from pathlib import Path
import hashlib
import os
import urllib.request

root = Path(os.environ.get('VOICEINPUT_MODEL_ROOT', Path(__file__).resolve().parents[1] / 'Models'))
name = 'qwen3-asr-1.7b-q8_0.gguf'
expected_size = 2473017600
expected_sha = '3bc2462eca3a3a8f56abcd860d0943ffdc0546547dde55a9d08589607d6f3936'
url = 'https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/main/Qwen3-ASR-1.7B-GGUF/' + name + '?download=true'

def validate(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(block)
    if path.stat().st_size != expected_size or digest.hexdigest() != expected_sha:
        raise RuntimeError('Model size or SHA-256 mismatch; retry download.')

if __name__ == '__main__':
    root.mkdir(parents=True, exist_ok=True)
    destination = root / name
    if destination.exists():
        validate(destination)
        print('Model already verified.', flush=True)
    else:
        temporary = destination.with_suffix('.gguf.partial')
        print('Downloading Qwen3-ASR 1.7B Q8, 2.47 GB', flush=True)
        try:
            with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as output:
                count = 0
                last = -1
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    output.write(block)
                    count += len(block)
                    percent = count * 100 // expected_size
                    if percent // 5 != last:
                        print(str(percent) + '%', flush=True)
                        last = percent // 5
            validate(temporary)
            temporary.replace(destination)
            print('READY', destination, flush=True)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
