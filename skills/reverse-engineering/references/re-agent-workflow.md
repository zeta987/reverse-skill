# RE Agent 工作流门闩（静态↔动态）

> 来源启发：binary-re 阶段划分、社区 RE skill（Frida/r2/Ghidra/IDA 循环）、Cerberus 三头环（静/动/插桩）  
> Issue #65 增量：IAT 修复铁律、恶意样本六阶段映射、.NET/DLL·SYS 等价路径（2026-08-12）  
> 适用：`reverse-engineering/`、`ida-reverse/`、`radare2/`、`malware-analysis/`、与 cre 角色交接

## 0. 启动

```text
□ scope.md：offline 样本路径 或 授权设备/靶机
□ tool-index：file/strings/r2/ida/frida 等实际路径
□ 角色：cre（ops/role-map）
```

## 1. Triage（5–15 分钟 · 强制起点）

```text
□ 计算样本 Hash（MD5/SHA256）→ 唯一 ID
□ 识别文件类型：EXE / DLL / SYS / ELF / Mach-O / .NET / 脚本 等
□ file / DIE / 熵 / 壳特征（PEiD / DIE / Exeinfo 等）
□ 架构：x86 / x64 / ARM；编译语言线索（VC++ / Delphi / .NET / Go / Rust）
□ 加壳类型线索：UPX / ASPack / VMProtect / Themida / 未知混淆
□ strings / rabin2 -z 捡漏
□ MUST 导入/导出锚点（见下方「导入表硬门与等价路径」）
□ 产出：E-triage（MUST 含 imports 或等价锚点分类摘要）+ 假设清单（勿过早下结论）
```

**阶段门闩（Triage → Static/Dynamic）**：E-triage 中未记录 imports **或** 合法等价锚点摘要前，MUST NOT 进入 Dynamic（除非已记录 IAT 修复失败并选择动态旁路，见 §1.2），也 MUST NOT 声称「基础分诊完成」。解析失败时仍 MUST 把失败输出写入 Evidence，不得跳过。用户要求「重做导入表检查」时 MUST 重做 imports/等价步骤本身，禁止改换其他分析步骤。

### 1.1 导入表硬门与等价路径

| 样本类型 | MUST 锚点（Evidence） | 说明 |
|----------|----------------------|------|
| 原生 PE/ELF/Mach-O（IAT 可读） | `E-imports` / `E-triage-imports`：导入分类摘要 | `rabin2 -i` / IDA imports / 等价 |
| DLL / SYS / 共享库 | **并列** `E-imports` + `E-exports`（`rabin2 -i` + `rabin2 -E`） | 导出表优先级等同导入表（对外入口） |
| .NET 托管（无传统 IAT） | **等价路径**：dnSpy/IL/元数据/程序集引用与敏感 API 摘要 → 仍写入 `E-imports` 或 `E-triage-imports` 语义槽 | **禁止** 因「没有 IAT」而空过硬门；dnSpy 查看 = 原生「查导入表」 |
| 导入表解析失败 / 为空 | 仍记失败输出为 Evidence | 不得静默跳过 |

**干净导入表警告（MUST 提醒）**：若导入表「过干净」（仅 kernel32/ntdll 等基础 DLL、几乎无业务 API），高度怀疑 `LoadLibrary` + `GetProcAddress` 动态加载 → 在 Evidence 注明嫌疑，并 **SHOULD** 转入 Dynamic 抓取内存 API；不得仅凭静态 IAT 宣称「无网络/无文件能力」。

### 1.2 脱壳与 IAT 处理（高风险分岔 · Issue #65）

```text
分支 A：无壳 / .NET 托管
  → 直接进入 §2 Static（.NET 走等价锚点）

分支 B：有壳 / 强混淆
  Step 1：尝试脱壳（自动脱壳机 / 手动找 OEP）— 须在授权与隔离环境
  Step 2：尝试修复 IAT
    工具：x86 → ImportREC（或等价）；x64 → Scylla（或等价）。禁止 64 位样本死磕 ImportREC。
    情况 B1：修复成功且可解析 → 记 E-imports（修复后）→ §2 Static
    情况 B2：ImportREC/Scylla 报错、修复后无法运行、或 IAT 全乱码（VMP/加密壳）
      → 【IAT 修复铁律】立即终止继续静态 IAT 修复
      → MUST 记录 E-iat-repair-fail（命令、工具、失败现象、决定转动态）
      → ⏩ 直接进入 §3 Dynamic：API 断点 / 硬件执行断点 / 内存搜索抓取导入
      → 这不算「跳过导入表」：导入表路径已尝试并记 Evidence
```

