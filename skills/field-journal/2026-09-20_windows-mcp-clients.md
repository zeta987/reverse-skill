# 2026-09-20 Windows MCP 客戶端與後端接入

## 範圍與執行链

使用者授權本機 Codex、dsh web MCP 配置與驗證；測試資料僅靜態開庫，未執行樣本。先讀已安裝 bridge／外掛原始碼，辨識 client、stdio bridge、應用後端與分析 API，再進行依賴固定、配置備份合併、MCP 初始化、後端呼叫及 UI 狀態核對。

## 已驗證模式

- IDA MCP 可使用 idalib 後端，兩者不是互斥選項；直接 IDAPython 成功不能代表 MCP 成功。
- GhydraMCP v2.2.0 bridge 從 8192 起发现本機實例，不解析誤附的 IDA 13337 URL；x64dbg backend 為 8888，URL 必須保留尾端 `/`。
- 原 x64dbg `uv --with mcp` 無版本固定，解析到不相容 2.x；持久 Python 環境固定 mcp 1.6.0、requests 2.32.3 後成功。
- GhydraMCP stdout 診斷使用獨立 wrapper 送到 stderr。其 rc.2 Java listener 原綁萬用位址；最小單類別修正限定 loopback，保留原 JAR 與其餘 entry，並實測地址與 MCP 反編譯。
- DSH 為每 server 一個 Cordis plugin entry；profile overlay 使用 insert，Agent preset 則使用原始 plugin list，不可混用。`disabled` 在 entry 層，MCP config 的未知 `enabled/perms/allowTools` 不產生預期效果。
- DSH 0.1.6-alpha.2 不按 cwd 載入 repo MCP；本案採 repo 內完整 Standard 衍生的 Agent preset，加四個 MCP，Web 只登記 roots 並移除原全域四項。會話須明確選用；相同 preset 共用 standing scope，並非每個 repo／session 各建一份 MCP。配置 roots 時保留既有 user root 的優先序，避免改變 Web 新建 preset 的位置。
- 此 repo 的四個 Codex MCP 應放在 `.codex/config.toml`，不放使用者全域設定。驗證必須比較 repo 內外清單，並讓 Codex 正常讀取專案設定；命令列注入四項設定不能證明專案範圍正確。
- DSH Web 插件清單是面板開啟時的快照；初次的「載入中」需重開面板才能反映後續完成狀態。
- 後端啟動須按 backend／port 序列化，核對真實 listener PID 與子程序關係；只看健康 API 可能誤報競爭啟動的 PID。

## 證據與驗證

兩個客戶端分別載入 IDA 42、Ghidra 40、x64dbg 34、math 22 個工具。IDA／Ghidra 靜態函式與反編譯、x64dbg 原始 HTTP 與 MCP 空會話狀態、math 加法均成功。Codex 測試沒有建立任務；DSH harness 未載入模型。175 筆路由與 smoke 通過；新增的惰性假後端測試驗證並行與早退行為。

DSH 移入 preset 後，正式檔完整 discovery 通過；抽取四個實際 MCP rows 經原生 AgentPresets.mount，selected scope 有 138 工具，sibling／root 為 0，math 呼叫成功且 sibling 呼叫被拒絕。Web 確認四項僅列在自訂 preset，Standard 與全域清單沒有這四項。這項測試未建立模型會話，也未重新啟動 Ghidra／x64dbg 後端。

完整 E-codex／E-dsh-core／E-dsh-ghidra／E-web-ui 證據保留在使用者的本機 case；本條目不保存私有配置、樣本內容、憑據或個人路径。呼叫路徑為 client → stdio bridge → loopback backend → 靜態分析結果。

## 交付與限制

新增 `docs/mcp/` 與 `skills/scripts/mcp/`，修正舊文件的命名、API 及 port 假設。MCP 初始化、後端 ready、真正工具呼叫、既有 UI 是否重載均分開回報。Ghidra 本機 patch 不是上游發行版，之後外掛更新須重新檢查。
