# PCore接入合同

上游由PCore负责人维护。已验收固定版本与最新静态核查版本记录于 `manifests/upstream.json`。本仓库不包含PCore、GCore或HBM RTL。

1. 上层顶层为`dea8_pcore_control`。VPU接`vector_*`，SFU接`function_*`，分别保存完整命令和token；不从TB直接代替计算返回结果。
2. 两单元各最多一条外部命令在途；内部算术流水或4行ALPHA批处理不等于允许接收多条外部命令。VPU、SFU可以与Matrix重叠。
3. FACC/OACC通过ACC访问，workspace通过各自读写请求访问；不得旁路更改PCore内部存储。返回按协议顺序配对，保持信用额度。
4. GELU每次接收51行Gate并返回51行，first有效、vector_valid=01；PCore配对同一行Up交VPU。P_EXP返回26对P，末对仅第一行有效。
5. V沿token方向按16+16+16+3量化，最后8组双feature包的token_mask为0007，无效元素零填充。Q/K做RoPE，V不做RoPE。
6. valid/ready握手前保持完整数据；done回显完整命令，等所有输入、结果、存储与系数事务处理完。最后数据接收和done不能同一接收沿完成。
7. flush清除/排空旧代流水及系数服务，取消后不得污染新任务。当前测试不能替代所有非法输入和任意阶段取消覆盖。

最新PCore的256-bit包变化只在外发边界，VPU/SFU接口未改。需迁移联合测试台的tx256包接收、header/长度/dtype/scale轴/last与K/V commit检查，再重新做新PCore验收；不能把旧版本日志直接归于新接口。

4ns来自PCore集成时钟口径；当前SFU优化版未重新综合。约400拍、434拍均不能当作全部Job或全部VOP的统一硬上限。
