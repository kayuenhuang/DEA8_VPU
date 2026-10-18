# 模块与依赖

## VPU

| 文件 | 职责 |
|---|---|
| dea8_vpu_top.sv | 命令调度、数据及token管理、结果缓存、写回、flush与done |
| dea8_vpu_math_pkg.sv | 内部数据类型和数值辅助函数 |
| dea8_vpu_mul32_shared.sv | 2×16共享FP32乘法流水 |
| dea8_vpu_add_pipe.sv | FP32加法内部流水 |
| dea8_vpu_dsp_addsub.sv | DSP加减基础运算 |
| dea8_vpu_p_pipe.sv | P_POST求和和l更新流水 |
| dea8_vpu_qk_post_pair_v3.sv | QK双行mask/MAX/统计处理 |
| dea8_vpu_quant16.sv | 16元素块量化语义 |
| dea8_vpu_quant16_pipe.sv | 量化分阶段实现 |
| dea8_vpu_saved_ram.sv | 已保存数据的同步存储访问 |
| dea8_vpu_stream_ram.sv | 流数据缓冲存储 |
| dea8_vpu_v_quant_tile.sv | V量化的辅助模块；不代表顶层独立实现完整转置 |
| dea8_vpu_vector_ops.sv | 保留的向量操作辅助模块 |
| ../vpu_vendor/dea8_fp32_v3_pkg.sv | FP32算术依赖package |

顶层实际使用关系以RTL实例和 `vpu_rtl.f` 的编译清单为准。目录保留全部VPU源文件，未实例化的辅助模块不能计为顶层额外算术硬件。文件名含v3为历史沿用命名，不表示使用PCore负责人仓库V3工程。

## SFU

当前顶层实际使用：`dea8_sfu_top.sv`、`dea8_sfu_precision_pkg.sv`、`dea8_sfu_exp4_wide.sv`、`dea8_sfu_gelu4_wide.sv`、`dea8_sfu_recip_wide.sv`、`dea8_sfu_rope_rom.sv`。

其余fixed_pkg、gelu_lane、gelu4、exp4、recip是保留的早期候选；旧Q24 GELU已发现严格数学不匹配，不能代替当前wide候选。旧系数ROM不表示它仍是当前GELU执行路径。

实际IP延迟：sub64=14、exp64=45、reciprocal64=35、gmul64=12、gadd64=14；GELU使用reciprocal加精确乘2后总168拍。生成配置见 `scripts/create_sfu_ip.tcl`。GELU设计II=1已做独立测试，不能由此推断整个SFU控制器或GU每拍接收一行。
