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

# === Funnel 狀態偵測 ===
#
# Tailscale 的 serve 設定是以 DNS 名稱為 key 的，機器改名後舊名的條目會留在設定裡卻不再服務
# 任何流量，而 `tailscale funnel status` 會把它們一併印出來。用純文字比對 "localhost:<port>"
# 或抓第一個 https://*.ts.net 因此會撈到早就失效的殘留條目——誤判成「已在運行」而跳過設置、
# 顯示一個連不上的公網 URL，或把別筆設定的 HTTPS port 當成自己的（-Remove 就是這樣關錯對象
# 而失敗的）。底下的判斷一律針對「目前的 DNS 名稱」查 serve 設定。

# 本機目前在 Tailscale 上的 DNS 名稱（不含結尾的點）。--peers=false 讓 JSON 只含本機。
function Get-TailscaleDnsName {
    $raw = tailscale status --peers=false --json 2>$null
    if (-not $raw) { return $null }
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $json.Self.DNSName) { return $null }
    return $json.Self.DNSName.TrimEnd('.')
}

function Get-TailscaleServeConfig {
    $raw = tailscale serve status --json 2>$null
    if (-not $raw) { return $null }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

# 目前 DNS 名稱 + 指定 HTTPS port 底下，/ 是否已轉發到指定的 localhost port。
# 只認對外公開的 Funnel（AllowFunnel），僅限 tailnet 的 serve 不算。
function Test-TailscaleFunnel {
    param(
        [string]$DnsName,
        [string]$HttpsPort = "443",
        [string]$LocalPort
    )

    if (-not $DnsName) { return $false }

    $serve = Get-TailscaleServeConfig
    if (-not $serve) { return $false }

    $key = "${DnsName}:$HttpsPort"
    if (-not $serve.AllowFunnel.$key) { return $false }

    return ($serve.Web.$key.Handlers.'/'.Proxy -eq "http://localhost:$LocalPort")
}

# 對外網址；443 不會出現在 URL 裡
function Get-TailscaleFunnelUrl {
    param(
        [string]$DnsName,
        [string]$HttpsPort = "443"
    )

    if (-not $DnsName) { return $null }
    if ($HttpsPort -eq "443") { return "https://$DnsName" }
    return "https://${DnsName}:$HttpsPort"
}

# 目前 DNS 名稱底下、已轉發到指定 localhost port 的所有 HTTPS port
function Get-TailscaleFunnelPortsForTarget {
    param(
        [string]$DnsName,
        [string]$LocalPort
    )

    $ports = @()
    if (-not $DnsName) { return $ports }

    $serve = Get-TailscaleServeConfig
    if (-not $serve -or -not $serve.Web) { return $ports }

    foreach ($entry in $serve.Web.PSObject.Properties) {
        if (-not $entry.Name.StartsWith("${DnsName}:")) { continue }
        if ($entry.Value.Handlers.'/'.Proxy -ne "http://localhost:$LocalPort") { continue }
        $ports += $entry.Name.Substring($DnsName.Length + 1)
    }

    return $ports
}

# 掛在「舊 DNS 名稱」底下、指向指定 localhost port 的殘留設定。
# 機器改名後就會留下這種條目：它不再服務任何流量，而 `tailscale funnel ... off` 只作用在目前
# 的名稱上，所以清不掉——唯一的辦法是 `tailscale serve reset` 整組清除後把要保留的重建回去。
function Get-TailscaleStaleFunnelKeys {
    param(
        [string]$DnsName,
        [string]$LocalPort
    )

    $stale = @()
    if (-not $DnsName) { return $stale }

    $serve = Get-TailscaleServeConfig
    if (-not $serve -or -not $serve.Web) { return $stale }

    foreach ($entry in $serve.Web.PSObject.Properties) {
        if ($entry.Name.StartsWith("${DnsName}:")) { continue }
        if ($entry.Value.Handlers.'/'.Proxy -eq "http://localhost:$LocalPort") {
            $stale += $entry.Name
        }
    }

    return $stale
}

$tsDnsName = Get-TailscaleDnsName
if ($tsDnsName) {
    Write-Host "   - DNS 名稱：$tsDnsName" -ForegroundColor Gray
} else {
    Write-Host "   - 無法取得 Tailscale DNS 名稱，Funnel 狀態偵測可能不準確" -ForegroundColor Yellow
}

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
    $expectedHttpsPort = if ($tsHttpsPort) { $tsHttpsPort } else { "443" }
    if (Test-TailscaleFunnel -DnsName $tsDnsName -HttpsPort $expectedHttpsPort -LocalPort $port) {
        Write-Host "   - Tailscale Funnel 運行中 ✓" -ForegroundColor Green
        Write-Host "   - 公網 URL：$(Get-TailscaleFunnelUrl -DnsName $tsDnsName -HttpsPort $expectedHttpsPort)" -ForegroundColor Green
    } else {
        Write-Host "   - Tailscale Funnel 未運行" -ForegroundColor Red
        Write-Host "   - 手動啟動：tailscale funnel --bg $tsHttpsArg http://localhost:$port" -ForegroundColor Yellow
        $allGood = $false

        $staleKeys = @(Get-TailscaleStaleFunnelKeys -DnsName $tsDnsName -LocalPort $port)
        if ($staleKeys.Count -gt 0) {
            Write-Host "   - 注意：舊 DNS 名稱底下有指向 localhost:$port 的殘留設定（機器改名留下的）：" -ForegroundColor Yellow
            $staleKeys | ForEach-Object { Write-Host "     $_" -ForegroundColor White }
            Write-Host "     它們不會服務任何流量，只能用 tailscale serve reset 清除" -ForegroundColor Gray
        }
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

    # 用目前 DNS 名稱底下的實際設定決定要關哪個 HTTPS port——不能從 status 文字猜，
    # 猜到的可能是舊名或別的服務的條目，關下去不是關錯對象就是什麼都沒關到。
    $portsToStop = @(Get-TailscaleFunnelPortsForTarget -DnsName $tsDnsName -LocalPort $port)

    if ($portsToStop.Count -gt 0) {
        foreach ($stopPort in $portsToStop) {
            Write-Host "   - 偵測到 Funnel 在 HTTPS port $stopPort 上" -ForegroundColor Gray
            # 只移除 / 路徑，保留同 port 上的其他路由
            tailscale funnel --https=$stopPort --set-path=/ off 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500

            if (Test-TailscaleFunnel -DnsName $tsDnsName -HttpsPort $stopPort -LocalPort $port) {
                Write-Host "   - 警告：無法自動停止，請手動執行 tailscale funnel --https=$stopPort --set-path=/ off" -ForegroundColor Yellow
            } else {
                Write-Host "   - Funnel 已停止 ✓" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "   - 目前 DNS 名稱底下沒有對應的 Funnel，跳過" -ForegroundColor Gray
    }

    # 舊主機名底下的殘留設定：funnel off 對它們無效，只能整組 reset
    $staleKeys = @(Get-TailscaleStaleFunnelKeys -DnsName $tsDnsName -LocalPort $port)
    if ($staleKeys.Count -gt 0) {
        Write-Host ""
        Write-Host "   - 偵測到掛在舊 DNS 名稱底下、指向 localhost:$port 的殘留設定：" -ForegroundColor Yellow
        $staleKeys | ForEach-Object { Write-Host "     $_" -ForegroundColor White }
        Write-Host "     這是機器改名留下的，不會再服務任何流量，但 funnel off 也清不掉。" -ForegroundColor Gray
        Write-Host "     要清除請執行 tailscale serve reset（會清掉本機全部 serve/funnel 設定），" -ForegroundColor Gray
        Write-Host "     再把其他要保留的服務重新加回去。" -ForegroundColor Gray
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

    $expectedHttpsPort = if ($tsHttpsPort) { $tsHttpsPort } else { "443" }
    $expectedUrl = Get-TailscaleFunnelUrl -DnsName $tsDnsName -HttpsPort $expectedHttpsPort

    # 檢查是否已安裝且不強制
    if ((Test-Path $runnerScript) -and (Test-Path $startupShortcut) -and -not $Force) {
        # 檢查 Funnel 是否已在運行
        if (Test-TailscaleFunnel -DnsName $tsDnsName -HttpsPort $expectedHttpsPort -LocalPort $port) {
            Write-Host ""
            Write-Host "已檢測到現有安裝配置且 Funnel 運行中 ✓" -ForegroundColor Green
            Write-Host "   - Runner 腳本：$runnerScript" -ForegroundColor Gray
            Write-Host "   - 啟動捷徑：$startupShortcut" -ForegroundColor Gray
            Write-Host "   - 公網 URL：$expectedUrl" -ForegroundColor Gray

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
    $funnelRunning = Test-TailscaleFunnel -DnsName $tsDnsName -HttpsPort $expectedHttpsPort -LocalPort $port

    # 掛在其他 HTTPS port 上的舊設定（.env 改過 TAILSCALE_HTTPS_PORT 就會出現），要先關掉；
    # -Force 時連目前這筆一起關掉重來。每一筆都用它自己的 port 關，不靠猜。
    $portsToStop = @(Get-TailscaleFunnelPortsForTarget -DnsName $tsDnsName -LocalPort $port |
                     Where-Object { $_ -ne $expectedHttpsPort })
    if ($Force -and $funnelRunning) {
        $portsToStop += $expectedHttpsPort
    }

    foreach ($stopPort in $portsToStop) {
        $reason = if ($stopPort -eq $expectedHttpsPort) { "使用 -Force 參數" } else { "HTTPS port $stopPort 不是期望的 $expectedHttpsPort" }
        Write-Host "   - $reason，正在停止 https port $stopPort 上的 Funnel..." -ForegroundColor Gray
        tailscale funnel --https=$stopPort --set-path=/ off 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        if ($stopPort -eq $expectedHttpsPort) { $funnelRunning = $false }
    }

    if (-not $funnelRunning) {
        Write-Host "   - 正在啟動 Funnel (localhost:$port)..." -ForegroundColor Gray
        if ($tsHttpsArg) {
            $funnelOutput = tailscale funnel --bg $tsHttpsArg http://localhost:$port 2>&1
        } else {
            $funnelOutput = tailscale funnel --bg http://localhost:$port 2>&1
        }

        # 等待 Funnel 啟動
        Start-Sleep -Seconds 3

        # 驗證 Funnel 狀態
        if (Test-TailscaleFunnel -DnsName $tsDnsName -HttpsPort $expectedHttpsPort -LocalPort $port) {
            Write-Host "   - Funnel 配置成功 ✓" -ForegroundColor Green
        } else {
            Write-Host "   - Funnel 配置失敗" -ForegroundColor Red
            Write-Host "   - 故障排除：" -ForegroundColor Yellow
            Write-Host "     - 檢查 Tailscale 狀態：tailscale status" -ForegroundColor White
            Write-Host "     - 檢查實際設定：tailscale serve status --json" -ForegroundColor White
            Write-Host "     - 手動配置：tailscale funnel --bg $tsHttpsArg http://localhost:$port" -ForegroundColor White
            if (-not $NonInteractive) {
                Read-Host "按 Enter 鍵結束..."
            }
            exit 1
        }
    } else {
        Write-Host "   - Funnel 已在運行中 ✓" -ForegroundColor Green
    }

    # 提取訪問 URL（直接由目前的 DNS 名稱算出來，不從 status 文字硬撈）
    $publicUrl = $expectedUrl

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
`$httpsPort = "$expectedHttpsPort"

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
#
# 不能用 tailscale funnel status 的文字去比對 localhost:<port>：serve 設定以 DNS 名稱為 key，
# 機器改名後舊名的條目會留在設定裡卻不再服務流量，status 仍會印出來，比對到就會誤判成
# 「還在跑」而永遠不重建 Funnel。一律對目前的 DNS 名稱查設定。
Add-Content -Path `$logFile -Value "Checking Tailscale Funnel..."

`$funnelCheck = `$false
`$statusJson = tailscale status --peers=false --json 2>`$null
if (`$statusJson) {
    try {
        `$dnsName = (`$statusJson | ConvertFrom-Json).Self.DNSName.TrimEnd('.')
        `$serve = tailscale serve status --json 2>`$null | ConvertFrom-Json
        `$key = "`${dnsName}:`$httpsPort"
        `$funnelCheck = (`$serve.AllowFunnel.`$key -eq `$true) -and
                       (`$serve.Web.`$key.Handlers.'/'.Proxy -eq "http://localhost:`$port")
    } catch {
        `$funnelCheck = `$false
    }
}

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
