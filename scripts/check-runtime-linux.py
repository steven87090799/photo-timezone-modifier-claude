#!/usr/bin/env python3
# Developer-only Linux fixture/lifecycle check; Python is not an app dependency.
import subprocess, tempfile, pathlib, time, os, signal, json, shutil
root=pathlib.Path(__file__).resolve().parent.parent
engine=root/'.build/vendor-exiftool'
results={}
with tempfile.TemporaryDirectory(prefix='ptz-runtime-check-') as temp:
    staged=pathlib.Path(temp)/'engine'
    subprocess.run(['bash',str(root/'scripts/stage-runtime.sh'),str(engine),str(staged)],check=True,capture_output=True)
    size=lambda p:sum(f.stat().st_size for f in p.rglob('*') if f.is_file())
    results.update(vendor_bytes=size(engine),runtime_bytes=size(staged),png_bytes=(root/'app/Assets/AppIcon.png').stat().st_size)
    # Use an upstream disposable JPEG sample with EXIF; never mutate a user photo.
    original=engine/'t/images/Canon.jpg'
    test=pathlib.Path(temp)/'sample.jpg'; shutil.copy2(original,test)
    exe=['/usr/bin/perl',str(staged/'exiftool'),'-config','']
    before=json.loads(subprocess.check_output(exe+['-j','-G1','-DateTimeOriginal','-CreateDate','-ModifyDate',str(test)]))[0]
    subprocess.run(exe+['-overwrite_original','-ExifIFD:OffsetTimeOriginal=+08:00','-ExifIFD:OffsetTimeDigitized=+08:00','-ExifIFD:OffsetTime=+08:00',str(test)],check=True,capture_output=True)
    after=json.loads(subprocess.check_output(exe+['-j','-G1','-DateTimeOriginal','-CreateDate','-ModifyDate','-OffsetTime*',str(test)]))[0]
    assert all(after[k]==v for k,v in before.items())
    for tag in ('OffsetTimeOriginal','OffsetTimeDigitized','OffsetTime'): assert after['ExifIFD:'+tag]=='+08:00'
    results['trimmed_runtime_read_write']='passed; dates unchanged; all three offsets present'
    for cause in ('parent_sigkill',):
        script='''import subprocess,sys,time
p=subprocess.Popen(sys.argv[1:],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
p.stdin.write(b"-ver\\n-execute1\\n");p.stdin.flush()
while p.stdout.readline().strip()!=b"{ready1}": pass
print(p.pid,flush=True)
if sys.argv[0]=="-c": time.sleep(30)
'''
        # A real helper owns the command pipe; killing it exercises loss of the
        # application, not an ExifTool timeout with a still-running parent.
        parent=subprocess.Popen(['/usr/bin/python3','-c',script]+exe+['-stay_open','True','-@','-'],stdout=subprocess.PIPE)
        child=int(parent.stdout.readline())
        start=time.monotonic(); parent.kill(); parent.wait(timeout=3)
        for _ in range(200):
            try:
                stat=pathlib.Path(f'/proc/{child}/stat').read_text()
                state=stat.rsplit(')',1)[1].split()[0]
                stopped=state=='Z'
            except FileNotFoundError: stopped=True
            if stopped: break
            time.sleep(.01)
        if not stopped: os.kill(child,signal.SIGKILL)
        assert stopped,'ExifTool stayed alive after parent SIGKILL'
        results[cause+'_child_exit_seconds']=round(time.monotonic()-start,4)
    p=subprocess.Popen(exe+['-stay_open','True','-@','-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    p.stdin.write(b'-ver\n-execute1\n');p.stdin.flush()
    while p.stdout.readline().strip()!=b'{ready1}': pass
    start=time.monotonic();p.stdin.close();p.wait(timeout=3)
    assert p.returncode==0
    results['stdin_closed_child_exit_seconds']=round(time.monotonic()-start,4)
results['resource_bytes_removed']=results['vendor_bytes']-results['runtime_bytes']

print(json.dumps(results,indent=2))
