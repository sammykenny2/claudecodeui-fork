<#
.SYNOPSIS
    Setup Claude Code UI with ngrok tunnel for auto-start on Windows boot

.DESCRIPTION
    Configures Claude Code UI (Express server + ngrok tunnel) to start automatically
    when Windows boots. Creates a runner script and a Windows Startup shortcut.

    This is a user-level script that does NOT require administrator privileges.

    Requirements:
    - Node.js and npm must be installed
    - NGROK_AUTHTOKEN must be set in the project .env file
    - npm dependencies must be installed (npm install)

.PARAMETER Install
    Build the frontend, create runner script, and add Windows startup shortcut

.PARAMETER Remove
    Remove runner script and startup shortcut

.PARAMETER Verify
    Verify that the server and ngrok tunnel are running

.PARAMETER Force
    Force reconfiguration even if already setup

.PARAMETER NonInteractive
    No user prompts (for automation)

.EXAMPLE
    .\Setup-NgrokTunnel.ps1 -Install
    Build and configure auto-start

.EXAMPLE
    .\Setup-NgrokTunnel.ps1 -Verify
    Verify all services are running

.EXAMPLE
    .\Setup-NgrokTunnel.ps1 -Remove
    Remove auto-start configuration

.NOTES
    - Creates scripts in: $env:USERPROFILE\Scripts\
    - Creates startup shortcut in: Startup folder
    - Log file: $env:USERPROFILE\Scripts\claude-code-ui-ngrok.log
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Install,

    [Parameter(Mandatory=$false)]
    [switch]$Remove,

    [Parameter(Mandatory=$false)]
    [switch]$Verify,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

Write-Host "--- Claude Code UI + ngrok Tunnel 設置腳本 ---" -ForegroundColor Cyan

# 計算路徑
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $scriptPath
$repoRoot = Split-Path -Parent $scriptsDir
$envFile = Join-Path $repoRoot ".env"
$envExample = Join-Path $repoRoot ".env.example"

# 部署路徑
$userScriptsDir = Join-Path $env:USERPROFILE "Scripts"
$runnerScript = Join-Path $userScriptsDir "Start-ClaudeCodeUITunnel.ps1"
$logFile = Join-Path $userScriptsDir "claude-code-ui-ngrok.log"
$pidFile = Join-Path $userScriptsDir "claude-code-ui-ngrok.pids"
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupFolder "Start-ClaudeCodeUITunnel.lnk"

# 處理互斥操作
$operations = @($Install, $Remove, $Verify)
$operationCount = ($operations | Where-Object { $_ -eq $true }).Count

if ($operationCount -eq 0) {
    Write-Host "`n請指定操作：-Install, -Remove, 或 -Verify" -ForegroundColor Red
    Write-Host ""
    Write-Host "使用範例：" -ForegroundColor Cyan
    Write-Host "   .\Setup-NgrokTunnel.ps1 -Install" -ForegroundColor White
    Write-Host "   .\Setup-NgrokTunnel.ps1 -Verify" -ForegroundColor White
    Write-Host "   .\Setup-NgrokTunnel.ps1 -Remove" -ForegroundColor White
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}

if ($operationCount -gt 1) {
    Write-Host "`n警告：只能同時使用一個操作參數" -ForegroundColor Yellow
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}

# === 服務進程清理 ===
#
# server 和 ngrok 都是用 `Start-Process cmd.exe /c "npm run ..."` 起的：真正做事的是 cmd 底下的
# node，cmd 只是批次殼層。只殺 node（或像舊版 -Remove 那樣什麼都不殺）會留下 cmd 停在
# 「終止批次工作 (Y/N)?」等一個永遠等不到的答案（視窗是 hidden 的）。這種殭屍殼層不 listen 任何
# port，對只看 port 的清理邏輯完全隱形，卻會一直抓著專案目錄當工作目錄、抓著 .out/.err 的 handle
# 不放——結果就是專案資料夾無法改名、log 檔刪不掉，而 -Remove 還印「移除完成」。
# 所以清理一律要連殼層一起殺：優先用 runner 記下的 PID 殺整棵 tree，其次從 port 擁有者往上追到
# 批次殼層，最後掃出已經沒有子行程的孤兒 cmd（舊版 runner 沒寫 PID 檔，只能靠這關撿回來）。

