import ctypes, json, time, os, sys, hashlib
T=sys.argv[1]
L=ctypes.CDLL("/home/claude/cablesend/target/debug/libcablesend.so")
L.cs_next_event.restype=ctypes.c_void_p
L.cs_free_string.argtypes=[ctypes.c_void_p]
L.cs_receive_start.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint16,ctypes.c_uint16]
L.cs_receive_start.restype=ctypes.c_int
L.cs_send.argtypes=[ctypes.c_char_p]*3
L.cs_scan.argtypes=[ctypes.c_uint16]
L.cs_answer.argtypes=[ctypes.c_int]
def drain():
    out=[]
    while True:
        p=L.cs_next_event()
        if not p: return out
        out.append(json.loads(ctypes.string_at(p).decode())); L.cs_free_string(p)
BUF=[]
def wait(pred, t=30):
    end=time.time()+t
    while time.time()<end:
        BUF.extend(drain())
        for i,e in enumerate(BUF):
            if pred(e):
                del BUF[:i+1]; return e, []
        time.sleep(0.05)
    raise SystemExit("TIMEOUT, buffered: %s"%BUF[-5:])
assert L.cs_version()==1
port=L.cs_receive_start((T+"/out").encode(),b"ffi-rx",54201,54203); print("bound",port); assert port==54201
assert L.cs_receive_start(b"x",b"y",54202,54203)==-1; print("double start -> -1 ok")
# probe (connect+close) must not generate events
import socket; s=socket.create_connection(("127.0.0.1",54201)); s.close(); time.sleep(0.5)
ev=[e for e in drain() if e["event"] in("error","offer")]; print(ev); assert ev==[]; print("probe silent ok")
# accepted transfer
L.cs_send(b"127.0.0.1:54201",b"ffi-tx",(T+"/big.bin\n"+T+"/n.txt").encode())
o,_=wait(lambda e:e["event"]=="offer"); print("offer:",o["peer"],[f["name"] for f in o["files"]])
L.cs_answer(1)
wait(lambda e:e["event"]=="done" and e["dir"]=="in")
wait(lambda e:e["event"]=="done" and e["dir"]=="out")
BUF.clear()
h=lambda p:hashlib.sha256(open(p,"rb").read()).hexdigest()
assert h(T+"/big.bin")==h(T+"/out/big.bin"); print("20MB identical ok")
# declined
L.cs_send(b"127.0.0.1:54201",b"ffi-tx",(T+"/n.txt").encode())
wait(lambda e:e["event"]=="offer"); L.cs_answer(0)
e,_=wait(lambda e:e["event"]=="error" and e["dir"]=="out"); print("declined ->",e["message"])
assert "rejected the transfer" in e["message"]
BUF.clear()  # the receiver's own "rejected locally" arrives first and is consumed above
# connect failure
L.cs_send(b"127.0.0.1:1",b"x",(T+"/n.txt").encode())
e,_=wait(lambda e:e["event"]=="error" and e["dir"]=="out"); print("refused ->",e["message"][:50])
assert "refus" in e["message"].lower(), e
BUF.clear()
# scan finds our own beacon? (loopback is filtered) -> empty list
L.cs_scan(54203); e,_=wait(lambda e:e["event"]=="scan"); print("scan:",e["peers"])
# stop and restart
L.cs_receive_stop()
assert L.cs_receive_start((T+"/out2").encode(),b"again",54201,54203)==54201; print("restart ok")
L.cs_receive_stop(); print("ALL OK")
# two concurrent scans must both finish (port contention)
L.cs_scan(54203); L.cs_scan(54203)
wait(lambda e:e["event"]=="scan",20); wait(lambda e:e["event"]=="scan",20); print("2 concurrent scans ok")
