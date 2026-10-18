# 上传整理检查

2026-10-18：上传副本的VPU/SFU及联合测试台源文件逐文件与已验证快照比对，保持原始SHA256；只修改说明、增加便携脚本，不修改RTL。

- `scripts/prepare_sim.py`使用本机冻结PCore及既有官方生成IP，严格核对非IP源码SHA256，成功生成编译清单。
- `scripts/run_sim.py --compile-only`实际执行Vivado2022.2 xvlog，退出码0，标记COMPILE_ONLY_PASS。此次为上传副本编译检查，不是再次完成完整展开或功能仿真。
- `scripts/verify_package.py`检查上传包SHA256和四轮既有日志的退出码、Fatal/Error与最终PASS标记。
- PCore外部依赖下载及IP重新生成脚本为新增复现工具，本次未从零重建全部IP再运行长仿真。
- README、模块/接口/验证说明以及VPU来源说明中的相关称呼统一为PCore负责人。

原始长回归的依据为本目录functional、stress_20261014、stress_7、stress_101中的raw.log与exit_code.txt。原始日志保留本机路径以便追溯。