# 殺掉整棵 process tree（含卡在批次提示、無法用 Stop-Process 正常收掉的父殼）
function Stop-ProcessTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return $false }
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $false }

    taskkill /PID $ProcessId /T /F 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    return -not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# 從 port 擁有者往上追，回傳這條鏈上最外層的批次殼層 PID。實際的鏈長這樣：
#
#   node.exe (server/index.js)          <- 真正 listen port 的
#     cmd.exe /d /s /c node ...         <- npm 起腳本用的殼（注意：這層 command line 沒有 npm）
#       node.exe (npm-cli.js run ...)
#         cmd.exe /c npm run server     <- 要殺的就是這層，卡在 Y/N 的也是它
#           powershell.exe (runner)     <- 停在這裡
#
# 規則：只往上吃 node.exe 和帶 /c 的批次 cmd.exe，碰到別的（powershell、explorer）就停。
# 互動式 cmd.exe 的 command line 沒有 /c，所以使用者自己開的終端機不會被追上去誤殺。
# 父行程的建立時間必須早於子行程，否則是 PID 被回收後撞名，不能認。
function Get-ServerShellPid {
    param([int]$ProcessId)

    $topMost = $ProcessId
    $current = $ProcessId

    for ($i = 0; $i -lt 8; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $proc -or -not $proc.ParentProcessId) { break }

        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $parent) { break }
        if ($parent.Name -notmatch '^(cmd|node)\.exe$') { break }
        if ($parent.Name -eq 'cmd.exe' -and $parent.CommandLine -notmatch '(?i)\s/c\b') { break }
        if ($parent.CreationDate -and $proc.CreationDate -and $parent.CreationDate -gt $proc.CreationDate) { break }

        $topMost = [int]$parent.ProcessId
        $current = $topMost
    }

    return $topMost
}

# 掃出卡在「終止批次工作 (Y/N)?」的孤兒殼層：跑著 npm 的 cmd.exe，底下卻只剩 conhost（node 已死）
function Get-OrphanNpmShell {
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'npm\s+run\s+(server|ngrok|tailscale)' })

    foreach ($shell in $shells) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($shell.ProcessId)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'conhost.exe' })
        if ($children.Count -eq 0) { $shell }
    }
}

