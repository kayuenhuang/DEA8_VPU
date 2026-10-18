# DEA8 VPU / SFU

面向 DEA8 固定 M=51、Alveo U50 的 VPU 与 SFU RTL。仓库按模块维护代码、接入说明、独立数值测试和联合验证证据；PCore RTL由PCore负责人维护，通过固定版本外部依赖接入。

## 当前状态

2026-10-18核对原始日志：真实PCore＋VPU＋SFU的完整七Job功能回归，以及随机压力种子20261014、7、101全部PASS；每轮265408次矩阵发射、143条SFU命令，VPU保持32 lanes。SFU运算来自RTL/浮点IP，TB数学仅作独立答案检查。

**以上证据对应PCore提交 `e12af5bdef23af8faa80c09a3520c73bf87e37b0` 的旧外发接口。** 新提交 `86856b5c54ce41854e5dcf5a4e03d686b83fa520` 的VPU/SFU接口已静态核对兼容，但256-bit外发迁移与新版联合验收尚未完成。不能将旧版本PASS当作新版PASS。

本轮没有新综合、布局布线或上板结果；不宣称250 MHz或整核资源预算达标。

## 目录

| 路径 | 内容 |
|---|---|
| `VPU/vpu_rtl` | VPU顶层、共享算术、量化、流水和缓冲模块，共13个SV文件 |
| `VPU/vpu_vendor` | VPU所需FP32算术package，1个SV文件 |
| `SFU/rtl` | SFU顶层、宽精度exp/GELU/reciprocal、RoPE ROM；保留早期候选，详见模块说明 |
| `SFU/rom` | 已验证测试场景的RoPE系数及历史GELU系数文件 |
| `tests` | 严格数值、ALPHA控制器和真实七Job联合测试台 |
| `scripts` | 外部依赖获取、IP生成、仿真准备与运行工具 |
| `reports` | 原始功能/压力/定向测试日志及退出码 |
| `manifests` | 源码SHA256、固定上游版本和复现依赖清单 |
| `docs` | 模块、接口、验证范围说明 |

## 实现功能

| VPU操作 | 功能 |
|---|---|
| QK_POST | mask、MAX、差值、Score及行统计写回 |
| P_POST | 保持既定FP32顺序的行求和、l更新和量化 |
| OACC_SCALE | OACC与alpha的FP32乘法、顺序写回 |
| AFIN_QUANT | OACC乘reciprocal并量化 |
| ROPE_QUANT | Q/K的RoPE乘加、feature方向B16量化 |
| V_QUANT | 跨token方向B16量化，51 token按16+16+16+3分组；V不做RoPE |
| GU_POST | 接收SFU的GELU(G)，乘同一行Up后量化 |

VPU保留2×16共享FP32乘法通路，不将分别舍入的乘加替换成单次舍入FMA。保持MXINT8-B16的块指数、RNE、饱和、mask和尾部语义。

SFU提供四路exp、四路GELU、单路流水倒数及RoPE系数ROM。接口FP32；宽精度候选内部采用FP64 IP后转换回FP32，不将内部宽精度实现描述为全FP32硬件。

## 实测周期

同一旧PCore、同为FUNCTIONAL场景的实际Job周期：

| Job | 当前周期 |
|---|---:|
| K | 4252 |
| V | 3627 |
| Q | 27594 |
| Attention | 169483 |
| O | 28277 |
| G-U | 290394 |
| Down | 54901 |

本轮ALPHA四行批处理将完整回归中的单条ALPHA命令从3214拍降到934拍；GELU独立流水从190拍降到168拍，II=1。以上是指定场景仿真数据，不是板上延迟、硬性验收上限或新PCore的性能结果。压力模式包含额外等待，不能与功能周期直接混用。

## 接入与复现

以PCore的 `dea8_pcore_control` 为上层，类型使用 `pcore_pkg` / `pcore_control_pkg`，VPU和SFU分别接command/data/result/done、ACC、workspace和RoPE通道。不能绕过真实Matrix、QOZ和workspace。

参见 [接入说明](docs/INTEGRATION.md)、[模块说明](docs/MODULES.md)、[验证说明](docs/VALIDATION.md)。工具为Vivado 2022.2：xvlog编译、xelab以O0展开、xsim执行。浮点IP从官方安装生成，不随仓库提交生成的商业IP代码或仿真二进制。

```powershell
python scripts/fetch_pcore.py
& 'D:/Vivado/download/Vivado/2022.2/bin/vivado.bat' -mode batch -source scripts/create_sfu_ip.tcl
python scripts/prepare_sim.py --pcore _deps/DEA8_PCore/DEA8/Pcore
python scripts/run_sim.py --vivado D:/Vivado/download/Vivado/2022.2 --mode FUNCTIONAL
python scripts/run_sim.py --vivado D:/Vivado/download/Vivado/2022.2 --mode STRESS --seed 20261014
```

这组便携脚本是上传整理时新增的复现入口；原始PASS来自reports中所列的既有命令和源码快照。便携脚本的实际校验状态见 `reports/PACKAGE_CHECK.md`，不虚构重新完成的长回归。

## 当前限制

- 新版PCore统一tx256外发尚未联合回归；本仓库联合测试台仍对应冻结旧版接口。
- 任意Job、任意阶段的系统级flush覆盖尚不完整；已有GELU流水和ALPHA控制器定向flush证据。
- RoPE ROM测试文件绑定position_base=7、51个position；不是任意位置的通用系数服务。顶层默认参数816需要另配相应ROM，不能把base7文件直接当默认文件使用。
- SFU的宽精度流水有延迟和资源代价；GU还受PCore逐行GELU交互限制。
- 没有真实HBM、GCore八核整层、18层×10步去噪或板级验收结果。

PCore依赖来源：[fly040507/DEA8_PCore / DEA8/Pcore](https://github.com/fly040507/DEA8_PCore/tree/main/DEA8/Pcore)。本仓库不授予第三方依赖的额外许可。
