# Logs metadata only (event names, tool names, key names, registry fields) for Claude Desktop Code
# sessions: new ~/.claude/sessions entries, new desktop session files, and Herdly hook records whose
# session is a desktop one. Usage: python3 -I watch.py <log> [seconds]. Writes nothing else.
import json,glob,os,time,sys
out=open(sys.argv[1],'a')
H=os.path.expanduser('~')
E=H+'/Library/Application Support/Herdly/claude-events'
DS=H+'/Library/Application Support/Claude/claude-code-sessions'
def desk():
    m={}
    for f in glob.glob(DS+'/*/*/local_*.json'):
        try: d=json.load(open(f))
        except: continue
        m[d.get('cliSessionId')]={k:d.get(k) for k in ('sessionId','cwd','isArchived','permissionMode','lastActivityAt')}
    return m
seen=set(glob.glob(E+'/*/*.json')); seenreg=set(glob.glob(H+'/.claude/sessions/*.json')); dk=set(desk())
def log(*a): out.write(time.strftime('%H:%M:%S ')+' '.join(map(str,a))+'\n'); out.flush()
log('start')
end=time.time()+int(sys.argv[2]) if len(sys.argv)>2 else time.time()+1500
while time.time()<end:
    d=desk()
    for k in set(d)-dk: log('DESKTOP_SESSION',k,json.dumps(d[k]))
    dk|=set(d)
    for f in set(glob.glob(H+'/.claude/sessions/*.json'))-seenreg:
        seenreg.add(f)
        try: r=json.load(open(f)); log('REGISTRY',os.path.basename(f),json.dumps({k:r.get(k) for k in ('pid','sessionId','entrypoint','kind','status','cwd')}))
        except Exception as e: log('REGISTRY_ERR',f,e)
    for f in set(glob.glob(E+'/*/*.json'))-seen:
        seen.add(f)
        try: r=json.load(open(f))
        except: continue
        if r.get('session_id') in d:
            log('HOOK',r.get('hook_event_name'),r.get('tool_name'),'term=',r.get('hc_terminal_id'),'keys=',sorted(r))
    time.sleep(2)
log('end')
