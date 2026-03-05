<#
.SYNOPSIS
    Setup Claude Code UI with Tailscale Funnel for auto-start on Windows boot

.DESCRIPTION
    Configures Claude Code UI (Express server + Tailscale Funnel) to start automatically
    when Windows boots. Creates a runner script and a Windows Startup shortcut.

    This is a user-level script that does NOT require administrator privileges.

    Tailscale Funnel is a free alternative to ngrok that provides a fixed HTTPS URL
    (*.ts.net) without requiring a paid subscription.

    Requirements:
    - Node.js and npm must be installed
    - Tailscale must be installed and logged in (tailscale up)
    - npm dependencies must be installed (npm install)

.PARAMETER Install
    Build the frontend, create runner script, and add Windows startup shortcut

.PARAMETER Remove
    Remove runner script, startup shortcut, and stop Funnel

.PARAMETER Verify
    Verify that the server and Tailscale Funnel are running

.PARAMETER Force
    Force reconfiguration even if already setup

.PARAMETER NonInteractive
    No user prompts (for automation)

.EXAMPLE
    .\Setup-TailscaleFunnel.ps1 -Install
    Build and configure auto-start with Tailscale Funnel

.EXAMPLE
    .\Setup-TailscaleFunnel.ps1 -Verify
    Verify all services are running

.EXAMPLE
    .\Setup-TailscaleFunnel.ps1 -Remove
    Remove auto-start configuration and stop Funnel

.NOTES
    - Creates scripts in: $env:USERPROFILE\Scripts\
    - Creates startup shortcut in: Startup folder
    - Log file: $env:USERPROFILE\Scripts\claude-code-ui-funnel.log
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

Write-Host "--- Claude Code UI + Tailscale Funnel 設置腳本 ---" -ForegroundColor Cyan

# 計算路徑
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $scriptPath
$repoRoot = Split-Path -Parent $scriptsDir
$envFile = Join-Path $repoRoot ".env"
$envExample = Join-Path $repoRoot ".env.example"

# 部署路徑
$userScriptsDir = Join-Path $env:USERPROFILE "Scripts"
$runnerScript = Join-Path $userScriptsDir "Start-ClaudeCodeUIFunnel.ps1"
$logFile = Join-Path $userScriptsDir "claude-code-ui-funnel.log"
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupFolder "Start-ClaudeCodeUIFunnel.lnk"

# 處理互斥操作
$operations = @($Install, $Remove, $Verify)
$operationCount = ($operations | Where-Object { $_ -eq $true }).Count

if ($operationCount -eq 0) {
    Write-Host "`n請指定操作：-Install, -Remove, 或 -Verify" -ForegroundColor Red
    Write-Host ""
    Write-Host "使用範例：" -ForegroundColor Cyan
    Write-Host "   .\Setup-TailscaleFunnel.ps1 -Install" -ForegroundColor White
    Write-Host "   .\Setup-TailscaleFunnel.ps1 -Verify" -ForegroundColor White
    Write-Host "   .\Setup-TailscaleFunnel.ps1 -Remove" -ForegroundColor White
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

# 步驟 0: 檢查 Tailscale
Write-Host "`n1. 正在檢查 Tailscale..." -ForegroundColor Yellow

$tailscaleCommand = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $tailscaleCommand) {
    Write-Host "   - 未找到 Tailscale" -ForegroundColor Red
    Write-Host "   - 請先安裝 Tailscale：https://tailscale.com/download" -ForegroundColor Yellow
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}
Write-Host "   - Tailscale 已安裝 ✓" -ForegroundColor Green

# 檢查登入狀態
$statusOutput = tailscale status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   - 未登入 Tailscale 網路" -ForegroundColor Red
    Write-Host "   - 請先登入：tailscale up" -ForegroundColor Yellow
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}
Write-Host "   - 已登入 Tailscale 網路 ✓" -ForegroundColor Green

