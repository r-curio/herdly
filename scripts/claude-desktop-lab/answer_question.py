# Stands in for the notch click on one throwaway probe question: waits for a new .question whose
# session is a claude-desktop session in ~/tmp/herdly-probe, waits for Herdly's receipt, then writes
# one answer naming the option that contains argv[1]. Questions from any other session are ignored.
import json,glob,os,time,sys
D=glob.glob(os.path.expanduser('~/Library/Application Support/Herdly/claude-events/*/'))[0]
R=os.path.join(D,'.herdly-claude-questions')
probe=os.path.expanduser('~/tmp/herdly-probe')
def probe_sessions():
    out=set()
    for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
        try: r=json.load(open(f))
        except Exception: continue
        if r.get('cwd')==probe and r.get('entrypoint')=='claude-desktop': out.add(r.get('sessionId'))
    return out
want=sys.argv[1]; before=set(glob.glob(R+'/*.question')); end=time.time()+180
while time.time()<end:
    new=set(glob.glob(R+'/*.question'))-before
    for q in new:
        before.add(q)
        req=json.load(open(q)); rid=req['requestID']
        if req['sessionID'] not in probe_sessions(): continue
        print('request keys',sorted(req)); sys.stdout.flush()
        rc=q+'-receipt'
        for _ in range(100):
            if os.path.exists(rc): break
            time.sleep(0.2)
        rec=json.load(open(rc)); print('receipt at',rec['receivedAt'])
        opts=req['prompts'][0]['options']; print('options',opts); pick=next(o for o in opts if want.lower() in o.lower())
        ans={k:req[k] for k in ('requestID','installationID','sourceScope','eventDirectory','sessionID','promptID','toolUseID')}
        ans.update(answers=[{'kind':'option','answer':pick}],kind='option',answer=pick,decidedAt=time.time())
        tmp=os.path.join(R,'.tmp-'+rid); open(tmp,'w').write(json.dumps(ans)); os.rename(tmp,os.path.join(R,rid+'.question-answer'))
        print('answered',want)
        for _ in range(50):
            if os.path.exists(os.path.join(R,rid+'.question-delivery')): print('delivery ack written'); break
            time.sleep(0.2)
        sys.exit(0)
    time.sleep(0.2)
print('no question seen')
