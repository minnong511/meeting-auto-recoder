"""Persistent local ASR worker. stdin/stdout are a bounded JSON protocol, never a network service."""
import base64, json, os, sys
protocol_out = sys.stdout
sys.stdout = sys.stderr  # libraries must not write into the response protocol
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

def reply(value):
    protocol_out.write(json.dumps(value, ensure_ascii=False) + '\n')
    protocol_out.flush()

try:
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    model = load(sys.argv[1])
    reply({'ready': True, 'protocol': 1})
    while True:
        line = sys.stdin.buffer.readline(3_000_001)
        if not line: break
        if len(line) > 3_000_000 or not line.endswith(b'\n'): raise ValueError('request too large')
        request = json.loads(line)
        identifier = request.get('id')
        try:
            raw = base64.b64decode(request['audio'], validate=True)
            if not raw or len(raw) % 4 or len(raw) > 32 * 16000 * 4: raise ValueError('invalid audio length')
            audio = np.frombuffer(raw, dtype='<f4')
            if not np.isfinite(audio).all(): raise ValueError('invalid audio values')
            result = model.generate(audio, language='Korean', max_tokens=512, temperature=0.0, verbose=False)
            mx.synchronize()
            text = result.text.strip()
            if getattr(result, 'generation_tokens', 0) >= 512: raise ValueError('output token limit reached')
            reply({'id': identifier, 'text': text})
        except Exception as error:
            reply({'id': identifier, 'error': str(error)})
except Exception as error:
    reply({'error': str(error)})
    sys.exit(1)
