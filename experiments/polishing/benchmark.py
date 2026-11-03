#!/usr/bin/env python3
"""Local, synthetic Korean polishing comparison; never touches saved meetings."""
import argparse, hashlib, json, os, pathlib, re, secrets, socket, statistics
import subprocess, threading, time, urllib.error, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
SERVER = next((str(p) for p in [pathlib.Path('/Applications/Ollama.app/Contents/Resources/llama-server'), pathlib.Path.home()/'Applications/Ollama.app/Contents/Resources/llama-server'] if p.is_file()), '')
SOURCE = ROOT.parents[1] / 'Sources/MeetingRecorder/LocalTranscriptPolisher.swift'
INSTRUCTION = re.search(r'let instruction = """\n(.*?)\n\s*"""', SOURCE.read_text(), re.S)[1]
INSTRUCTION = '\n'.join(x.strip() for x in INSTRUCTION.splitlines())
CASES = json.loads((ROOT / 'cases.json').read_text())
MODELS = pathlib.Path(os.environ.get('OLLAMA_MODELS', pathlib.Path.home() / '.ollama/models'))
MANIFEST = json.loads((MODELS / 'manifests/registry.ollama.ai/library/qwen3.5/4b').read_text())
DIGEST = next(x['digest'] for x in MANIFEST['layers'] if x['mediaType'] == 'application/vnd.ollama.image.model')
MODEL = MODELS / 'blobs' / DIGEST.replace(':','-')

def cpu_seconds(value):
    chunks = value.split(':')
    return sum(float(x) * 60**i for i, x in enumerate(reversed(chunks)))

def stats(pid):
    result = subprocess.run(['ps', '-o', 'rss=,time=', '-p', str(pid)], capture_output=True, text=True)
    parts = result.stdout.split()
    return {'rss_mib': int(parts[0])/1024, 'cpu_seconds': cpu_seconds(parts[1])} if len(parts)==2 else {}

def run(mode, number, count, output):
    key = secrets.token_hex(32)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    root = f'http://127.0.0.1:{port}/'
    args = [SERVER, '--model', str(MODEL), '--host', '127.0.0.1', '--port', str(port), '--api-key', key,
            '--ctx-size', '4096', '--parallel', '1', '--no-mmproj', '--jinja', '--threads', '4', '--no-webui']
    if mode == 'cpu': args += ['--device', 'none', '--n-gpu-layers', '0', '--fit', 'off', '--no-op-offload']
    else: args += ['--n-gpu-layers', 'auto', '--fit', 'on']
    rows, samples = [], []
    done = threading.Event()
    log_path = output / f'{mode}-{number}.log'
    started = time.perf_counter()
    process = subprocess.Popen(args, stdout=log_path.open('w'), stderr=subprocess.STDOUT)
    def sample():
        while not done.is_set():
            samples.append(stats(process.pid)); done.wait(0.2)
    monitor = threading.Thread(target=sample, daemon=True); monitor.start()
    def request(path, body=None):
        req = urllib.request.Request(root + path, data=json.dumps(body).encode() if body is not None else None,
              headers={'Authorization':'Bearer '+key, 'Content-Type':'application/json'})
        with urllib.request.urlopen(req, timeout=180 if body else 1) as response:
            return json.load(response)
    try:
        while time.perf_counter() - started < 90:
            if process.poll() is not None: raise RuntimeError(f'{mode} server exited: inspect {log_path}')
            try:
                request('health'); break
            except (urllib.error.URLError, TimeoutError): time.sleep(0.1)
        else: raise RuntimeError('startup timeout')
        startup = time.perf_counter() - started
        print(json.dumps({'mode':mode,'round':number,'startup_seconds':round(startup,3)}), flush=True)
        before = stats(process.pid)
        for case in CASES[:count]:
            body = {'model':'qwen3.5:4b','stream':False,'temperature':0,'max_tokens':1024,
                    'stop':['<|im_end|>','<end_of_turn>'], 'chat_template_kwargs':{'enable_thinking':False},
                    'messages':[{'role':'system','content':INSTRUCTION},
                                {'role':'user','content':'다음은 편집 대상 전사문입니다.\n<transcript>\n'+case['text']+'\n</transcript>'}]}
            start = time.perf_counter(); result = request('v1/chat/completions', body)
            elapsed = time.perf_counter()-start
            choice=result['choices'][0]; text=choice['message']['content'].strip()
            missing=[x for x in case['preserve'] if x.replace(' ','') not in text.replace(' ','')]
            row={'mode':mode,'round':number,'case':case['id'],'seconds':elapsed,'input_characters':len(case['text']),
                 'output':text,'finish_reason':choice.get('finish_reason'),'usage':result.get('usage'),
                 'timings':result.get('timings'),'missing_markers':missing}
            rows.append(row)
            print(json.dumps({k:row[k] for k in ['mode','round','case','seconds','missing_markers']}, ensure_ascii=False), flush=True)
        after=stats(process.pid)
        summary={'mode':mode,'round':number,'startup_seconds':startup,
                 'request_cpu_seconds':after['cpu_seconds']-before['cpu_seconds'],
                 'peak_rss_mib':max(x.get('rss_mib',0) for x in samples),'rows':rows}
        (output/f'{mode}-{number}.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
        return summary
    finally:
        done.set(); monitor.join()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--rounds',type=int,default=3)
    parser.add_argument('--cases',type=int,default=6); parser.add_argument('--output',required=True)
    parser.add_argument('--mode',choices=['cpu','metal','both'],default='both')
    opts=parser.parse_args(); output=pathlib.Path(opts.output); output.mkdir(parents=True,exist_ok=True)
    metadata={'model':'qwen3.5:4b','model_digest':DIGEST,'server_version':(lambda p: (p.stdout+p.stderr).strip())(subprocess.run([SERVER,'--version'],capture_output=True,text=True,check=True)),
              'fixture_sha256':hashlib.sha256((ROOT/'cases.json').read_bytes()).hexdigest(),
              'instruction_sha256':hashlib.sha256(INSTRUCTION.encode()).hexdigest(),
              'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string','hw.memsize'],text=True).strip(),
              'rss_sampling_seconds':0.2,'os':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip()}
    (output/'metadata.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
    runs=[]
    for number in range(1,opts.rounds+1):
        modes=(['cpu','metal'] if number%2 else ['metal','cpu']) if opts.mode=='both' else [opts.mode]
        for mode in modes: runs.append(run(mode,number,opts.cases,output))
    (output/'results.json').write_text(json.dumps(runs,ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__': main()
