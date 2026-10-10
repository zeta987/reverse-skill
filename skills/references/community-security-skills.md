# 社区安全 Skill 生态对照（2026-07）

> 来源检索日期：**2026-07-17**  
> 目的：让 reverse-skill **知道外面有什么**，按需借鉴，**不**把外部巨型库整仓并入本包。  
> 本包身份：路由 + 工具自举 + 证据/scope 契约 + field-journal（见 `ops/IDENTITY.md`）。

## 1. 外部高价值仓库（可学习，勿盲装）

| 仓库 | 规模/定位 | 对本包价值 | 风险 |
|------|-----------|------------|------|
| [trailofbits/skills](https://github.com/trailofbits/skills) | ToB 安全研究 Claude 插件市场 | 审计/漏洞分析/RE 插件质量标杆 | 需按 ToB 市场安装；勿默认信任非 curated 副本 |
| [trailofbits/skills-curated](https://github.com/trailofbits/skills-curated) | 已审核插件列表 | 优先于任意社区 skill | 同上 |
| [Orizon-eu/claude-code-pentest](https://github.com/Orizon-eu/claude-code-pentest) | 6 个 pentest 生命周期 skill + 纯 Python 脚本 | 侦察→利用→报告流水线可对标我们 `attack-chain`+`pentest-tools` | 授权边界要自检；脚本需沙箱 |
| [trilwu/secskills](https://github.com/trilwu/secskills) | 16 skills + 6 专家 subagent | 多角色分工可对标 `ops/role-map.md` | 插件形态，与本包 monorepo 不同 |
| [Masriyan/Claude-Code-CyberSecurity-Skill](https://github.com/Masriyan/Claude-Code-CyberSecurity-Skill) | ~15–19 领域 skill（含 RE/OT/CSOC） | 领域覆盖 checklist | 深度不如本包单域 skill |
| [mukul975/Anthropic-Cybersecurity-Skills](https://github.com/mukul975/Anthropic-Cybersecurity-Skills) | **800+** skill · ATT&CK/NIST 映射 | **框架映射**与领域目录可参考，不宜整库依赖 | 体量过大、维护与投毒面巨大 |
| [Eyadkelleh/awesome-skills-security](https://github.com/Eyadkelleh/awesome-claude-skills-security) | SecLists 打包为 agent skills | 字典/payload 入口 | 与 seclists bootstrap 重叠 |
| [securityfortech/awesome-security-skills](https://github.com/securityfortech/awesome-security-skills) | 安全 skill 精选列表 | 发现新 skill 的索引 | 列表型，需逐个审计 |
| [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) | 1000+ 跨厂商 skill 索引 | 发现官方/社区 skill | 非安全专用 |
| [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) | PR 安全审查 GitHub Action | 可对标我们 docs/报告侧「变更审计」场景 | CI 产品，不是 RE 路由 |
| [agentskills.io](https://agentskills.io) | Agent Skills 开放标准 | frontmatter/目录约定对齐 | 标准本身无攻防内容 |

### 1.1 第二轮检索增补（2026-07-17 再搜）

| 仓库 / 资源 | 定位 | 本包落点 |
|-------------|------|----------|
| [trailofbits/skills](https://github.com/trailofbits/skills) 插件：`audit-context-building` `differential-review` `semgrep-rule-creator` `sharp-edges` `dwarf-expert` `burpsuite-project-parser` | 审计上下文、差分安全审查、危险 API、DWARF、Burp 工程解析 | 对照 `ida-reverse`/`docs-generator`/审计工作流；**不**整库并入 |
| [HexRaysSA/ida-claude-code-plugins](https://github.com/HexRaysSA/ida-claude-code-plugins) | 官方 IDA Claude 插件（含 domain 自动化，标注 unsafe） | `ida-reverse` MCP 路径对照；unsafe 插件默认不启用 |
| [P4nda0s/reverse-skills](https://github.com/P4nda0s/reverse-skills) | IDA-NO-MCP：导出反编译后再分析；rev-frida/dex-dump/u3d | 与「MCP 不可用时的离线导出」互补 |
| [2389-research/binary-re](https://github.com/2389-research/binary-re) | triage→static(r2/Ghidra)→dynamic(QEMU/GDB/Frida)→synthesis | `reverse-engineering` 阶段门闩见 `re-agent-workflow.md` |
| [incogbyte/android-reverse-engineering-claude-skill](https://github.com/incogbyte/android-reverse-engineering-claude-skill) | APK 解包、端点提取、自适应 Frida 绕过 | 对照 `apk-reverse`；动态脚本需 scope |
| [OwenPawl/cerberus-re-skill](https://github.com/OwenPawl/cerberus-re-skill) | Apple 向 Ghidra+LLDB+Frida 三循环 | 可参考 macOS/iOS 动态环 |
| [ljagiello/ctf-skills](https://github.com/ljagiello/ctf-skills) | CTF reverse/pwn；工具按需装 | 对照 CTF-Sandbox + `pwn-chain` |
| [shuvonsec/claude-bug-bounty](https://github.com/shuvonsec/claude-bug-bounty) | /recon→/hunt→/validate→/report | 对照 `recon-pipeline.md` + scope 门 |
| [PayloadsAllTheThings](https://github.com/swisskyrepo/PayloadsAllTheThings) | Web payload + Prompt Injection 章节 | `pentest-tools/payloads` 优先；LLM 见 `llm-security` |
| [HackTricks](https://hacktricks.wiki/) | 渗透方法论 + **AI/MCP 滥用** | 见 skill-supply-chain MCP 节 |
| [appsecsanta AI pentesting agents 2026](https://appsecsanta.com/research/ai-pentesting-agents-2026) | 39+ 开源 AI 渗透 agent 架构分类 | 多 agent ≠ 必须；我们用 role-map |
| Snyk 评测「更多 skill ≠ 更好」 | 技能堆叠可能降低审计质量 | 强化「深 skill + 路由」策略 |

### 1.2 本机已部署的外部平台（2026-10-09 补）

| 仓库 / 资源 | 定位 | 本包落点 | 风险 / 边界 |
|-------------|------|----------|-------------|
| [mhtsec/ARTEX](https://github.com/mhtsec/ARTEX)（本机 fork，v0.3.15；原 `Autumn-27/ARTEX` 已删除） | 自主渗透**平台**：Go + Next.js + PostgreSQL，双图（资产图 / 探索图）、planner/worker 多 agent、MITM 流量留痕、拦截审批、漏洞复测、IM 推送、ScopeSentry 同步；REST + JWT，**无 MCP server**（`mcphttp/` 是 client） | 不作 MCP 后端（与 pentestswarm 编排器角色重叠，且需另写 REST→MCP bridge）；作为 `pentest-tools` / `attack-chain` / `api-security` 的**升级路径**，`scripts/artex/start-artex.ps1` 仅 loopback 启动，产物回灌 Evidence 链（`pentest-tools/references/artex-escalation.md`） | AGPL-3.0 + 作者附加「禁止实测」条款（fork `CLAUDE.md` 改为仅授权目标）；Docker Hub 镜像与 Releases 已失效，只能本机构建 `artex:local`；`update.sh` / 页面更新写死已删 repo，禁用 |
| [morluto/rea](https://github.com/morluto/rea)（rea-agents 6.3.0，接入日期 2026-10-09） | 单一 MCP server + CLI（139 个 MCP 工具、6 个 prompt）：JS/Electron 应用图与功能追踪、托管 PE/CLI 元数据、ZIP/APK/IPA/MSIX/DMG 清单图、被动 CDP 网页检查与受控浏览器场景、HAR/mitmproxy 存档、EVM、原生二进制（Hopper/Ghidra/IDA provider），结果带 observed / inferred / unknown 的 Evidence 记录 | 已接入为 MCP 后端 `rea`（manifest `npm-mcp`，pinned `rea-agents@6.3.0`；项目级手写注册 `.mcp.json` / `.codex/config.toml` / `.agents/mcp_config.json` / dsh preset，四客户端一致；Claude Code 与 Codex 已各走通 offline-sample 流程两次：自写 JS 样本（`work/rea-flow-test`）与真实 .NET 程序集 Microsoft.PowerShell.MarkdownRender.dll（`work/rea-dotnet-test`），strict case-review 均通过）；路由自 `js-reverse` / `dotnet-reverse` / `macos-reverse` / `apk-reverse` / `browser-extension-reverse` 的 ACTION REQUIRED「rea 可用」段；Evidence bundle 按 `ops/evidence-finding-path.md` §5.2 回灌 | 刻意无 scope/permission 门（上游 PR #555），授权门留在本包；`rea setup` 会写用户级客户端配置，不执行；Windows 上 Hopper / 进程捕获 / 固件提取 / Android JADX `inspect_*` / macOS 原生工具不可用，Ghidra provider 需 12.1.x（本机 12.0.2 不替换），IDA provider 与现有 ida-pro-mcp 同后端不重复登记（`docs/mcp/host-deviations.md`） |

## 2. 安全标准与威胁（2025–2026）

| 来源 | 要点 | 本包落点 |
|------|------|----------|
| [OWASP Agentic Skills Top 10](https://owasp.org/www-project-agentic-skills-top-10/) | 恶意 skill、供应链、权限滥用、记忆投毒等 | `ops/skill-supply-chain.md` |
| [Anthropic Agent Skills 工程文](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) | 只装可信源；审脚本与依赖 | 同上 + bootstrap 禁止猜路径 |
| ClawHavoc 等投毒活动（AST10 记载） | 注册表批量恶意 skill | 禁止从未知 registry 一键安装进本包 |

## 3. 本包已有 vs 外部「广」覆盖

| 领域 | reverse-skill | 外部常有、我们不整库并入的原因 |
|------|---------------|--------------------------------|
| APK/JS/IDA/r2/固件/pwn | **深** skill + 脚本 | 保持深度与 tool-index 绑定 |
| 渗透/攻击链/SRC | pentest-tools + attack-chain + src-hunter | Orizon 类可作方法论对照 |
| LLM/Agent 安全 | llm-security | AST10 增强 skill 自身安全 |
| 证据/scope/角色 | **ops/**（特色） | 多数 skill 包没有 case 契约 |
| 自主渗透平台（ARTEX 类） | 不并入、不作后端；升级路径 + 产物回灌 | 平台自带 agent 与审批门，与本包 scope 门并行会分裂证据来源；只在 scope granted 后由 agent 自行拉起 |
| OT/ICS / 纯 GRC / 欺诈 F3 | 无独立 skill | 路由未命中 → 提议新增或外链，不硬塞 |
| 800+ 微 skill | 不复制 | 用 MASTER 路由 + 域 skill 替代碎片化 |

## 4. 借鉴规则（MUST）

```text
1. 禁止 git submodule 拉整库 800+ skills 当运行时依赖
2. 借鉴时：提取「阶段/清单/命令模式」写入本包 references 或现有 skill
3. 外部脚本：先在隔离环境看依赖与网络行为，再考虑 bootstrap-manifest
4. 新场景：走 CONTRIBUTING 新增 skill，并更新 routing + RULES 关键词
5. 标注来源 URL + 检索日期（本文件格式）
6. 安装/合并前走 ops/skill-supply-chain.md 清单
7. 运行时只加载 MASTER-ROUTING 的 PRIMARY（+必要 secondary），避免技能堆叠过载
```

## 4.1 本包已沉淀的「借鉴产物」（非外库依赖）

| 产物 | 路径 |
|------|------|
| RE 四阶段 | `reverse-engineering/references/re-agent-workflow.md` |
| 授权侦察 | `pentest-tools/references/recon-pipeline.md` |
| 攻击链门闩 | `attack-chain/references/lifecycle-checklist.md` |
| Skill 供应链 | `ops/skill-supply-chain.md` |
| 领域覆盖 | `references/domain-coverage-map.md` |

## 5. 建议优先级（后续迭代）

| 优先级 | 动作 |
|--------|------|
| P0 已做 | ops 契约、MASTER 路由、skill 供应链安全文档 |
| P1 | 对照 Orizon/ToB 补 pentest 阶段检查单到 attack-chain references |
| P2 | 可选「外链 skill 白名单」配置，不进默认路径 |