# 刪除部署檔案。這些檔案可能還被沒清乾淨的進程開著（.out/.err 是 Start-Process 的重導向目標），
# 失敗必須講出來——原本這裡是 -ErrorAction SilentlyContinue，檔案還在卻一聲不吭。
function Remove-DeployFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        Write-Host "   - $Label 不存在，跳過" -ForegroundColor Gray
        return $true
    }

    try {
        Remove-Item $Path -Force -ErrorAction Stop
        Write-Host "   - 已刪除 $Label ✓" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "   - 刪除 $Label 失敗：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "     檔案仍被某個進程開著，通常是上一步沒清乾淨的殼層。" -ForegroundColor Yellow
        Write-Host "     可重跑一次 -Remove；要查出持有者請用 Sysinternals：" -ForegroundColor Yellow
        Write-Host "     handle64.exe -nobanner `"$Path`"" -ForegroundColor White
        return $false
    }
}

# === 驗證操作 ===
if ($Verify) {
    Write-Host "`n=== 開始驗證服務 ===" -ForegroundColor Cyan

    $allGood = $true

    # 檢查 node server 進程
    Write-Host "`n1. 檢查 Node.js server 進程..." -ForegroundColor Yellow
    $nodeProcs = Get-Process -Name "node" -ErrorAction SilentlyContinue
    if ($nodeProcs) {
        Write-Host "   - Node.js 進程運行中 (PID: $($nodeProcs.Id -join ', ')) ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 未找到 Node.js 進程" -ForegroundColor Red
        $allGood = $false
    }

    # 檢查 ngrok 進程
    Write-Host "`n2. 檢查 ngrok 進程..." -ForegroundColor Yellow
    $ngrokProcs = Get-Process -Name "ngrok" -ErrorAction SilentlyContinue
    if ($ngrokProcs) {
        Write-Host "   - ngrok 進程運行中 (PID: $($ngrokProcs.Id -join ', ')) ✓" -ForegroundColor Green
    } else {
        # ngrok SDK 透過 node 運行，不一定有獨立進程
        Write-Host "   - 未找到獨立 ngrok 進程（ngrok SDK 透過 Node.js 運行，這可能是正常的）" -ForegroundColor Gray
    }

    # 嘗試 HTTP 請求 localhost:3001/health
    Write-Host "`n3. 檢查 HTTP 服務 (localhost:3001)..." -ForegroundColor Yellow
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:3001/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            Write-Host "   - HTTP 服務正常 (status: $($response.StatusCode)) ✓" -ForegroundColor Green
        } else {
            Write-Host "   - HTTP 服務回應異常 (status: $($response.StatusCode))" -ForegroundColor Yellow
            $allGood = $false
        }
    } catch {
        Write-Host "   - HTTP 服務無法連線：$($_.Exception.Message)" -ForegroundColor Red
        $allGood = $false
    }

    # 檢查 ngrok tunnel 狀態（透過 ngrok API）
    Write-Host "`n4. 檢查 ngrok tunnel 狀態..." -ForegroundColor Yellow
    try {
        $tunnelResponse = Invoke-WebRequest -Uri "http://localhost:4040/api/tunnels" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $tunnelData = $tunnelResponse.Content | ConvertFrom-Json
        if ($tunnelData.tunnels.Count -gt 0) {
            foreach ($tunnel in $tunnelData.tunnels) {
                Write-Host "   - Tunnel: $($tunnel.public_url) -> $($tunnel.config.addr) ✓" -ForegroundColor Green
            }
        } else {
            Write-Host "   - 未找到活躍 tunnel" -ForegroundColor Yellow
            $allGood = $false
        }
    } catch {
        # ngrok SDK 可能不會啟動 localhost:4040 API
        Write-Host "   - 無法查詢 ngrok API（ngrok SDK 模式可能不提供 4040 API）" -ForegroundColor Gray
        Write-Host "   - 如果 HTTP 服務正常，tunnel 很可能也在運行" -ForegroundColor Gray
    }

    # 檢查 runner 腳本和啟動項
    Write-Host "`n5. 檢查啟動配置..." -ForegroundColor Yellow
    if (Test-Path $runnerScript) {
        Write-Host "   - Runner 腳本存在 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Runner 腳本不存在：$runnerScript" -ForegroundColor Red
        $allGood = $false
    }

    if (Test-Path $startupShortcut) {
        Write-Host "   - 啟動捷徑存在 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 啟動捷徑不存在：$startupShortcut" -ForegroundColor Red
        $allGood = $false
    }

    # 檢查 log 檔案
    Write-Host "`n6. 檢查 log 檔案..." -ForegroundColor Yellow
    if (Test-Path $logFile) {
        $logSize = (Get-Item $logFile).Length
        $logLastWrite = (Get-Item $logFile).LastWriteTime
        Write-Host "   - Log 檔案存在 ($([math]::Round($logSize/1024, 1)) KB, 最後更新: $logLastWrite)" -ForegroundColor Gray
        Write-Host "   - 最後幾行 log：" -ForegroundColor Gray
        Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "   - Log 檔案不存在（服務可能尚未啟動過）" -ForegroundColor Gray
    }

    # 總結
    Write-Host ""
    if ($allGood) {
        Write-Host "所有服務運行正常 ✓" -ForegroundColor Green
    } else {
        Write-Host "部分服務未運行，請檢查上方訊息" -ForegroundColor Yellow
    }

    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}

