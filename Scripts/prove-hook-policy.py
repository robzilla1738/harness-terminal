#!/usr/bin/env python3
import argparse, json, os, socket, struct, subprocess, tempfile, threading, uuid
from pathlib import Path
parser = argparse.ArgumentParser(description="Isolated native policy response and redacted audit fixture; never changes installed policy.")
parser.add_argument('--cli', type=Path, required=True)
cli = parser.parse_args().cli.resolve()
with tempfile.TemporaryDirectory(prefix='hpolicy-', dir='/tmp') as directory:
    root = Path(directory); policy_id = str(uuid.uuid4()); rule_id = str(uuid.uuid4())
    policy = {'version':1,'id':policy_id,'name':'Fixture','contract':'claude-hooks-2026-10','enabled':True,'rules':[{'id':rule_id,'event':'PreToolUse','conditions':[{'field':'command','match':'contains','value':'fixture-protected'}],'decision':'deny','reason':'Fixture blocked'}]}
    file = root/'trusted-hook-policies.json'; file.write_text(json.dumps([{'policy':policy,'approvedAt':0}])) ; file.chmod(0o600)
    path = root/'audit.sock'; listener = socket.socket(socket.AF_UNIX); listener.bind(str(path)); listener.listen(); listener.settimeout(5)
    audits=[]
    def serve():
        with listener.accept()[0] as connection:
            connection.settimeout(2)
            def read(count):
                data=b''
                while len(data)<count:
                    chunk=connection.recv(count-len(data))
                    if not chunk: raise RuntimeError('truncated fixture request')
                    data+=chunk
                return data
            value=json.loads(read(struct.unpack('>I',read(4))[0])); audits.append(value)
            reply=json.dumps({'response':{'ok':{}}}).encode(); connection.sendall(struct.pack('>I',len(reply))+reply)
    worker=threading.Thread(target=serve);worker.start()
    env={**os.environ,'HARNESS_HOME':directory,'HARNESS_SERVER':str(path)}
    args=[str(cli),'hook-policy','evaluate','--policy',policy_id,'--contract','claude-hooks-2026-10','--event','PreToolUse']
    payload=json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':'printf fixture-protected RAW_INPUT_SECRET_SENTINEL'},'cwd':'/private/repository'}).encode()
    result=subprocess.run(args,input=payload,env=env,capture_output=True,timeout=3);worker.join(3);listener.close()
    assert result.returncode==0 and json.loads(result.stdout)['hookSpecificOutput']['permissionDecision']=='deny',result.stderr
    assert len(audits)==1 and 'RAW_INPUT_SECRET_SENTINEL' not in json.dumps(audits) and '/private/repository' not in json.dumps(audits)
    # No audited allowance can escape when its local daemon is unavailable.
    clear=json.dumps({'hook_event_name':'PreToolUse','tool_input':{'command':'printf harmless'}}).encode()
    unavailable=subprocess.run(args,input=clear,env=env,capture_output=True,timeout=3)
    assert unavailable.returncode==0 and json.loads(unavailable.stdout)['hookSpecificOutput']['permissionDecision']=='deny'
    malformed=subprocess.run(args,input=b'{',env=env,capture_output=True,timeout=3)
    assert malformed.returncode==0 and json.loads(malformed.stdout)['hookSpecificOutput']['permissionDecision']=='deny'
    policy['enabled']=False;file.write_text(json.dumps([{'policy':policy,'approvedAt':0}]));file.chmod(0o600)
    disabled=subprocess.run(args,input=b'{',env=env,capture_output=True,timeout=3)
    assert disabled.returncode==0 and json.loads(disabled.stdout)=={}, 'Explicitly disabled policy must not enforce malformed input or unavailable audit'
    assert b'\x1b' not in result.stdout+unavailable.stdout+malformed.stdout
    print(json.dumps({'provider_native_deny':True,'redacted_audit':True,'unavailable_audit_fails_closed':True,'malformed_input_fails_closed':True,'explicit_disabled_policy_does_not_enforce':True,'no_osc_in_json':True,'scope':'isolated CLI/helper socket'}))
