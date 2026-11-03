#!/usr/bin/env python3
"""Compile the production worker with a fake loopback server; no model download."""
import json, os, pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parents[1]
FAKE = r'''#!/usr/bin/env python3
import http.server, json, os, pathlib, sys
root=pathlib.Path(__file__).resolve().parent
args=sys.argv[1:]
def flag(name): return args[args.index(name)+1]
mode=flag('--n-gpu-layers')
scenario=(root/'scenario.txt').read_text()
attempts=root/'attempts.jsonl'
previous=[json.loads(x) for x in attempts.read_text().splitlines()]
alive=False
if previous:
    try: os.kill(previous[-1]['pid'],0); alive=True
    except ProcessLookupError: pass
with attempts.open('a') as f: f.write(json.dumps({'mode':mode,'pid':os.getpid(),'priorAlive':alive})+'\n')
if scenario=='both-fail' or scenario=='fallback' and mode=='auto': sys.exit(3)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,status,data):
        body=json.dumps(data,ensure_ascii=False).encode();self.send_response(status)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
        self.end_headers();self.wfile.write(body)
    def authorized(self): return self.headers.get('Authorization')=='Bearer '+flag('--api-key')
    def do_GET(self): self.reply(503 if scenario=='cancel' else 200 if self.authorized() else 401,{'status':'ok'})
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        self.reply(200 if self.authorized() else 401,{'choices':[{'finish_reason':'length' if scenario=='truncated' else 'stop','message':{'content':'숫자 240, 담당자 미정'}}],'usage':{'prompt_tokens':10,'completion_tokens':7}})
parent=os.getppid()
server=http.server.HTTPServer(('127.0.0.1',int(flag('--port'))),Handler)
server.timeout=0.2
while os.getppid()==parent: server.handle_request()
'''

def main():
    with tempfile.TemporaryDirectory(prefix='recorder-polisher-check-') as name:
        root=pathlib.Path(name); models=root/'models'; (models/'blobs').mkdir(parents=True)
        manifest=models/'manifests/registry.ollama.ai/library/test';manifest.mkdir(parents=True)
        digest='sha256:'+'0'*64
        (models/'blobs'/digest.replace(':','-')).touch()
        (manifest/'small').write_text(json.dumps({'layers':[{'mediaType':'application/vnd.ollama.image.model','digest':digest}]}))
        server=root/'fake-server.py';server.write_text(FAKE);server.chmod(0o700)
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(REPO/'Sources/MeetingRecorder/LocalTranscriptPolisher.swift'),str(ROOT/'PolisherLifecycleChecks.swift'),'-o',str(root/'checks')],check=True)
        env=dict(os.environ,OLLAMA_MODELS=str(models))
        subprocess.run([str(root/'checks'),str(root)],env=env,check=True,timeout=30)
if __name__=='__main__': main()
