"""Score a complete labeled manifest against final, unpolished app events (stdlib only)."""
import argparse, collections, json, re, statistics, unicodedata
from pathlib import Path

def norm(value):
    return ''.join(c for c in unicodedata.normalize('NFC', value).lower()
                   if not c.isspace() and unicodedata.category(c)[0] not in 'PS')

def edits(a, b):
    prev = list(range(len(b)+1))
    for i, left in enumerate(a, 1):
        row = [i]
        for j, right in enumerate(b, 1):
            row.append(min(prev[j]+1, row[-1]+1, prev[j-1]+(left != right)))
        prev = row
    return prev[-1]

def number_text(value):
    value = ''.join(unicodedata.normalize('NFC', value).lower().split())
    return re.sub(r'(?<=\d),(?=\d{3}(?:\D|$))', '', value)

def contains(aliases, value, kind):
    if kind == 'names':
        return any(norm(alias) in norm(value) for alias in aliases)
    text = number_text(value)
    for alias in aliases:
        alias = number_text(alias)
        prefix = r'(?<![0-9])(?<![0-9]\.)' if alias[0].isdigit() else r'(?<![0-9일이삼사오육칠팔구십백천만억])'
        if re.search(prefix + re.escape(alias), text):
            return True
    return False

def sentences(text):
    # A run of terminal punctuation is a single boundary. Decimal points are not boundaries.
    return sum(bool(norm(part)) for part in re.split(r'(?:[!?。！？]+|(?<!\d)\.+|\.+(?!\d)|\n+)', text))

def quantile(values, q):
    x = sorted(values); pos = q*(len(x)-1); lo = int(pos)
    return x[lo] + (x[min(lo+1,len(x)-1)]-x[lo])*(pos-lo)

def summarize(manifest, rows):
    samples = manifest['samples']
    by_id = {row['id']: row for row in rows}
    if len(by_id) != len(rows) or set(by_id) != {s['id'] for s in samples}:
        raise ValueError('Incomplete or duplicate evaluation set')
    counts = collections.Counter(dict(speech=0,non_speech=0,characters=0,edits=0,
        names_hits=0,names_total=0,numbers_hits=0,numbers_total=0,false_clips=0,
        false_sentences=0,pure_silence_false_sentences=0,empty_speech=0))
    lag=[];lag_acoustic=[]; forced=0; details=[]
    for s in samples:
        row=by_id[s['id']]
        if row.get('error'): raise ValueError(s['id']+': '+row['error'])
        text=row['text'].strip()
        d={'id':s['id']}
        if s['kind']=='non-speech':
            counts['non_speech']+=1; n=sentences(text)
            counts['false_sentences']+=n; counts['false_clips']+=bool(text)
            if s['id'].startswith('zero-'): counts['pure_silence_false_sentences']+=n
            d.update(false_sentences=n)
        else:
            ref=norm(s['reference']); hyp=norm(text)
            err=edits(ref,hyp)
            counts['speech']+=1; counts['characters']+=len(ref); counts['edits']+=err
            counts['empty_speech']+=not hyp
            d.update(characters=len(ref),edits=err)
            for kind in ('names','numbers'):
                hits=sum(contains(options,text,kind) for options in s[kind])
                counts[kind+'_hits']+=hits; counts[kind+'_total']+=len(s[kind])
                d[kind+'_hits']=hits
            if row['realtime']:
                finals=[e for e in row['events'] if e['final'] and e['text'].strip()]
                if finals:
                    t=finals[-1]['elapsed']; value=t-s['duration']
                    lag.append(value); forced+=bool(finals[-1]['afterInput'])
                    d['lag_clip_end_s']=value
                    if 'speech_end_estimate' in s:
                        lag_acoustic.append(t-s['speech_end_estimate'])
        details.append(d)
    result=dict(counts)
    result['cer']=counts['edits']/counts['characters'] if counts['characters'] else None
    result['wall_s']=sum(r['seconds'] for r in rows)
    if lag:
        result.update(latency_n=len(lag),latency_missing=counts['speech']-len(lag),after_eof=forced,
            clip_end_p50_s=statistics.median(lag),clip_end_p95_s=quantile(lag,.95),clip_end_values_s=lag)
    if lag_acoustic:
        result.update(acoustic_end_p50_s=statistics.median(lag_acoustic),
                      acoustic_end_p95_s=quantile(lag_acoustic,.95),acoustic_end_values_s=lag_acoustic)
    return result,details

if __name__=='__main__':
    cli=argparse.ArgumentParser();cli.add_argument('manifest',type=Path);cli.add_argument('results',type=Path,nargs='+')
    args=cli.parse_args(); manifest=json.loads(args.manifest.read_text())
    for path in args.results:
        print(path.stem,json.dumps(summarize(manifest,[json.loads(x) for x in path.read_text().splitlines()])[0],ensure_ascii=False))
