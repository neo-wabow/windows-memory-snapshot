# Windows Memory Snapshot

本工具只用於診斷 Windows、WSL2 與 Docker 的記憶體使用狀況。

所有資料只儲存在你的電腦，不會自動上傳，不會連線至公司伺服器，也不會修改任何系統、Docker 或 WSL 設定。

你可以直接檢視完整 PowerShell 原始碼，並隨時按 Ctrl+C 停止或刪除此工具。

這是透明、唯讀的診斷工具。它只留下觀測資料，不會判定你是否需要換電腦。

## 開始使用

需求：Windows 10/11、內建 Windows PowerShell 5.1 或 PowerShell 7。一般使用者權限即可；WSL 和 Docker 都是選用的。

1. 從 GitHub 下載整個目錄，先閱讀 `MemorySnapshot.ps1`。
2. 在 PowerShell 視窗切到這個目錄：

   ```powershell
   cd path\to\windows-memory-snapshot
   ```

3. 執行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemorySnapshot.ps1
   ```

   這個 `ExecutionPolicy Bypass` 只套用到新啟動的 PowerShell 程序，不改系統設定。若使用 PowerShell 7，可將 `powershell.exe` 換成 `pwsh.exe`。

視窗可以最小化，但需保持開啟。按 Ctrl+C 停止監看。工具不會設定開機啟動、排程工作或 Windows service。

只檢查一次可加 `-Once`。使用 `-OutputDirectory` 可指定本機輸出位置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemorySnapshot.ps1 -Once -OutputDirectory C:\MemorySnapshots
```

## 觸發規則

每 30 秒讀一次 Windows 可用實體記憶體。高於 15% 時只檢查，不寫完整快照。

| 狀態 | 條件 | 記錄 |
| --- | --- | --- |
| Warning | Available RAM ≤ 15% | 每次檢查將時間、可用 RAM%、可用 GB、Commit 寫入 `snapshots/warning-memory.csv` |
| Critical | Available RAM ≤ 10% **或** ≤ 4 GB | 完整快照 |
| Severe | Available RAM ≤ 5% | 額外完整快照 |
| Recovery | 曾進入 Warning/Critical，且 Available RAM ≥ 20% | 最後一份完整快照 |

Recovery 必須同時脫離 Critical 的百分比與 4 GB 門檻；RAM 較小的電腦可能要高於 20% 才會進入 Recovery。每次低記憶體事件中，各級完整快照最多一份；不同事件的同一級別快照也至少相隔 10 分鐘。若第一次檢查就低於 5%，會各留下一份 Critical 與 Severe 快照。Warning CSV 上限約 10 MB，超過時輪替為一份 `warning-memory.previous.csv`；輪替的舊檔會被覆寫。工具不會替你清理完整快照。

可複製 `config.example.json` 為 `config.json` 後調整門檻。設定檔與快照預設留在工具目錄，不會納入 Git。設定值必須是正數，且 Severe < Critical < Warning < Recovery ≤ 100。

## 快照內容

每個事件一個時間戳記目錄，例如：

```text
snapshots/
├── warning-memory.csv
└── 2026-09-24_19-42-13-123_critical/
    ├── summary.txt
    ├── windows-memory.csv
    ├── pagefile.csv
    ├── processes.csv
    ├── wsl.txt
    ├── docker-stats.csv
    ├── docker-containers.csv
    └── oom.txt
```

`summary.txt` 先列出 Windows RAM、Commit、pagefile、WSL、前五名 Windows process、Docker container 和 OOM 線索。CSV 保留 Windows 前 20 名 process 的 PID、working set、private memory；Docker CSV 只保留容器名稱、短 ID、記憶體、CPU、狀態、restart count 和 OOMKilled。WSL 的 `free -b` 數值會轉為 GB；Windows `vmmemWSL` 的 working set 另外列出。兩者是不同觀測角度，不能直接相加。

WSL 只查詢已在執行的 distribution，不會為了量測而啟動一個已停止的 distribution。Docker 未安裝、未啟動、或查詢失敗時，對應欄位標示 unavailable，Windows 快照仍可完成。外部指令逾時後會跳過該項；為遵守唯讀原則，工具不會終止任何程序，且同一個逾時指令尚未結束時不會再重複啟動。

OOM 為盡力取得的線索：嘗試讀取近 30 分鐘可存取的 Linux kernel OOM 訊息，只儲存 killed process 的 PID／名稱；另讀取容器的 `OOMKilled` 狀態。權限不足或來源不可用時顯示 `Unknown`。`No evidence found` 只表示可存取來源中未發現線索，不等於證明沒有 OOM。

## 資料與行為邊界

**不蒐集：**檔案內容、文件名稱、瀏覽器網址或歷史紀錄、剪貼簿、鍵盤輸入、終端歷史、原始碼、環境變數值、Docker secret、token／API key、網路封包、Docker log 內容。也不儲存 pagefile 路徑或 WSL distribution 名稱。

**不執行：**終止使用者程序、重啟 container／Docker／WSL、修改 `.wslconfig`、pagefile、Docker 設定、Registry 或 Windows service、上傳資料、連線至公司 server。程式內沒有 telemetry 或 upload 功能。

Docker CLI 一律指定 Windows 本機 named pipe，並清除子程序繼承的 Docker host／context 設定，因此不會依使用者的遠端 Docker context 連線。WSL CLI 只向本機已啟動的 distribution 查詢記憶體及可讀的 OOM 線索。工具本身不發出 HTTP／TCP 請求。

快照目錄可能包含程序與容器名稱，請在分享前自行檢查。分享完全由使用者手動進行。

## 測試

在 Windows PowerShell 執行內建測試，不需 Pester：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

測試涵蓋門檻、cooldown、Recovery、缺少 WSL／Docker、單項擷取失敗、外部命令 timeout 及靜態掃描。真實 Docker／WSL 的輸出、非 Administrator 權限和 Ctrl+C 仍需在目標 Windows 電腦做一次實機 smoke test；步驟見 `tests/Windows-Smoke-Test.md`。

GitHub Actions 也會在 Windows 執行上述測試，分別使用 Windows PowerShell 5.1 與 PowerShell 7，並執行一次真實的 Windows 記憶體檢查。

## 授權

MIT，見 `LICENSE`。
