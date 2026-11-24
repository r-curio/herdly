# Stands in for the notch's Approve click on one throwaway probe approval: waits for a new
# PermissionRequest record from a session whose cwd is the probe folder, waits for Herdly's
# receipt, then writes one allow decision.
import json,glob,os,time,sys
D=glob.glob(os.path.expanduser('~/Library/Application Support/Herdly/claude-events/*/'))[0]
probe=os.path.expanduser('~/tmp/herdly-probe')

def probe_sessions():
    out=set()
    for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
        try: r=json.load(open(f))
        except: continue
        if r.get('cwd')==probe and r.get('entrypoint')=='claude-desktop': out.add(r.get('sessionId'))
    return out
before=set(glob.glob(D+'*.json')); end=time.time()+240
while time.time()<end:
    for f in set(glob.glob(D+'*.json'))-before:
        before.add(f)
        try: r=json.load(open(f))
        except: continue
        if r.get('hook_event_name')!='PermissionRequest': continue
        rid=r.get('approval_request_id'); sess=r.get('session_id')
        print('PermissionRequest',r.get('tool_name'),'rid=',rid,'probe=',sess in probe_sessions(),'keys=',sorted(r)); sys.stdout.flush()
        if not rid or sess not in probe_sessions(): continue
        rc=os.path.join(D,rid+'.claude.receipt')
        for _ in range(100):
            if os.path.exists(rc): break
            time.sleep(0.1)
        print('receipt',os.path.exists(rc))
        dec={'request_id':rid,'decision':sys.argv[1],'decided_at':time.time()}
        tmp=os.path.join(D,'.herdly-probe-'+rid); open(tmp,'w').write(json.dumps(dec)); os.rename(tmp,os.path.join(D,rid+'.claude.decision'))
        print('decided',sys.argv[1])
        for _ in range(50):
            if os.path.exists(os.path.join(D,rid+'.claude.delivery')): print('delivery ack'); break
            time.sleep(0.1)
        sys.exit(0)
    time.sleep(0.1)
print('no approval seen')
