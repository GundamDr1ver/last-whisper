#!/usr/bin/env python3
"""Download the default model with size/SHA-256 verification. No Python inference runtime."""
from pathlib import Path
import hashlib
import urllib.request

root = Path(__file__).resolve().parents[1] / 'Models'
name = 'vibevoice-asr-streaming-1.5b-q8_0.gguf'
expected_size = 3343199488
expected_sha = '1a92c0f6c72439d58dedaaff96bb77264802618bd577f58cc0176f47bae5180d'
url = 'https://huggingface.co/christopherthompson81/VibeVoice-ASR-Streaming-1.5B-GGUF/resolve/main/' + name + '?download=true'

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
        print('Downloading VibeVoice-ASR-Streaming 1.5B, 3.34 GB', flush=True)
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
