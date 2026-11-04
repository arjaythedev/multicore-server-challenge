#!/usr/bin/env python3
# Failure tests against a running server. Writes are claimed only if they really committed; nothing hangs; one bad request fails alone.
import http.client, json, subprocess, sys, threading, time, random, base64, hmac, hashlib
H,P='127.0.0.1',3110
SECRET=b'dev-secret'
def tok(uid):
    b=lambda d: base64.urlsafe_b64encode(d).rstrip(b'=')
    p=b(b'{"alg":"HS256","typ":"JWT"}')+b'.'+b(json.dumps({'sub':str(uid),'iat':int(time.time()),'exp':int(time.time())+3600}).encode())
    return (p+b'.'+b(hmac.new(SECRET,p,hashlib.sha256).digest())).decode()
def req(m,path,body=None,token=None,timeout=15):
    c=http.client.HTTPConnection(H,P,timeout=timeout); t=time.time()
    try:
        hd={'Content-Type':'application/json'}
        if token: hd['Authorization']='Token '+token
        c.request(m,path,json.dumps(body) if body is not None else None,hd)
        r=c.getresponse(); d=r.read(); return r.status,d,time.time()-t
    except Exception as e: return 0,str(e).encode(),time.time()-t
    finally: c.close()
def psql(q,db='asan'):
    return subprocess.run(['psql','-h','/var/run/postgresql','-U','postgres','-d',db,'-Atqc',q],capture_output=True,text=True).stdout.strip()
ok=True
def check(name,cond,detail=''):
    global ok
    print(('PASS ' if cond else 'FAIL ')+name,detail); ok=ok and cond
slug=json.loads(req('GET','/api/articles?limit=1')[1])['articles'][0]['slug']

# 1. one bad request in a group fails alone
tag=str(int(time.time())); res=[None]*60
def reg(i):
    name=f'dup{tag}' if i%3==0 else f'u{tag}x{i}'
    res[i]=req('POST','/api/users',{'user':{'username':name,'email':name+'@x.io','password':'password123'}})[0]
ts=[threading.Thread(target=reg,args=(i,)) for i in range(60)]; [t.start() for t in ts]; [t.join() for t in ts]
good=[res[i] for i in range(60) if i%3]; dup=[res[i] for i in range(60) if i%3==0]
check('duplicates fail alone',all(s==201 for s in good) and dup.count(201)==1 and dup.count(422)==19,f'good={set(good)} dup={sorted(set(dup))}')
res2=[None]*80
def cm(i):
    t=tok(1); 
    if i%4==0: res2[i]=req('POST',f'/api/articles/no-such-slug-{i}/comments',{'comment':{'body':'x'}},t)[0]
    else: res2[i]=req('POST',f'/api/articles/{slug}/comments',{'comment':{'body':f'g{i}'}},t)[0]
ts=[threading.Thread(target=cm,args=(i,)) for i in range(80)]; [t.start() for t in ts]; [t.join() for t in ts]
check('404 in a group leaves the rest',all(res2[i]==(404 if i%4==0 else 201) for i in range(80)),str(set(res2)))
# foreign-key failure: a token for a user that does not exist
s,_,_=req('POST',f'/api/articles/{slug}/favorite',None,tok(999999999))
check('unknown user write is rejected, not 500',s in(401,404),str(s))
res3=[None]*40
def mix(i):
    if i%5==0: res3[i]=req('POST',f'/api/articles/{slug}/comments',{'comment':{'body':'x'}},tok(999999999))[0]
    else: res3[i]=req('POST',f'/api/articles/{slug}/comments',{'comment':{'body':f'm{i}'}},tok(2))[0]
ts=[threading.Thread(target=mix,args=(i,)) for i in range(40)]; [t.start() for t in ts]; [t.join() for t in ts]
check('FK failure fails alone',all(res3[i]==201 for i in range(40) if i%5) and all(res3[i] in(401,404) for i in range(0,40,5)),str(set(res3)))
s,d,_=req('POST','/api/articles',{'article':{'title':'a\u0000b','description':'d','body':'b'}},tok(1))
check('NUL in text is 422',s==422,str(s))
s,_,_=req('GET','/api/articles?tag=%FF%FE'); check('invalid UTF-8 tag is an empty list',s==200,str(s))
s,_,_=req('GET','/api/articles/%FF'); check('invalid UTF-8 slug is 404',s==404,str(s))
s,_,_=req('GET','/api/articles?offset=99999999999999999&limit=5'); check('huge offset',s==200,str(s))

# 2. Postgres restarts and backend kills under writes: every claimed write exists, nothing hangs
stop=False; claimed=[]; lat=[]; stat={}; lock=threading.Lock()
marker='fail'+tag
def writer(k):
    i=0;t=tok(10+k)
    while not stop:
        i+=1; body=f'{marker}-{k}-{i}'
        s,d,l=req('POST',f'/api/articles/{slug}/comments',{'comment':{'body':body}},t)
        with lock:
            lat.append(l); stat[s]=stat.get(s,0)+1
            if s==201: claimed.append(json.loads(d)['comment']['id'])
def reader(k):
    while not stop:
        s,d,l=req('GET','/api/articles?limit=10',None,tok(20+k) if k%2 else None)
        with lock:
            lat.append(l); stat[s]=stat.get(s,0)+1
ts=[threading.Thread(target=writer,args=(k,)) for k in range(16)]+[threading.Thread(target=reader,args=(k,)) for k in range(16)]
[t.start() for t in ts]
time.sleep(3)
killed=psql("SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name='conduit'")
print('terminated backends:',killed); time.sleep(4)
subprocess.run(['pg_ctlcluster','18','main','restart','-m','immediate'],capture_output=True); print('postgres crashed+restarted'); time.sleep(5)
subprocess.run(['pg_ctlcluster','18','main','stop','-m','immediate'],capture_output=True); print('postgres down 6 s'); 
time.sleep(6)
down=dict(stat)
subprocess.run(['pg_ctlcluster','18','main','start'],capture_output=True); print('postgres back'); time.sleep(8)
stop=True; [t.join() for t in ts]
print('status counts:',stat,'max latency %.1fs'%max(lat))
check('no request hung past client timeout',max(lat)<12,'%.1f'%max(lat))
check('no connection-level failures',stat.get(0,0)==0,str(stat.get(0,0)))
time.sleep(1)
found=set(int(x) for x in psql(f"SELECT id FROM comments WHERE body LIKE '{marker}-%'").split())
missing=[c for c in claimed if c not in found]
check('every claimed write committed',not missing,f'claimed={len(claimed)} in_db={len(found)} missing={len(missing)}')
s,_,_=req('GET','/api/tags'); check('reads recover',s==200,str(s))
s,_,_=req('POST',f'/api/articles/{slug}/comments',{'comment':{'body':'after'}},tok(3)); check('writes recover',s==201,str(s))
n=psql("SELECT count(*) FROM pg_stat_activity WHERE application_name='conduit'"); check('connections stay within limit',int(n)<=95,n)
print('RESULT','PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
