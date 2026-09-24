# Windows 實機驗收

在一般使用者的 Windows PowerShell 視窗執行。記錄 Windows 版本、PowerShell 版本與本次結果；不需要、也不要刻意把電腦記憶體用滿。

1. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`：所有 assertions 通過。
2. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemorySnapshot.ps1 -Once`：一般權限下完成一次檢查，沒有 Administrator 提示；正常 RAM 時沒有完整快照。
3. 在沒有 Docker CLI 的電腦、或暫時讓 Docker 不在 PATH 時執行測試與單次檢查：不崩潰。若只關閉 Docker Desktop，低 RAM 快照中的 Docker 顯示 unavailable。
4. 在未安裝 WSL 的電腦、或暫時讓 WSL 不在 PATH 時執行測試與單次檢查：不崩潰。若 WSL 已安裝但 distribution 沒有啟動，低 RAM 快照中顯示 `No running distribution`，且不啟動 distribution。
5. 執行正常監看，按 Ctrl+C：PowerShell 回到提示字元，沒有新背景監看程序。
6. 用 `-Once` 和測試檔驗證 timeout 及單項失敗；不可藉此重啟 Docker、WSL 或 container。
7. 用 `Get-NetTCPConnection` 或公司核准的網路監測方式觀察此腳本啟動的程序；Docker 查詢只能走本機 named pipe。此步是實機確認，靜態掃描只能證明程式沒有呼叫網路 API。
8. 檢查快照檔案只包含規格允許的欄位。將快照分享給他人前，再人工檢查程序及容器名稱。
