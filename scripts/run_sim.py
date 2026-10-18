from pathlib import Path
import argparse,subprocess,json,datetime,shutil,re,sys
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--vivado',type=Path,required=True);p.add_argument('--prepared',type=Path,default=R/'build/prepared');p.add_argument('--mode',choices=['FUNCTIONAL','STRESS'],default='FUNCTIONAL');p.add_argument('--seed',type=int,default=20261014);p.add_argument('--compile-only',action='store_true');a=p.parse_args()
D=R/'build'/('sim_'+a.mode.lower()+'_'+str(a.seed)+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));D.mkdir(parents=True,exist_ok=False)
shutil.copy2(a.prepared/'sources.f',D/'sources.f')
shutil.copy2(a.vivado/'data/xsim/xsim.ini',D/'xsim.ini')
for n in ['rope_base7_rom256.mem','gelu_uniform256_q24.mem']:shutil.copy2(R/'SFU/rom'/n,D/n)
libs=['xbip_utils_v3_0_10','axi_utils_v2_0_6','xbip_pipe_v3_0_6','xbip_dsp48_wrapper_v3_0_4','xbip_dsp48_addsub_v3_0_6','xbip_dsp48_multadd_v3_0_6','xbip_bram18k_v3_0_6','mult_gen_v12_0_18','floating_point_v7_1_15','unisims_ver','unimacro_ver','secureip','xpm']
commands=[]
def run(name,args):
 c=dict(stage=name,command=[str(a.vivado/'bin'/args[0])]+args[1:],cwd=str(D),start=datetime.datetime.now().isoformat());commands.append(c)
 with (D/(name+'_console.log')).open('w') as f:
  child=subprocess.Popen(c['command'],cwd=D,stdout=f,stderr=subprocess.STDOUT);c['pid']=child.pid;(D/'commands.json').write_text(json.dumps(commands,indent=2));c['exit']=child.wait()
 (D/'commands.json').write_text(json.dumps(commands,indent=2));assert c['exit']==0,name+' tool failed'
try:
 run('compile',['xvlog.bat','-sv','-f','sources.f',str(a.vivado/'data/verilog/src/glbl.v'),'-log','compile.log'])
 if a.compile_only:
  (D/'exit_code.txt').write_text('0');print('COMPILE_ONLY_PASS (not elaboration or functional PASS)',D);sys.exit(0)
 run('elaborate',['xelab.bat','tb_pcore_vpu_sfu','glbl','-s','joint','--O0','--debug','typical','--mt','off','-timescale','1ns/1ps',*[x for lib in libs for x in ['-L',lib]],'-log','elaborate.log'])
 (D/'run.options').write_text(f'-runall\n-testplusarg MODE={a.mode}\n-testplusarg SEED={a.seed}\n')
 run('simulate',['xsim.bat','joint','-f','run.options','-log','simulation.log'])
 text=(D/'simulation.log').read_text(errors='replace')
 assert not re.search(r'^\s*(Fatal:|Error:|ERROR:)',text,re.M),'simulation assertions failed'
 assert 'tb_pcore_control PASS jobs=7' in text and 'REAL_SFU_SEVEN_JOB_COVER commands=143 model_driver=0' in text,'final markers absent'
 if a.mode=='STRESS':assert f'CONTROL_COVER seed={a.seed} stress=1' in text,'stress coverage marker absent'
 (D/'exit_code.txt').write_text('0');print('SEVEN_JOB_PASS',a.mode,D)
except Exception as error:
 (D/'exit_code.txt').write_text('1');(D/'failure.txt').write_text(repr(error));print('FAIL',repr(error),D);sys.exit(1)
