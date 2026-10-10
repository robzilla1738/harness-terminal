#!/usr/bin/env python3
"""Check resize-vote cleanup with disposable PTYs; never touches installed services."""
import argparse
import json, os, socket, struct, subprocess, tempfile, time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bin-dir', type=Path, required=True)
args = parser.parse_args()
binary = args.bin_dir.resolve() / 'HarnessDaemon'
with tempfile.TemporaryDirectory(prefix='hsize-', dir='/tmp') as home:
    root = Path(home)
    log = (root/'service.log').open('wb')
    owner = subprocess.Popen([str(binary)], env={**os.environ,'HARNESS_HOME':home,'SHELL':'/bin/sh'}, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    peers=[]
    def connect():
        s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(str(root/'harness.sock')); return s
    def read(s,n):
        data=b''
        while len(data)<n:
            chunk=s.recv(n-len(data))
            if not chunk: raise RuntimeError('closed')
            data+=chunk
        return data
    def call(s,method,values=None):
        data=json.dumps({'request':{method:values or {}}}).encode()
        s.sendall(struct.pack('>I',len(data))+data)
        while True:
            first=read(s,1)
            if first==b'\xf5': read(s,struct.unpack('>I',read(s,4))[0]); continue
            return json.loads(read(s,struct.unpack('>I',first+read(s,3))[0]))['response']
    def request(method,values=None):
        with connect() as s: return call(s,method,values)
    def size():
        return json.loads(request('paneQuery',{'surfaceID':surface,'kind':'size'})['text']['_0'])
    def vote(s,cols,rows):
        assert 'ok' in call(s,'resizeSurface',{'surfaceID':surface,'cols':cols,'rows':rows})
    def expect(cols,rows,label):
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            actual=size()
            if actual=={'cols':cols,'rows':rows}: print(label,actual,flush=True); return
            time.sleep(.02)
        raise AssertionError((label,actual,{'cols':cols,'rows':rows}))
    try:
        deadline=time.monotonic()+10
        while True:
            try:
                if 'pong' in request('ping'): break
            except OSError: pass
            if time.monotonic()>deadline: raise RuntimeError('startup: '+(root/'service.log').read_text())
            time.sleep(.05)
        assert request('daemonStats')['daemonStats']['_0'].get('sessionHostPID'), 'requires session host'
        surface=request('createSurface',{'cwd':home,'shell':'/bin/sh'})['surfaceID']['_0']
        small=connect(); peers.append(small); large=connect(); peers.append(large)
        vote(small,80,24); vote(large,120,40)
        expect(80,24,'two clients use the smaller size')
        small.close()
        expect(120,40,'closing a non-stream resize client releases its vote')
        vote(large,130,45)
        expect(130,45,'remaining client can grow')
        small=connect(); peers.append(small)
        assert 'ok' in call(small,'subscribeSurfaceOutput',{'surfaceID':surface,'label':'resize-proof'})
        vote(small,90,25)
        expect(90,25,'stream client votes')
        assert 'ok' in call(small,'detachSurface',{'surfaceID':surface})
        expect(130,45,'explicit detach applies the remaining size')
        assert 'ok' in call(small,'subscribeSurfaceOutput',{'surfaceID':surface,'label':'resize-proof'})
        vote(small,90,25)
        small.close()
        expect(130,45,'socket close applies the remaining size')
        print('PASS',flush=True)
    finally:
        for s in peers: s.close()
        try: request('shutdownDaemon',{'requireEmpty':False})
        except (OSError,RuntimeError): pass
        try: owner.wait(timeout=10)
        except subprocess.TimeoutExpired: owner.terminate(); owner.wait(timeout=5)
        log.close()
