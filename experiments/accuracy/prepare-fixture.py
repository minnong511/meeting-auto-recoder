"""Materialize only the frozen evaluation cases from the pinned FLEURS revision."""
import argparse, hashlib, json, shutil, tarfile, urllib.request
from pathlib import Path
import numpy as np
from scipy.io import wavfile

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--data', type=Path, default=HERE.parents[1]/'.build/asr-benchmark')
args = parser.parse_args()
dest = args.output.resolve(); dest.mkdir(parents=True, exist_ok=True)
data = args.data.resolve(); data.mkdir(parents=True, exist_ok=True)
manifest = json.loads((HERE/'cases.json').read_text())
base = f"https://huggingface.co/datasets/google/fleurs/resolve/{manifest['revision']}/data/ko_kr"

def fetch(remote, local):
    if not local.exists():
        temp = local.with_suffix(local.suffix+'.part')
        urllib.request.urlretrieve(base+'/'+remote, temp); temp.replace(local)

fetch('test.tsv', data/'test.tsv')
rows = {row[1]: row for row in (line.split('\t') for line in (data/'test.tsv').read_text().splitlines())}
audio = data/'audio'; audio.mkdir(exist_ok=True)
files = {p.name:p for p in audio.rglob('*.wav')}
needed = {s['id']+'.wav' for s in manifest['samples'] if s['kind']=='speech'} - files.keys()
if needed:
    fetch('audio/test.tar.gz', data/'test.tar.gz')
    with tarfile.open(data/'test.tar.gz') as archive:
        for member in archive:
            name = Path(member.name).name
            if member.isfile() and name in needed:
                with archive.extractfile(member) as src, (audio/name).open('wb') as target:
                    shutil.copyfileobj(src, target)
                files[name] = audio/name
noise_dir = dest/'non-speech'; noise_dir.mkdir(exist_ok=True)
rng = np.random.default_rng(20261104)
for s in manifest['samples']:
    if s['kind']=='speech':
        name = s['id']+'.wav'; path=files[name]
        assert rows[name][0] == s['text_id']
        s['reference'] = rows[name][3]
    else:
        kind, i = s['id'].split('-'); i=int(i); sr=16_000
        seconds=[5,8,12][i]; n=seconds*sr; t=np.arange(n)/sr
        if kind=='zero': x=np.zeros(n)
        elif kind=='hiss': x=rng.normal(0,[.0015,.004,.012][i],n)
        elif kind=='hum': x=[.003,.01,.03][i]*(np.sin(2*np.pi*60*t)+.3*np.sin(2*np.pi*180*t))+rng.normal(0,.0003,n)
        else:
            assert kind=='clicks'
            x=rng.normal(0,.001,n)
            for at in np.arange(.4, seconds, .7):
                start=int(at*sr); count=min(1000,n-start)
                x[start:start+count]+=.08*rng.normal(0,1,count)*np.exp(-np.arange(count)/90)
        path=noise_dir/(s['id']+'.wav'); wavfile.write(path,sr,x.astype(np.float32));s['reference']=''
    if hashlib.sha256(path.read_bytes()).hexdigest()!=s['sha256']:
        raise ValueError(f"Fixture hash differs: {s['id']}")
    s['path']=str(path)
for split in ('dev','test','latency','confirm'):
    subset=[s for s in manifest['samples'] if (s['split']==split if split!='latency' else 'speech_end_estimate' in s)]
    (dest/(split+'.json')).write_text(json.dumps({**manifest,'samples':subset},ensure_ascii=False,indent=2)+'\n')
    print(split,len(subset))