# === 移除操作 ===
if ($Remove) {
    Write-Host "`n=== 開始移除 Claude Code UI 自動啟動配置 ===" -ForegroundColor Cyan

    # 確認操作
    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "此操作將移除：" -ForegroundColor Yellow
        Write-Host "   - 本專案起的 server / ngrok 進程（含批次殼層）" -ForegroundColor White
        Write-Host "   - Runner 腳本 (Start-ClaudeCodeUITunnel.ps1)" -ForegroundColor White
        Write-Host "   - Windows 啟動項捷徑" -ForegroundColor White
        Write-Host "   - Log 檔案" -ForegroundColor White
        Write-Host ""
        $confirm = Read-Host "   確定要繼續嗎？(Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "   - 已取消操作" -ForegroundColor Yellow
            exit 0
        }
    }

    # 停止服務進程（連批次殼層一起殺，理由見上方「服務進程清理」）
    #
    # 原本這裡只印一行「不自動終止（可能有其他 Node 應用）」什麼都不做，於是 server 和 ngrok 兩個
    # 殼層都會活過 -Remove，繼續抓著專案目錄不放。改成只對「本專案起的」下手：認 PID 檔、認 port
    # 擁有者的殼層鏈，分不清歸屬的孤兒則列出來讓使用者自己確認，仍然不會亂殺別的 Node 應用。
    Write-Host "`n1. 正在停止服務進程..." -ForegroundColor Yellow

    # 讀取 PORT（server 監聽的 port，預設 3001）
    $port = "3001"
    if (Test-Path $envFile) {
        $portLine = Get-Content $envFile | Select-String '^PORT\s*='
        if ($portLine) {
            $port = ($portLine.Line -split '=', 2)[1].Trim()
        }
    }

    $killed = @()

    # 1-1. runner 記在 PID 檔裡的殼層（server 和 ngrok 各一行）：直接殺整棵 tree，最可靠
    if (Test-Path $pidFile) {
        foreach ($line in (Get-Content $pidFile -ErrorAction SilentlyContinue)) {
            $recordedPid = 0
            if (-not [int]::TryParse($line.Trim(), [ref]$recordedPid)) { continue }

            $proc = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
            if (-not $proc) { continue }

            Write-Host "   - 記錄在案的 $($proc.ProcessName) (PID: $recordedPid)，連同子行程一併停止" -ForegroundColor Gray
            if (Stop-ProcessTree -ProcessId $recordedPid) {
                $killed += $recordedPid
                Write-Host "     已停止 ✓" -ForegroundColor Green
            } else {
                Write-Host "     停止失敗，請手動執行：taskkill /PID $recordedPid /T /F" -ForegroundColor Yellow
            }
        }
    }

    # 1-2. 仍佔用 port 的進程：往上追到批次殼層再殺整棵，避免只殺掉 node 卻留下卡住的 cmd
    $portConn = Get-NetTCPConnection -LocalPort ([int]$port) -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Listen' } |
        Select-Object -First 1
    if ($portConn) {
        $ownerPid = [int]$portConn.OwningProcess
        $shellPid = Get-ServerShellPid -ProcessId $ownerPid
        $proc = Get-Process -Id $shellPid -ErrorAction SilentlyContinue

        if ($proc -and ($shellPid -notin $killed)) {
            if ($shellPid -ne $ownerPid) {
                Write-Host "   - port $port 由 PID $ownerPid 佔用，其批次殼層是 $($proc.ProcessName) (PID: $shellPid)" -ForegroundColor Gray
            } else {
                Write-Host "   - 發現 $($proc.ProcessName) 進程 (PID: $shellPid) 佔用 port $port" -ForegroundColor Gray
            }
            if (Stop-ProcessTree -ProcessId $shellPid) {
                $killed += $shellPid
                Write-Host "     已停止 ✓" -ForegroundColor Green
            } else {
                Write-Host "     停止失敗，請手動執行：taskkill /PID $shellPid /T /F" -ForegroundColor Yellow
            }
        }
    } elseif ($killed.Count -eq 0) {
        Write-Host "   - 未找到 port $port 上的服務" -ForegroundColor Gray
    }

    # 1-3. 孤兒殼層：node 已結束、cmd 還卡在「終止批次工作 (Y/N)?」的殘留
    # 光看 command line 分不出是哪個 repo 起的，所以列出來讓使用者確認，不預設代殺。
    $orphans = @(Get-OrphanNpmShell | Where-Object { [int]$_.ProcessId -notin $killed })
    if ($orphans.Count -gt 0) {
        Write-Host ""
        Write-Host "   - 偵測到卡在批次提示的殘留殼層（node 已結束，cmd 還在等 Y/N）：" -ForegroundColor Yellow
        $orphans | ForEach-Object {
            Write-Host "     PID $($_.ProcessId)：$($_.CommandLine)" -ForegroundColor White
        }
        Write-Host "     它們會抓著專案目錄和 log 檔不放，導致目錄無法改名、log 刪不掉。" -ForegroundColor Gray

        $killOrphans = [bool]$Force
        if (-not $killOrphans -and -not $NonInteractive) {
            $killOrphans = ((Read-Host "     要一併停止嗎？(Y/N)") -match '^[Yy]')
        }

        if ($killOrphans) {
            foreach ($orphan in $orphans) {
                $orphanPid = [int]$orphan.ProcessId
                if (Stop-ProcessTree -ProcessId $orphanPid) {
                    $killed += $orphanPid
                    Write-Host "     已停止 PID $orphanPid ✓" -ForegroundColor Green
                } else {
                    Write-Host "     PID $orphanPid 停止失敗，請手動執行：taskkill /PID $orphanPid /T /F" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "     已略過（確認是本專案的話，執行 taskkill /PID <PID> /T /F，或改用 -Force）" -ForegroundColor Gray
        }
    }

    # 刪除腳本
    Write-Host "`n2. 正在刪除腳本..." -ForegroundColor Yellow

    $removeOk = $true
    $removeOk = (Remove-DeployFile -Path $runnerScript -Label "Start-ClaudeCodeUITunnel.ps1") -and $removeOk
    $removeOk = (Remove-DeployFile -Path $logFile -Label "log 檔案") -and $removeOk
    $removeOk = (Remove-DeployFile -Path "$logFile.server.out" -Label "server stdout log") -and $removeOk
    $removeOk = (Remove-DeployFile -Path "$logFile.server.err" -Label "server stderr log") -and $removeOk
    $removeOk = (Remove-DeployFile -Path "$logFile.ngrok.out" -Label "ngrok stdout log") -and $removeOk
    $removeOk = (Remove-DeployFile -Path "$logFile.ngrok.err" -Label "ngrok stderr log") -and $removeOk
    $removeOk = (Remove-DeployFile -Path $pidFile -Label "PID 記錄檔") -and $removeOk

    # 刪除啟動項
    Write-Host "`n3. 正在刪除 Windows 啟動項..." -ForegroundColor Yellow

    if (Test-Path $startupShortcut) {
        Remove-Item $startupShortcut -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除啟動捷徑 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 啟動捷徑不存在，跳過" -ForegroundColor Gray
    }

    Write-Host ""
    if ($removeOk) {
        Write-Host "移除完成！" -ForegroundColor Green
    } else {
        Write-Host "移除未完全成功：有檔案刪不掉，請看上方訊息。" -ForegroundColor Yellow
    }
    Write-Host ""

    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}

# === 安裝操作 ===
if ($Install) {
    Write-Host "`n=== 開始設置 Claude Code UI 自動啟動 ===" -ForegroundColor Cyan

    # 步驟 1: 檢查前置條件
    Write-Host "`n1. 正在檢查前置條件..." -ForegroundColor Yellow

    # 檢查 Node.js
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand) {
        Write-Host "   - 未找到 Node.js" -ForegroundColor Red
        Write-Host "   - 請先安裝 Node.js：https://nodejs.org/" -ForegroundColor Yellow
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 1
    }
    $nodeVersion = node --version
    Write-Host "   - Node.js $nodeVersion ✓" -ForegroundColor Green

    # 檢查 npm
    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCommand) {
        Write-Host "   - 未找到 npm" -ForegroundColor Red
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 1
    }
    Write-Host "   - npm 已安裝 ✓" -ForegroundColor Green

    # 檢查 .env 檔案
    if (-not (Test-Path $envFile)) {
        if (Test-Path $envExample) {
            Write-Host "   - 從 .env.example 創建 .env" -ForegroundColor Gray
            Copy-Item $envExample $envFile
        } else {
            Write-Host "   - 未找到 .env 或 .env.example" -ForegroundColor Red
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 1
        }
    }

    # 讀取 NGROK_AUTHTOKEN
    $envContent = Get-Content $envFile
    $authtokenLine = $envContent | Select-String '^NGROK_AUTHTOKEN\s*='
    if (-not $authtokenLine) {
        Write-Host "   - .env 中未設定 NGROK_AUTHTOKEN" -ForegroundColor Red
        Write-Host "   - 請在 .env 中設定你的 ngrok authtoken" -ForegroundColor Yellow
        Write-Host "   - 取得 authtoken：https://dashboard.ngrok.com/signup" -ForegroundColor Yellow
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 1
    }

    $authtoken = ($authtokenLine.Line -split '=', 2)[1].Trim()
    if ($authtoken -eq 'your_authtoken_here' -or [string]::IsNullOrWhiteSpace($authtoken)) {
        Write-Host "   - NGROK_AUTHTOKEN 尚未設定（仍為預設值）" -ForegroundColor Red
        Write-Host "   - 請在 .env 中填入你的 ngrok authtoken" -ForegroundColor Yellow
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 1
    }
    Write-Host "   - NGROK_AUTHTOKEN 已設定 ✓" -ForegroundColor Green

    # 讀取 NGROK_DOMAIN（可選）
    $domainLine = $envContent | Select-String '^NGROK_DOMAIN\s*='
    if ($domainLine) {
        $ngrokDomain = ($domainLine.Line -split '=', 2)[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($ngrokDomain)) {
            Write-Host "   - NGROK_DOMAIN: $ngrokDomain ✓" -ForegroundColor Green
        }
    }

    # 讀取 PORT
    $portLine = $envContent | Select-String '^PORT\s*='
    $port = "3001"
    if ($portLine) {
        $port = ($portLine.Line -split '=', 2)[1].Trim()
    }
    Write-Host "   - 端口配置：$port" -ForegroundColor Gray

    # 檢查是否已安裝且不強制
    if ((Test-Path $runnerScript) -and (Test-Path $startupShortcut) -and -not $Force) {
        Write-Host ""
        Write-Host "已檢測到現有安裝配置 ✓" -ForegroundColor Green
        Write-Host "   - Runner 腳本：$runnerScript" -ForegroundColor Gray
        Write-Host "   - 啟動捷徑：$startupShortcut" -ForegroundColor Gray
        Write-Host ""
        Write-Host "如需重新配置，請使用 -Force 參數：" -ForegroundColor Yellow
        Write-Host "   .\Setup-NgrokTunnel.ps1 -Install -Force" -ForegroundColor White
        Write-Host ""
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 0
    }

    # 步驟 2: 建置前端
    Write-Host "`n2. 正在建置前端 (npm run build)..." -ForegroundColor Yellow
    Push-Location $repoRoot
    try {
        $buildOutput = npm run build 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   - 前端建置成功 ✓" -ForegroundColor Green
        } else {
            Write-Host "   - 前端建置失敗" -ForegroundColor Red
            $buildOutput | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 1
        }
    } finally {
        Pop-Location
    }

    # 步驟 3: 創建 Runner 腳本
    Write-Host "`n3. 正在創建 Runner 腳本..." -ForegroundColor Yellow

    if (-not (Test-Path $userScriptsDir)) {
        New-Item -ItemType Directory -Path $userScriptsDir -Force | Out-Null
        Write-Host "   - 已創建目錄：$userScriptsDir" -ForegroundColor Gray
    }

    $runnerContent = @"