**IAT 修复铁律（MUST）**：优先尝试自动/半自动修复；一旦修复工具报错或修复后程序无法运行，**立即停止**在静态导入表上死磕，切换动态调试，用 API 断点（如 `bp CreateFile` / 关键网络 API）在运行时捕获导入函数。

## 2. Static（基础静态锚点 → 深挖）

| 工具 | 何时 |
|------|------|
| radare2 / rabin2 | 快速函数/导入/字符串（imports 已在 Triage MUST 完成或已记失败旁路） |
| IDA / Ghidra（MCP 或 headless） | 深挖、交叉引用、类型；survey 阶段复核 imports 分类 |
| jadx / dnSpy | Android / .NET |
| OLLVM 文档 | 控制流平坦化怀疑 |

```text
□ 确认 E-imports / E-triage 已含导入表或等价锚点 Evidence（缺失则先补，禁止后置）
□ 若 DLL/SYS：确认 E-exports 已记录
□ 敏感 API 分组：网络/WinHTTP、文件/CreateFile、进程/远程线程、注册表/服务
□ 硬编码域名/IP/URL 字符串；资源节是否藏 Payload
□ 定位关键函数（加密/校验/网络/授权）→ 地址/符号写入 Evidence
□ 一条路不通 → 换工具（IDA↔r2↔Ghidra）
```

**无 MCP 时**：可用导出反编译文本再分析（对照 P4nda0s reverse-skills / IDA-NO-MCP 思路），仍写 Evidence 路径。

## 3. Dynamic（交叉验证循环区）

核心理念：**静态提供线索 → 动态验证 → 验证卡壳 → 回静态重审**（无固定唯一顺序）。

```text
□ Frida / x64dbg / gdb / emulator：验证静态假设
□ 敏感 API 断点、单步跟踪栈/寄存器（白盒）
□ 行为监控：沙箱 / Procmon / RegShot（黑盒）
□ IAT 修复失败样本：硬件执行断点或内存搜索强行捕捉 API
□ 反调试/反 Frida → reverse-engineering/anti-analysis
□ Android：root 检测 / SSL pinning 绕过脚本按需生成，**须在授权设备**
□ 崩溃日志驱动下一轮 hook（自适应循环）
```

### 3.1 沙箱 / 动态无行为应急分支（MUST）

```text
无行为或立刻退出 / 无限休眠
  → 检查反调试 / 反虚拟机例程（CPUID、高精度计时、沙箱特征等）
  → 尝试硬件断点绕过、修补检测点、或换物理机/更高保真环境
  → 将「无行为 + 疑似 anti-VM」写入 Evidence，禁止写成「样本无害」而不加条件
```

## 4. Synthesis（IOC / 攻击链 / 报告）

```text
□ Finding：算法/校验逻辑/可利用点 / 行为结论
□ Path：callflow 或 solve 步骤挂 E-*
□ IOC：网络指纹 + 主机指纹（有则表；无则 n/a+原因）
□ 报告 docs-generator（malware/apt/null/vuln overlay 按任务选型）+ 可选图
□ 可选：YARA / Snort·Suricata 规则化沉淀
□ field-journal 脱敏
```

## 5. 六阶段实战映射（Issue #65 思维导图 → 本文件）

| 实战阶段 | 本文件章节 | 硬门 / 铁律 |
|----------|------------|-------------|
| 1 初步快速研判 | §0–§1 Triage | Hash、架构、文件类型、查壳；imports/等价锚点 |
| 2 脱壳与 IAT | §1.2 | IAT 修复铁律；失败 → E-iat-repair-fail → Dynamic |
| 3 基础静态锚点 | §2 Static | 仅 IAT 正常或等价锚点已记录后深挖 |
| 4 深度交叉验证 | §3 Dynamic | 静↔动循环；无行为应急分支 |
| 5 提取 IoC 与攻击链 | §4 Synthesis | IOC + Kill Chain / Path |
| 6 归档与规则化 | §4 + docs-generator / YARA | 结构化报告；规则可选 |

## 6. 与「堆 RE skill 插件」的差异

- 本包用 **阶段门闩 + tool-index**，不默认启用 Hex-Rays「unsafe 全自动执行」类插件  
- 动态插桩默认 **offline/lab** network_profile  
- IAT/导入表：**尝试 + 记录** 优先于「无限静态死磕」或「静默跳过」