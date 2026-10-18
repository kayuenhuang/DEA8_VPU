from pathlib import Path
import argparse,json,hashlib
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--pcore',type=Path,required=True);p.add_argument('--ip64-root',type=Path);p.add_argument('--gelu-ip-root',type=Path);p.add_argument('--output',type=Path,default=R/'build/prepared');a=p.parse_args()
D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
files=[]
for item in json.loads((R/'manifests/tested_sources.json').read_text()):
 rel=Path(item['path']);parts=rel.parts
 if parts[0]=='PCore':src=a.pcore.joinpath(*parts[1:]).resolve()
 elif parts[0] in ['ip64_retry','gelu_ip']:
  base=(a.ip64_root if parts[0]=='ip64_retry' else a.gelu_ip_root) or R/'build/ip/generated'
  src=base.joinpath(*parts[2:]).resolve()
 elif parts[0]=='tb':src=R/'tests'/rel.name
 else:src=R/rel
 if not src.is_file():raise SystemExit('Required source absent: '+str(src))
 if parts[0] not in ['ip64_retry','gelu_ip']:
  actual=hashlib.sha256(src.read_bytes()).hexdigest()
  if actual!=item['source_sha256']:raise SystemExit('Source SHA256 differs from verified snapshot: '+str(src))
 files.append(src)
(D/'sources.f').write_text(''.join('"'+x.as_posix()+'"\n' for x in files))
(D/'inputs_sha256.json').write_text(json.dumps({str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in files},indent=2))
print(D/'sources.f')