# Start-ClaudeCodeUITunnel.ps1
# Auto-generated by Setup-NgrokTunnel.ps1
# Starts Claude Code UI server and ngrok tunnel

`$repoRoot = "$($repoRoot -replace '\\', '\\')"
`$logFile = "$($logFile -replace '\\', '\\')"
`$pidFile = "$($pidFile -replace '\\', '\\')"

# Ensure we're in the project directory
Set-Location `$repoRoot

# Timestamp
`$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path `$logFile -Value ""
Add-Content -Path `$logFile -Value "=== [`$timestamp] Starting Claude Code UI ==="

# Start Express server in background
Add-Content -Path `$logFile -Value "Starting server (npm run server)..."
`$serverJob = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm run server" ``
    -WorkingDirectory `$repoRoot ``
    -WindowStyle Hidden ``
    -RedirectStandardOutput "`$logFile.server.out" ``
    -RedirectStandardError "`$logFile.server.err" ``
    -PassThru

Add-Content -Path `$logFile -Value "Server started (PID: `$(`$serverJob.Id))"

# `$serverJob 是 cmd.exe 這層批次殼層，不是 node。把它記下來，-Remove 才能 taskkill /T 整棵殺掉；
# 少了這個，node 被殺後 cmd 會卡在「終止批次工作 (Y/N)?」變成抓著 repo 目錄不放的殭屍。
Set-Content -Path `$pidFile -Value `$serverJob.Id -Encoding ASCII

# Wait a moment for server to initialize
Start-Sleep -Seconds 5

# Start ngrok tunnel in background
Add-Content -Path `$logFile -Value "Starting ngrok tunnel (npm run ngrok)..."
`$ngrokJob = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm run ngrok" ``
    -WorkingDirectory `$repoRoot ``
    -WindowStyle Hidden ``
    -RedirectStandardOutput "`$logFile.ngrok.out" ``
    -RedirectStandardError "`$logFile.ngrok.err" ``
    -PassThru

Add-Content -Path `$logFile -Value "ngrok started (PID: `$(`$ngrokJob.Id))"

# ngrok 殼層追加成第二行；-Remove 會逐行讀，兩個殼層都要清掉
Add-Content -Path `$pidFile -Value `$ngrokJob.Id -Encoding ASCII

Add-Content -Path `$logFile -Value "=== Startup complete ==="
"@

    Set-Content -Path $runnerScript -Value $runnerContent -Encoding UTF8
    Write-Host "   - 已創建 Start-ClaudeCodeUITunnel.ps1 ✓" -ForegroundColor Green
    Write-Host "   - 位置：$runnerScript" -ForegroundColor Gray

    # 步驟 4: 創建 Windows 啟動項
    Write-Host "`n4. 正在配置 Windows 啟動項..." -ForegroundColor Yellow

    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($startupShortcut)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerScript`""
    $Shortcut.WorkingDirectory = $repoRoot
    $Shortcut.WindowStyle = 7  # 最小化
    $Shortcut.Description = "Claude Code UI + ngrok Tunnel 自動啟動"
    $Shortcut.Save()

    Write-Host "   - 已創建啟動捷徑 ✓" -ForegroundColor Green
    Write-Host "   - 位置：$startupShortcut" -ForegroundColor Gray

    # 步驟 5: 顯示結果
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║      Claude Code UI 自動啟動設置完成！                  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "配置信息：" -ForegroundColor Cyan
    Write-Host "   - 專案目錄：$repoRoot" -ForegroundColor White
    Write-Host "   - 本地端口：$port" -ForegroundColor White
    Write-Host "   - Runner 腳本：$runnerScript" -ForegroundColor White
    Write-Host "   - Log 檔案：$logFile" -ForegroundColor White
    if ($ngrokDomain) {
        Write-Host "   - ngrok Domain：$ngrokDomain" -ForegroundColor White
        Write-Host "   - 訪問 URL：https://$ngrokDomain" -ForegroundColor White
    } else {
        Write-Host "   - ngrok Domain：（隨機，每次啟動不同）" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "後續步驟：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. 立即啟動服務（不用等重開機）：" -ForegroundColor Yellow
    Write-Host "   powershell -File `"$runnerScript`"" -ForegroundColor White
    Write-Host ""
    Write-Host "2. 驗證服務運行狀態：" -ForegroundColor Yellow
    Write-Host "   .\Setup-NgrokTunnel.ps1 -Verify" -ForegroundColor White
    Write-Host ""
    Write-Host "3. 重開機後自動啟動：" -ForegroundColor Yellow
    Write-Host "   已配置 Windows 啟動項，無需手動操作" -ForegroundColor White
    Write-Host ""
    Write-Host "提示：" -ForegroundColor Cyan
    Write-Host "   - 查看 log：Get-Content `"$logFile`" -Tail 20" -ForegroundColor White
    Write-Host "   - 移除配置：.\Setup-NgrokTunnel.ps1 -Remove" -ForegroundColor White
    Write-Host "   - 強制重裝：.\Setup-NgrokTunnel.ps1 -Install -Force" -ForegroundColor White
    Write-Host ""

    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}
