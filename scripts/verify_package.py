from pathlib import Path
import hashlib,json,re
R=Path(__file__).resolve().parents[1]
for rel,expected in json.loads((R/'manifests/package_sha256.json').read_text()).items():
 assert hashlib.sha256((R/rel).read_bytes()).hexdigest()==expected,rel
for name in ['functional','stress_20261014','stress_7','stress_101']:
 d=R/'reports'/name;t=(d/'raw.log').read_text(errors='replace')
 assert (d/'exit_code.txt').read_text().strip()=='0'
 assert 'tb_pcore_control PASS jobs=7' in t and 'REAL_SFU_SEVEN_JOB_COVER commands=143 model_driver=0' in t
 assert not re.search(r'^\s*(Fatal:|Error:|ERROR:)',t,re.M)
print('PACKAGE_HASHES_AND_FOUR_ORIGINAL_RUN_LOGS_PASS')