# === 驗證操作 ===
if ($Verify) {
    Write-Host "`n=== 開始驗證服務 ===" -ForegroundColor Cyan

    $allGood = $true

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    $port = "3001"
    $tsHttpsPort = ""
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile
        $portLine = $envContent | Select-String '^PORT\s*='
        if ($portLine) {
            $port = ($portLine.Line -split '=', 2)[1].Trim()
        }
        $tsPortLine = $envContent | Select-String '^TAILSCALE_HTTPS_PORT\s*='
        if ($tsPortLine) {
            $tsHttpsPort = ($tsPortLine.Line -split '=', 2)[1].Trim()
        }
    }
    $tsHttpsArg = if ($tsHttpsPort) { "--https=$tsHttpsPort" } else { "" }

    # 檢查 node server 進程
    Write-Host "`n2. 檢查 Node.js server 進程..." -ForegroundColor Yellow
    $nodeProcs = Get-Process -Name "node" -ErrorAction SilentlyContinue
    if ($nodeProcs) {
        Write-Host "   - Node.js 進程運行中 (PID: $($nodeProcs.Id -join ', ')) ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 未找到 Node.js 進程" -ForegroundColor Red
        $allGood = $false
    }

    # 嘗試 HTTP 請求 localhost:PORT/health
    Write-Host "`n3. 檢查 HTTP 服務 (localhost:$port)..." -ForegroundColor Yellow
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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

    # 檢查 Tailscale Funnel 狀態
    Write-Host "`n4. 檢查 Tailscale Funnel 狀態..." -ForegroundColor Yellow
    $funnelStatus = tailscale funnel status 2>$null
    $funnelCheck = $funnelStatus | Select-String "localhost:$port"
    if ($funnelCheck) {
        Write-Host "   - Tailscale Funnel 運行中 ✓" -ForegroundColor Green

        # 提取訪問 URL
        $funnelUrl = $funnelStatus | Where-Object { $_ -notmatch '^\s*#' } | Select-String "https://.*\.ts\.net" | Select-Object -First 1
        if ($funnelUrl) {
            if ($funnelUrl.Line -match '(https://\S+)') {
                Write-Host "   - 公網 URL：$($Matches[1])" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "   - Tailscale Funnel 未運行" -ForegroundColor Red
        Write-Host "   - 手動啟動：tailscale funnel --bg http://localhost:$port" -ForegroundColor Yellow
        $allGood = $false
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
    Write-Host "`n=== 開始移除 Claude Code UI + Tailscale Funnel 自動啟動配置 ===" -ForegroundColor Cyan

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    $port = "3001"
    $tsHttpsPort = ""
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile
        $portLine = $envContent | Select-String '^PORT\s*='
        if ($portLine) {
            $port = ($portLine.Line -split '=', 2)[1].Trim()
        }
        $tsPortLine = $envContent | Select-String '^TAILSCALE_HTTPS_PORT\s*='
        if ($tsPortLine) {
            $tsHttpsPort = ($tsPortLine.Line -split '=', 2)[1].Trim()
        }
    }
    $tsHttpsArg = if ($tsHttpsPort) { "--https=$tsHttpsPort" } else { "--https=443" }

    # 確認操作
    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "此操作將移除：" -ForegroundColor Yellow
        Write-Host "   - Tailscale Funnel 配置" -ForegroundColor White
        Write-Host "   - Runner 腳本 (Start-ClaudeCodeUIFunnel.ps1)" -ForegroundColor White
        Write-Host "   - Windows 啟動項捷徑" -ForegroundColor White
        Write-Host "   - Log 檔案" -ForegroundColor White
        Write-Host ""
        $confirm = Read-Host "   確定要繼續嗎？(Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "   - 已取消操作" -ForegroundColor Yellow
            exit 0
        }
    }

    # 停止 Tailscale Funnel（只移除 Claude Code UI 的路徑，不影響同 port 上的其他服務）
    Write-Host "`n2. 正在停止 Tailscale Funnel..." -ForegroundColor Yellow
    $funnelStatus = tailscale funnel status 2>$null
    $funnelRunning = $funnelStatus | Select-String "localhost:$port"
    if ($funnelRunning) {
        # 從 URL 偵測實際 HTTPS port（無 port 表示 443，有 :port 則取該值）
        $actualUrl = $funnelStatus | Where-Object { $_ -notmatch '^\s*#' } | Select-String "https://.*\.ts\.net" | Select-Object -First 1
        $actualHttpsPort = "443"
        if ($actualUrl -and $actualUrl.Line -match ':(\d+)\s') {
            $actualHttpsPort = $Matches[1]
        }
        Write-Host "   - 偵測到 Funnel 在 HTTPS port $actualHttpsPort 上" -ForegroundColor Gray
        # 只移除 / 路徑，保留同 port 上的其他路由
        tailscale funnel --https=$actualHttpsPort --set-path=/ off 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $recheckStatus = tailscale funnel status 2>$null
        $recheckRunning = $recheckStatus | Select-String "localhost:$port"
        if (-not $recheckRunning) {
            Write-Host "   - Funnel 已停止 ✓" -ForegroundColor Green
        } else {
            Write-Host "   - 警告：無法自動停止 Funnel，請手動執行 tailscale funnel --https=$actualHttpsPort --set-path=/ off" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   - Funnel 未運行，跳過" -ForegroundColor Gray
    }

    # 停止佔用 port 的進程
    Write-Host "`n3. 正在停止 port $port 上的服務..." -ForegroundColor Yellow
    $portConn = Get-NetTCPConnection -LocalPort ([int]$port) -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Listen' } |
        Select-Object -First 1
    if ($portConn) {
        $proc = Get-Process -Id $portConn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "   - 發現 $($proc.ProcessName) 進程 (PID: $($proc.Id)) 佔用 port $port" -ForegroundColor Gray
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Host "   - 已停止 ✓" -ForegroundColor Green
        }
    } else {
        Write-Host "   - 未找到 port $port 上的服務" -ForegroundColor Gray
    }

    # 刪除腳本
    Write-Host "`n4. 正在刪除腳本..." -ForegroundColor Yellow

    if (Test-Path $runnerScript) {
        Remove-Item $runnerScript -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除 Start-ClaudeCodeUIFunnel.ps1 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Start-ClaudeCodeUIFunnel.ps1 不存在，跳過" -ForegroundColor Gray
    }

    if (Test-Path $logFile) {
        Remove-Item $logFile -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除 log 檔案 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Log 檔案不存在，跳過" -ForegroundColor Gray
    }

    # 清理附帶 log 檔案
    @("$logFile.server.out", "$logFile.server.err") | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -ErrorAction SilentlyContinue
        }
    }

    # 刪除啟動項
    Write-Host "`n5. 正在刪除 Windows 啟動項..." -ForegroundColor Yellow

    if (Test-Path $startupShortcut) {
        Remove-Item $startupShortcut -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除啟動捷徑 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 啟動捷徑不存在，跳過" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "移除完成！" -ForegroundColor Green
    Write-Host ""

    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}

