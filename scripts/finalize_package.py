from pathlib import Path
import json,hashlib,zipfile
R=Path(__file__).resolve().parents[1]
exclude={'build','_deps','.git','__pycache__'}
files=[p for p in R.rglob('*') if p.is_file() and not any(x in exclude for x in p.relative_to(R).parts) and p.relative_to(R).as_posix()!='manifests/package_sha256.json']
manifest={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(R/'manifests/package_sha256.json').write_text(json.dumps(manifest,indent=2))
print('Manifest files',len(files),'total bytes',sum(p.stat().st_size for p in files))
archive=R.parent/(R.name+'_upload.zip')
if archive.exists():raise SystemExit('Refuse archive overwrite: '+str(archive))
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for p in files+[R/'manifests/package_sha256.json']:z.write(p,p.relative_to(R).as_posix())
print(archive)
