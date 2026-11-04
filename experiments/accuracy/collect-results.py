"""Collect a complete paired run. Requires no model, network or third-party library."""
import argparse, json, random
from pathlib import Path
from score import summarize, quantile

METHODS={'turbo-energy':'Whisper Turbo 626MB · 음량 기준 (기존)','turbo-vad':'Whisper Turbo 626MB · 말소리 감지',
    'fp16-vad':'Whisper Turbo FP16 · 말소리 감지','qwen-vad':'Qwen3-ASR 1.7B 4bit · 말소리 감지',
    'large-vad-initial':'Whisper large-v3 947MB · 말소리 감지 (초기)',
    'large-vad':'Whisper large-v3 947MB · 말소리 감지 + 확정 우선 (적용)'}
def paired(a,b):
    rows=[(x['edits']-y['edits'],x['characters']) for x,y in zip(a,b) if 'edits' in x]
    rng=random.Random(20261104); deltas=[]
    for _ in range(10000):
        sample=rng.choices(rows,k=len(rows))
        deltas.append(100*sum(x[0] for x in sample)/sum(x[1] for x in sample))
    return {'cer_reduction_pp':100*sum(x[0] for x in rows)/sum(x[1] for x in rows),
            'paired_percentile_95_pp':[quantile(deltas,.025),quantile(deltas,.975)],
            'clips_fewer_equal_more_edits':[sum(((d>0)-(d<0))==v for d,_ in rows) for v in (1,0,-1)]}
def collect(root):
    def get(name): return json.loads((root/name).read_text())
    manifests={s:get(s+'.json') for s in ('dev','test','confirm','latency')}
    info={s:{'speech_s':round(sum(x['duration'] for x in m['samples'] if x['kind']=='speech'),3),
             'nonspeech_s':sum(x['duration'] for x in m['samples'] if x['kind']=='non-speech'),
             'unique_speech_text_groups':len({x['text_id'] for x in m['samples'] if x['kind']=='speech'})}
          for s,m in manifests.items()}
    result={'date':'2026-11-04','hardware':{'chip':'Apple M5','memory_GiB':16,'macOS':'26.5.1'},
            'dataset':{'source':'https://huggingface.co/datasets/google/fleurs','locale':'ko_kr','revision':manifests['test']['revision'],'license':'CC-BY-4.0'},
            'baseline':'turbo-energy','chosen':'large-vad','sets':info,
            'timing':'One model and input lane at a time; 8 paired real-time replays, warm model. Last nonempty final event minus spectrogram-estimated end. Wall time outside model preparation; excludes disk/UI/capture driver.',
            'selection':{},'realtime':{},'confirmation':{},'dev':{},'per_clip':{}}
    for split,section,run,methods in [('test','selection','test',METHODS),('latency','realtime','live',METHODS),
             ('confirm','confirmation','confirm',['turbo-energy','large-vad']),('dev','dev','dev',
             ['turbo-energy','turbo-vad06','turbo-vad10','qwen-vad06','fp16-vad'])]:
        m=manifests[split];quiet={s['id'] for s in m['samples'] if s['kind']=='non-speech'}
        result['per_clip'][section]={}
        for key in methods:
            filekey = {'large-vad':'priority','large-vad-initial':'large-vad'}.get(key,key) if split in ('test','latency') else key
            rows=[json.loads(line) for line in (root/(filekey+'-'+run+'.jsonl')).read_text().splitlines()]
            metrics,details=summarize(m,rows)
            metrics['nonspeech_decode_events']=sum(len(r['events']) for r in rows if r['id'] in quiet)
            metrics['nonspeech_wall_s']=sum(r['seconds'] for r in rows if r['id'] in quiet)
            result[section][key]=metrics
            result['per_clip'][section][key]=details
    result['paired_comparison']={s:paired(result['per_clip'][s]['turbo-energy'],result['per_clip'][s]['large-vad'])
                                 for s in ['selection','confirmation']}
    return result
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('directory',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.write_text(json.dumps(collect(args.directory),ensure_ascii=False,indent=2)+'\n')
