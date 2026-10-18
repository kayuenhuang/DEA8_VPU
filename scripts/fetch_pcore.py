from pathlib import Path
import subprocess,json
R=Path(__file__).resolve().parents[1];cfg=json.loads((R/'manifests/upstream.json').read_text())
D=R/'_deps/DEA8_PCore'
if D.exists():raise SystemExit('Destination exists; inspect/reuse explicitly rather than overwrite: '+str(D))
D.parent.mkdir(exist_ok=True)
def run(*a):subprocess.run(a,check=True,cwd=R)
run('git','clone','--filter=blob:none','--no-checkout',cfg['repository'],str(D))
run('git','-C',str(D),'config','core.autocrlf','false')
run('git','-C',str(D),'sparse-checkout','set','DEA8/Pcore')
run('git','-C',str(D),'checkout','--detach',cfg['tested_commit'])
print(D/'DEA8/Pcore')
