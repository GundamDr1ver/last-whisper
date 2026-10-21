import urllib.request, json, pathlib, concurrent.futures, hashlib
repo='argmaxinc/whisperkit-coreml'
variant='openai_whisper-large-v3-v20240930_turbo'
root=pathlib.Path(__file__).resolve().parents[1]/'Models'
url=f'https://huggingface.co/api/models/{repo}/tree/main/{variant}?recursive=true&expand=false'
with urllib.request.urlopen(url, timeout=40) as r: entries=json.load(r)
files=[e for e in entries if e['type']=='file']
print('Downloading', len(files), 'model files;', round(sum(e.get('size',0) for e in files)/1e6), 'MB',flush=True)
def fetch(e):
    dest=root/e['path']; dest.parent.mkdir(parents=True,exist_ok=True)
    expected=e.get('size',0)
    if dest.exists() and dest.stat().st_size==expected: return
    source=f'https://huggingface.co/{repo}/resolve/main/'+e['path']+'?download=true'
    temp=dest.with_name(dest.name+'.partial')
    with urllib.request.urlopen(source, timeout=180) as response, temp.open('wb') as f:
        while True:
            chunk=response.read(1024*1024)
            if not chunk: break
            f.write(chunk)
    if expected and temp.stat().st_size!=expected: raise RuntimeError('Incomplete '+e['path'])
    sha=e.get('lfs',{}).get('oid')
    if sha and hashlib.sha256(temp.read_bytes()).hexdigest()!=sha: raise RuntimeError('Checksum mismatch '+e['path'])
    temp.replace(dest)
    print('OK',e['path'].split('/')[-2:],flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(fetch,files))
# The tokenizer is required for completely offline inference.
for name in ['tokenizer.json','tokenizer_config.json','config.json']:
    dest=root/'tokenizer'/name; dest.parent.mkdir(parents=True,exist_ok=True)
    if not dest.exists():
        with urllib.request.urlopen(f'https://huggingface.co/openai/whisper-large-v3/resolve/main/{name}',timeout=90) as r: dest.write_bytes(r.read())
print('READY',root/variant,flush=True)
