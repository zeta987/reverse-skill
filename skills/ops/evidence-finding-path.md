# Evidence → Finding → Path 证据链

> 灵感来自 Z3r0 Evidence Plane，落地为 **Markdown 字段契约**。  
> reverse-skill 特色：与 `docs-generator` 报告模板、`field-journal` 脱敏回写、可复现命令绑定。

## 1. Evidence（不可变观察）

每条证据独立一段或表行：

```markdown
### E-{nnn}
- title:
- observed_at:
- source_type: command | screenshot | file | log | memory | network | manual
- source_ref: {path or command id}
- content_hash: {sha256 of artifact if file, else n/a}
- artifact_path: {relative path under case root when content_hash is recorded, else n/a}
- repro_command: |
    {exact command}
- raw_excerpt: |
    {脱敏摘录}
- linked_workitem: WI-{nnn} | n/a
- supersedes: E-{nnn} | none
```

**MUST**：Finding 引用的 Evidence 至少 1 条；`repro_command` 第三方可跑或标明离线限制。

**CLI helper**（写入 `work/<case>/evidence/E-*.md`）：

```powershell
powershell -File skills/scripts/append-evidence.ps1 -CaseRoot work/<case> `
  -Id E-001 -Title "..." -ReproCommand "..." -Severity info -Status observed
```

When the evidence is a case-local file, pass `-ArtifactPath` to record a SHA-256 fixity value and a relative artifact path. Review the complete case graph before handoff:

```bash
python3 skills/case-review/scripts/review_case.py work/<case> --verify-hashes --strict
```

The review is read-only and checks scope fields, Evidence records, work item and timeline references, structured Findings, Paths, and artifact hash matches.

## 2. Finding（安全/逆向结论）

```markdown
### F-{nnn}
- title:
- severity: critical | high | medium | low | info | n/a_re
- category: vuln | misconfig | design | reverse_algo | bypass | other
- status: candidate | validated | false_positive | accepted_risk
- evidence_ids: [E-001, E-002]
- location: {file:line | addr | url | class.method}
- impact:
- confidence: high | medium | low
- repro_steps:
  1.
  2.
- remediation: {or n/a for pure RE}
- optional_attack: {ATT&CK ID or empty}
```

**MUST**：`evidence_ids` 非空；`status=validated` 时 confidence 不得为 low（除非标注 residual risk）。

## 3. Path（攻击路径 / 调用路径 / 解题路径）

统一叫 **Path**，按任务类型解释：

| 任务 | Path 含义 |
|------|-----------|
| 渗透 / 攻击链 | 攻击路径步骤 |
| 逆向 | 关键调用/数据流步骤 |
| CTF | 解题步骤 |

```markdown
### P-{nnn}
- title:
- path_type: attack | callflow | solve
- start:
- goal:
- steps:
  1. action: — evidence: E-xxx — finding: F-xxx | none
  2. action: — evidence: E-xxx — finding: F-yyy | none