# === 安裝操作 ===
if ($Install) {
    Write-Host "`n=== 開始設置 Claude Code UI + Tailscale Funnel 自動啟動 ===" -ForegroundColor Cyan

    # 步驟 2: 檢查前置條件
    Write-Host "`n2. 正在檢查前置條件..." -ForegroundColor Yellow

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

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    $envContent = Get-Content $envFile
    $portLine = $envContent | Select-String '^PORT\s*='
    $port = "3001"
    if ($portLine) {
        $port = ($portLine.Line -split '=', 2)[1].Trim()
    }
    Write-Host "   - 端口配置：$port" -ForegroundColor Gray

    $tsPortLine = $envContent | Select-String '^TAILSCALE_HTTPS_PORT\s*='
    $tsHttpsPort = ""
    if ($tsPortLine) {
        $tsHttpsPort = ($tsPortLine.Line -split '=', 2)[1].Trim()
    }
    $tsHttpsArg = if ($tsHttpsPort) { "--https=$tsHttpsPort" } else { "" }
    $tsHttpsOffArg = if ($tsHttpsPort) { "--https=$tsHttpsPort" } else { "--https=443" }
    if ($tsHttpsPort) {
        Write-Host "   - Tailscale HTTPS 端口：$tsHttpsPort" -ForegroundColor Gray
    }

    # 檢查是否已安裝且不強制
    if ((Test-Path $runnerScript) -and (Test-Path $startupShortcut) -and -not $Force) {
        # 檢查 Funnel 是否已在運行
        $funnelStatus = tailscale funnel status 2>$null
        $funnelRunning = $funnelStatus | Select-String "localhost:$port"

        if ($funnelRunning) {
            Write-Host ""
            Write-Host "已檢測到現有安裝配置且 Funnel 運行中 ✓" -ForegroundColor Green
            Write-Host "   - Runner 腳本：$runnerScript" -ForegroundColor Gray
            Write-Host "   - 啟動捷徑：$startupShortcut" -ForegroundColor Gray

            # 提取訪問 URL
            $funnelUrl = $funnelStatus | Where-Object { $_ -notmatch '^\s*#' } | Select-String "https://.*\.ts\.net" | Select-Object -First 1
            if ($funnelUrl) {
                if ($funnelUrl.Line -match '(https://\S+)') {
                    Write-Host "   - 公網 URL：$($Matches[1])" -ForegroundColor Gray
                }
            }

            Write-Host ""
            Write-Host "如需重新配置，請使用 -Force 參數：" -ForegroundColor Yellow
            Write-Host "   .\Setup-TailscaleFunnel.ps1 -Install -Force" -ForegroundColor White
            Write-Host ""
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 0
        }
    }

    # 步驟 3: 安裝依賴並建置前端
    Write-Host "`n3. 正在安裝依賴 (npm install)..." -ForegroundColor Yellow
    Push-Location $repoRoot
    try {
        $installOutput = npm install 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   - 依賴安裝成功 ✓" -ForegroundColor Green
        } else {
            Write-Host "   - 依賴安裝失敗" -ForegroundColor Red
            $installOutput | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 1
        }

        Write-Host "`n4. 正在建置前端 (npm run build)..." -ForegroundColor Yellow
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

    # 步驟 5: 配置 Tailscale Funnel
    Write-Host "`n5. 正在配置 Tailscale Funnel..." -ForegroundColor Yellow

    # 檢查 Funnel 是否已在運行
    $funnelStatus = tailscale funnel status 2>$null
    $funnelRunning = $funnelStatus | Select-String "localhost:$port"

    if ($funnelRunning -and $Force) {
        Write-Host "   - 使用 -Force 參數，正在停止現有 Funnel..." -ForegroundColor Gray
        # 從 URL 偵測實際 HTTPS port
        $actualUrl = $funnelStatus | Where-Object { $_ -notmatch '^\s*#' } | Select-String "https://.*\.ts\.net" | Select-Object -First 1
        $actualHttpsPort = "443"
        if ($actualUrl -and $actualUrl.Line -match ':(\d+)\s') {
            $actualHttpsPort = $Matches[1]
        }
        tailscale funnel --https=$actualHttpsPort --set-path=/ off 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $funnelRunning = $null  # 強制重新啟動
    }

    if (-not $funnelRunning -or $Force) {
        Write-Host "   - 正在啟動 Funnel (localhost:$port)..." -ForegroundColor Gray
        if ($tsHttpsArg) {
            $funnelOutput = tailscale funnel --bg $tsHttpsArg http://localhost:$port 2>&1
        } else {
            $funnelOutput = tailscale funnel --bg http://localhost:$port 2>&1
        }

        # 等待 Funnel 啟動
        Start-Sleep -Seconds 3

        # 驗證 Funnel 狀態
        $funnelStatus = tailscale funnel status 2>$null
        $funnelCheck = $funnelStatus | Select-String "localhost:$port"

        if ($funnelCheck) {
            Write-Host "   - Funnel 配置成功 ✓" -ForegroundColor Green
        } else {
            Write-Host "   - Funnel 配置失敗" -ForegroundColor Red
            Write-Host "   - 故障排除：" -ForegroundColor Yellow
            Write-Host "     - 檢查 Tailscale 狀態：tailscale status" -ForegroundColor White
            Write-Host "     - 手動配置：tailscale funnel --bg http://localhost:$port" -ForegroundColor White
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 1
        }
    } else {
        Write-Host "   - Funnel 已在運行中 ✓" -ForegroundColor Green
    }

    # 提取訪問 URL
    $funnelStatus = tailscale funnel status 2>$null
    $funnelUrl = $funnelStatus | Where-Object { $_ -notmatch '^\s*#' } | Select-String "https://.*\.ts\.net" | Select-Object -First 1
    $publicUrl = $null
    if ($funnelUrl -and $funnelUrl.Line -match '(https://\S+)') {
        $publicUrl = $Matches[1]
    }

    # 步驟 6: 創建 Runner 腳本
    Write-Host "`n6. 正在創建 Runner 腳本..." -ForegroundColor Yellow

    if (-not (Test-Path $userScriptsDir)) {
        New-Item -ItemType Directory -Path $userScriptsDir -Force | Out-Null
        Write-Host "   - 已創建目錄：$userScriptsDir" -ForegroundColor Gray
    }

    $runnerContent = @"
# Start-ClaudeCodeUIFunnel.ps1
# Auto-generated by Setup-TailscaleFunnel.ps1
# Starts Claude Code UI server and Tailscale Funnel

`$repoRoot = "$($repoRoot -replace '\\', '\\')"
`$logFile = "$($logFile -replace '\\', '\\')"
`$port = "$port"
`$tsHttpsArg = "$tsHttpsArg"

# Ensure we're in the project directory
Set-Location `$repoRoot

# Timestamp
`$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path `$logFile -Value ""
Add-Content -Path `$logFile -Value "=== [`$timestamp] Starting Claude Code UI + Tailscale Funnel ==="

# Start Express server in background
Add-Content -Path `$logFile -Value "Starting server (npm run server)..."
`$serverJob = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm run server" ``
    -WorkingDirectory `$repoRoot ``
    -WindowStyle Hidden ``
    -RedirectStandardOutput "`$logFile.server.out" ``
    -RedirectStandardError "`$logFile.server.err" ``
    -PassThru

Add-Content -Path `$logFile -Value "Server started (PID: `$(`$serverJob.Id))"

# Wait for server to initialize
Start-Sleep -Seconds 5

# Start Tailscale Funnel (idempotent - checks if already running)
Add-Content -Path `$logFile -Value "Checking Tailscale Funnel..."
`$funnelCheck = tailscale funnel status 2>`$null | Select-String "localhost:`$port"
if (-not `$funnelCheck) {
    Add-Content -Path `$logFile -Value "Starting Tailscale Funnel on port `$port..."
    if (`$tsHttpsArg) {
        tailscale funnel --bg `$tsHttpsArg http://localhost:`$port 2>&1 | Out-Null
    } else {
        tailscale funnel --bg http://localhost:`$port 2>&1 | Out-Null
    }
    Add-Content -Path `$logFile -Value "Funnel started"
} else {
    Add-Content -Path `$logFile -Value "Funnel already running, skipping"
}

Add-Content -Path `$logFile -Value "=== Startup complete ==="
"@

    Set-Content -Path $runnerScript -Value $runnerContent -Encoding UTF8
    Write-Host "   - 已創建 Start-ClaudeCodeUIFunnel.ps1 ✓" -ForegroundColor Green
    Write-Host "   - 位置：$runnerScript" -ForegroundColor Gray

    # 步驟 7: 創建 Windows 啟動項
    Write-Host "`n7. 正在配置 Windows 啟動項..." -ForegroundColor Yellow

    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($startupShortcut)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerScript`""
    $Shortcut.WorkingDirectory = $repoRoot
    $Shortcut.WindowStyle = 7  # 最小化
    $Shortcut.Description = "Claude Code UI + Tailscale Funnel Auto-Start"
    $Shortcut.Save()

    Write-Host "   - 已創建啟動捷徑 ✓" -ForegroundColor Green
    Write-Host "   - 位置：$startupShortcut" -ForegroundColor Gray

    # 步驟 8: 顯示結果
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   Claude Code UI + Tailscale Funnel 自動啟動設置完成！  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "配置信息：" -ForegroundColor Cyan
    Write-Host "   - 專案目錄：$repoRoot" -ForegroundColor White
    Write-Host "   - 本地端口：$port" -ForegroundColor White
    Write-Host "   - Runner 腳本：$runnerScript" -ForegroundColor White
    Write-Host "   - Log 檔案：$logFile" -ForegroundColor White
    if ($publicUrl) {
        Write-Host "   - 公網 URL：$publicUrl" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "後續步驟：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. 立即啟動服務（不用等重開機）：" -ForegroundColor Yellow
    Write-Host "   powershell -File `"$runnerScript`"" -ForegroundColor White
    Write-Host ""
    Write-Host "2. 驗證服務運行狀態：" -ForegroundColor Yellow
    Write-Host "   .\Setup-TailscaleFunnel.ps1 -Verify" -ForegroundColor White
    Write-Host ""
    Write-Host "3. 重開機後自動啟動：" -ForegroundColor Yellow
    Write-Host "   已配置 Windows 啟動項，無需手動操作" -ForegroundColor White
    Write-Host ""
    Write-Host "提示：" -ForegroundColor Cyan
    Write-Host "   - 查看 log：Get-Content `"$logFile`" -Tail 20" -ForegroundColor White
    Write-Host "   - Funnel 狀態：tailscale funnel status" -ForegroundColor White
    Write-Host "   - 移除配置：.\Setup-TailscaleFunnel.ps1 -Remove" -ForegroundColor White
    Write-Host "   - 強制重裝：.\Setup-TailscaleFunnel.ps1 -Install -Force" -ForegroundColor White
    Write-Host ""
    Write-Host "vs ngrok 的優勢：" -ForegroundColor Cyan
    Write-Host "   - 完全免費（不需要 authtoken 或付費方案）" -ForegroundColor White
    Write-Host "   - 固定 URL（*.ts.net，不會每次變動）" -ForegroundColor White
    Write-Host "   - 無 endpoint 數量限制" -ForegroundColor White
    Write-Host ""

    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}
