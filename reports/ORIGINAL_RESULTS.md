# SFU 耗时优化与压力验证（进行中）

## 最终核查：功能及三个随机压力种子全部通过
2026-10-18核对原始日志：FUNCTIONAL以及STRESS种子20261014、7、101均出现完整七Job PASS和`REAL_SFU_SEVEN_JOB_COVER commands=143 model_driver=0`。各运行退出码0，总验证退出码0，最终阶段`FUNCTIONAL_AND_THREE_STRESS_PASS`。种子101于2026-10-18 03:50:18结束。本节取代下文早期“仍运行/尚未启动”进度快照；保留历史记录供追溯。尚未进行本轮综合、布局布线和上板验证。

## 2026-10-18 最新原始日志核查
- 优化版完整七Job FUNCTIONAL：PASS，包装器退出码0，143条真实SFU命令，265408次发射；`joint/functional.log`、`joint/exit_code.txt`。
- 随机压力种子20261014：PASS，退出码0；`stress_20261014/stress.log`。原有压力覆盖检查通过，SFU命令等待724拍、结果等待15374拍、done等待722拍；ACC背压97240拍、workspace背压3520拍，全部7个Job的完成保持检查通过，具体逐Job保持周期见原始日志。
- 种子7：仍运行，当前GU；进程xsimk PID23540仍存在，尚无最终退出码或PASS。
- 种子101：尚未启动，须待种子7通过。三个种子尚未全部通过。

同为FUNCTIONAL模式、相同PCore/VPU及原数值检查的实际周期比较：

| 项目 | 基线 | 优化版 | 说明 |
|---|---:|---:|---|
| 单条ALPHA_EXP命令 | 3214 | 934 | 51行读写完整；55条命令均为934拍 |
| K | 4252 | 4252 | 不变 |
| V | 3627 | 3627 | 不变 |
| Q | 27594 | 27594 | 不变 |
| Attention | 294883 | 169483 | 减少约42.5% |
| O | 28277 | 28277 | 不变 |
| GU | 326298 | 290394 | 减少约11.0% |
| Down | 54900 | 54901 | 增加1拍 |

这些是仿真周期，不是综合时序或板上时间；未运行新综合。压力场景周期不与上述功能周期混用。

## 基线与范围
- 基线：`D:\VLA_XSim_Work\DEA8_GELU_Wide_20261017_201654`，真实PCore+VPU+SFU七Job功能PASS；K4252、V3627、Q27594、Attention294883、O28277、GU326298、Down54900拍。
- 独立候选：`D:\VLA_XSim_Work\DEA8_SFU_Perf_20261017_220735`。
- PCore、VPU原样复制、逐文件比对一致；不改变冻结接口和32-lane VPU。本轮修改SFU两份RTL。没有运行综合或布局布线。
- `before/sfu_rtl`保存修改前源文件，`evidence/before_sha256.json`、`after_sha256.json`记录哈希。完整回归输入冻结清单为`evidence/wide_joint_inputs_sha256.json`。

## 实际修改
1. `SFU/rtl/dea8_sfu_top.sv`：ALPHA_EXP由逐行复制到4个lane改为4行共用一次exp等待。存储读请求仍最多1笔在途，不要求PCore改变响应排序。顺序收齐最多4行后并行计算，依次写回；51行尾组仅写3行。写回遇到ready低保持当前地址和数据，done等全部51行写回完成后发出。
2. `SFU/rtl/dea8_sfu_gelu4_wide.sv`：FP64 `2/den`改为FP64 reciprocal后按二进制指数精确乘2。仍按原顺序计算其他乘加，末端RNE到FP32。复用已生成的真实` sfu_recip64_ip`，不使用数学模型供结果。实测数据通路从190拍缩短到168拍，II仍为1。未进行4ns时序验证。

## 已完成定向验证
| 测试 | 原始日志 | 结果 |
|---|---|---|
| GELU独立逐位数值、背压、flush | `gelu_numeric/numeric.log` | PASS；4128次比较、7次flush、35拍输出背压；168拍、II=1 |
| ALPHA批处理、随机读延迟及请求背压、done保持、flush后重启 | `alpha_numeric/numeric.log` | PASS；8条完整命令、408行写回；108拍请求背压；尾3行正确；另1条中断命令 |

每个测试的精确命令、工具退出码、输入哈希分别在对应目录的`commands.json`、`exit_code.txt`、`inputs_sha256.json`。运行方式为本机Python执行对应目录的`run.py`，工具为Vivado2022.2自带xvlog/xelab/xsim。未放宽逐位数值判定。

ALPHA随机存储场景的前7条完整命令分别为1133、1124、1152、1114、1137、1165、1119拍。同一测试台和种子下，旧RTL对照为3422、3392、3406、3398、3424、3415、3425拍，7条命令357行均逐位PASS；原始日志`alpha_baseline/numeric.log`、包装器退出码0。平均周期及日志SHA256见`evidence/alpha_benchmark.json`。随机等待序列随各自仿真时钟推进，不能理解为逐事务完全相同的等待长度。这是独立模块场景，不等于完整Attention或GU的加速比例，也不能直接与完整回归3214拍当作同一环境比较。

## 完整功能与随机压力验证
`run_validation.py`已启动，单个串行验证流程：
1. 优化版完整七Job FUNCTIONAL：`joint/run.py`，记录实际周期，确认全部143条真实SFU命令。
2. 只有功能回归PASS后才继续STRESS种子20261014、7、101，每个种子独立目录`stress_<seed>`。复用同一已展开快照，不重复编译或并发启动完整长仿真。
3. 每一步同时检查工具退出码、Fatal/Error以及最终七Job/真实SFU覆盖标记，失败即停止后续阶段，不自动重试。

当前状态见`validation_stage.txt`、`validation_commands.json`，最终退出码见`validation_exit_code.txt`。本报告初次写入时完整功能与三个压力种子尚未完成，不能称为PASS。

## 压力测试台增加的实际激励
- `tb/tb_pcore_vpu_sfu.sv`新增TB通道延迟适配器，对真实SFU命令、结果、done、RoPE请求施加固定种子伪随机1～7拍等待；一旦向接收方呈现valid，保持至握手。仅延迟传输，不计算或替换结果。
- 原有数值、数量、顺序、生命周期和压力覆盖断言保留；新增真实SFU结果、done、存储请求在背压时的保持断言。
- 原有VPU、外部供数、出数、完成保持测试继续执行。压力模式下的周期不得当作无背压性能。
- 联合压力中并未增加任意时间中止整Job的flush测试。flush证据来自GELU流水与ALPHA真实SFU控制器定向测试，不能夸大为整个系统所有阶段flush覆盖。

## 剩余瓶颈
P_EXP仍逐个行对等待，reciprocal统计仍单行处理，GU仍受PCore逐行交互限制。此轮先验证有限修改的正确性和周期收益，再决定是否继续扩大调度重叠。没有新LUT/DSP/RAM或WNS结果，不宣称资源预算、250MHz或系统上板达标。