- residual_risks:
```

**MUST**：每步可关联 Evidence；攻击路径终点 Finding 若声明「已拿权限/数据」必须有 validated 证据。

## 4. 报告中的位置

`docs-generator` 安全报告 **MUST** 含：

1. Scope 摘要（链到 case `scope.md`）  
2. Evidence 表或章节  
3. Findings 列表（含 evidence_ids）  
4. 至少 1 条 Path（攻击/调用/解题）  
5. Timeline 摘要（可选全文链到 `timeline.md`）

详见 `docs-generator/references/security-report-templates.md` 中 **Evidence Chain** 节。

## 5. field-journal 挂钩

回写 journal 时 **SHOULD** 摘录：

- 3 条内关键 Evidence id + 命令  
- 1 条核心 Finding  
- 可复用 Path 模式一句话  

完整敏感内容只在用户项目报告中；journal **MUST** 脱敏（`anonymization.md`）。

## 5.1 外部平台产物回灌

本包之外的分析/渗透平台产出的结论**不直接**变成 Finding；先落成 Evidence，再按第 2 节绑定：

| 来源 | 取什么 | 写成 | 细则 |
|------|--------|------|------|
| ARTEX（自主渗透平台） | `findings`、`findings/{id}/lineage`、`findings/export?format=md-single`、finding traffic body、task archive（含 `sha256`） | finding → `F-nnn`；lineage → `P-nnn`（attack）；traffic body / 导出文件 → `E-nnn`（`source_type: network` / `file`，`-ArtifactPath` 记 hash） | `pentest-tools/references/artex-escalation.md` §4 |
| rea（reverse-engineer-anything MCP，rea-agents 6.3.0） | `export_evidence_bundle` 写出的 bundle JSON（`records[]` 每条带 `evidence_id`、`subject.digest.sha256`、`operation`、`confidence`、`limitations[]`） | 整份 bundle → `E-nnn`（`source_type: file`，`-ArtifactPath` 记 bundle 的 sha256）；被 Finding 引用的单条记录各自 → `E-nnn`，`evidence_id` + `subject.digest.sha256` 写进 notes | 本文 §5.2 |

规则：外部平台的一条结论只算**一份**证据；`status=validated` 仍需第二份独立证据（本包工具复现为佳）。回灌时不得把平台的 token、`.env`、密钥写进 `work/`。

## 5.2 rea Evidence bundle 回灌

rea 的每个分析工具都返回一条 Evidence 记录（`structuredContent.evidence_id`，形如 `ev_<64 hex>`），同一连接的记录保存在会话账本里，`close_binary` 会清空账本，所以**先导出再关闭**。

> **6.2.0 起的结果形状**（本包 pin 6.3.0 已实测）：分析工具的 `structuredContent` **就是**那条 Evidence 记录本身，顶层字段 `evidence_id / subject / provider / analysis_profile / predicate_type / operation / parameters / raw_result / normalized_result / confidence / authority / environment / limitations / locations / evidence_links`，不再有 6.1.0 的 `result` 外层——6.1.0 文档里写 `result.*` 的路径一律改读 `normalized_result.*`（例如 `normalized_result.statistics`、`normalized_result.semantic_graph`）。`export_evidence_bundle` 等非分析工具仍回 `result: {...}`。`analyze_javascript_application` / `trace_application_feature` 的语意图新增 `semantic_graph.evidence_contexts[]`（每项 `context_id`、`evidence_ids[]`、`authority`、`state`、`confidence`、`artifact`、`extractor`、`coverage`、`limitations[]`），节点与关系改以 `evidence.context_id` + `evidence.location`（`source-range`：文件、起止行列）指回上下文；把单条节点落 Evidence 时 `-Location` 直接用这个 source-range，`-Notes` 带上 `context_id` 对应的 `authority/state/confidence`。`statistics.truncated_scopes` 已移除。

1. 让 rea 把 bundle 写进 case 目录。路径必须在 CaseRoot 内，`append-evidence.ps1 -ArtifactPath` 拒绝外部路径：

   ```json
   {"name": "export_evidence_bundle", "arguments": {"path": "<abs>/work/<case>/evidence/rea/<stamp>-bundle.json"}}
   ```

   返回 `result: {path, bytes, records, unknowns}`；已存在的文件需要 `overwrite: true`。
2. bundle 顶层字段：`artifacts[]`（`digest.sha256` / `format` / `architecture`）、`providers[]`、`environments[]`、`scenarios[]`、`captures[]`、`unknowns[]`、`records[]`。每条 record：`evidence_id`、`subject{name, digest.sha256, format, local_path}`、`provider{id, name, version}`、`operation`、`predicate_type`、`confidence`（observed / derived / inferred）、`authority`、`limitations[]`、`locations[]`、`evidence_links[]`、`normalized_result`。
3. 整份 bundle 落一条 Evidence（`content_hash` 由脚本按文件算出，就是 bundle 的 sha256）：

   ```powershell
   powershell -File skills/scripts/append-evidence.ps1 -CaseRoot work/<case> `
     -Id E-0xx -Title "rea bundle: <目标>" -SourceType file `
     -ArtifactPath evidence/rea/<stamp>-bundle.json `
     -ReproCommand "rea MCP export_evidence_bundle path=<abs>/work/<case>/evidence/rea/<stamp>-bundle.json (rea-agents 6.3.0)" `
     -Notes "records=<n> unknowns=<m> tools_sha256=<binary_session.server_identity.catalog 的 tools_sha256>"
   ```

4. 要被 Finding 引用的单条记录各自落一条 Evidence：`-Title` 写 `operation` 与目标，`-Location` 写 `subject.name` 或 `locations[]`，`-Notes` 写 `evidence_id=… subject.sha256=… predicate_type=… confidence=… authority=…`，`-RawExcerptFile` 放 `normalized_result` 的脱敏摘录；`confidence: observed` → `-Status observed`，`derived` / `inferred` → `-Status candidate`。`limitations[]` 与 `unknowns[]` 原文保留进 notes。
5. 规则同 §5.1：一条 rea 记录只算一份证据，`validated` 仍需第二份独立 Evidence；`subject.local_path` 是本机绝对路径，回写 journal 前脱敏；bundle 不含 token，但 `capture_browser_scenario` 的 `storage` / `secrets` 选择项可能让 `normalized_result` 带上会话数据，导出前确认。

## 6. 与 Z3r0 的差异（特色）

| Z3r0 | reverse-skill |
|------|----------------|
| PG 不可变行 + API | Markdown 文件 + hash 字段 |
| UI 审阅队列 | 报告 + next-step 菜单 + journal |
| ATT&CK 深度绑定 | 可选标签，不强制 UI |


## Validated sufficiency (Issue #77 / R4*)

Global bind rule remains: every Finding references **>=1** Evidence.

Promotion to status=validated is stricter (decision cookbook):

| status | Evidence bar |
|--------|----------------|
| preliminary / candidate | >=1 (unchanged) |
| **validated** | **SHOULD >=2 independent** Evidence (best: 1 static + 1 dynamic). A single Evidence item alone MUST NOT silently promote to validated — keep candidate/preliminary, or record residual_risk + human confirm. |
| blocked promotion | record Evidence E-insufficient-evidence |

Full recipes: [nalysis-decision-framework.md](analysis-decision-framework.md) (R4*, R1, R41, R44).
