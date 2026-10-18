# 验证证据与复现边界

## 原始证据

`reports/functional/raw.log` 和三个 `reports/stress_<seed>/raw.log` 均有以下最终标记，并有退出码0：

```
REAL_SFU_SEVEN_JOB_COVER commands=143 model_driver=0
tb_pcore_control PASS jobs=7 issues=265408
```

FUNCTIONAL与STRESS的模式、seed、背压覆盖计数在原始日志中。各轮使用相同真实PCore/VPU/SFU RTL/IP，外部输入、接收、随机通道等待与独立数值golden由TB提供。FP32输出逐位检查，没有通过增加误差容限或关闭断言取得PASS。

- GELU独立测试：4128次比较、7次flush、35拍输出背压；168拍延迟、II=1。
- ALPHA批处理：8条完整命令、408行严格比较，尾3行正确，108拍存储请求背压，另有中断命令及flush后重新执行检查。
- 系统压力种子：20261014、7、101；每个种子完整七Job、143条SFU命令，保留输入/输出等待、顺序、完成保持及生命周期覆盖检查。

`manifests/tested_sources.json`记录原始编译顺序与源码哈希。路径前缀是逻辑布局，不表示将PCore或Vivado IP生成源码复制进本仓库。`manifests/package_sha256.json`用于本次上传包完整性。

## 不包含的结论

未验证最新tx256 PCore联合链路；未覆盖任意Job任意阶段整系统flush；无本轮新综合/PnR、资源预算或上板结果。宽精度算术的样本PASS不是整个FP32域的数学正确舍入证明。RoPE只验证指定51位置窗口。

## 运行

Vivado2022.2、Python3、Git。先获取固定外部PCore并生成浮点IP，再准备独立build目录。`scripts/run_sim.py`逐阶段保存命令、时间、退出码和日志，同时要求最终PASS标记且没有Fatal/Error。每次运行使用新的目录，不覆盖已有结果。不自动启动综合。

上传新增脚本的本地检查见 `reports/PACKAGE_CHECK.md`；不要将脚本整理本身当作重新运行完整回归。原始日志中的本机绝对路径用于追溯，复现不要求相同路径。
