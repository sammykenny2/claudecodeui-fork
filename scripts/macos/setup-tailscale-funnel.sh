#!/bin/bash
#
# Setup Claude Code UI with Tailscale Funnel for auto-start on macOS boot
#
# Configures Claude Code UI (Express server + Tailscale Funnel) to start automatically
# when macOS boots via launchd LaunchAgent.
#
# This is a user-level script that does NOT require administrator privileges.
#
# Tailscale Funnel is a free alternative to ngrok that provides a fixed HTTPS URL
# (*.ts.net) without requiring a paid subscription.
#
# Requirements:
#   - Node.js and npm must be installed
#   - Tailscale must be installed and logged in (tailscale up)
#   - npm dependencies must be installed (npm install)
#
# Usage:
#   ./setup-tailscale-funnel.sh install          Build and configure auto-start
#   ./setup-tailscale-funnel.sh install --force   Force reconfiguration
#   ./setup-tailscale-funnel.sh verify           Verify services are running
#   ./setup-tailscale-funnel.sh remove           Remove auto-start configuration
#   ./setup-tailscale-funnel.sh remove -y        Remove without confirmation
#

set -euo pipefail

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# --- 計算路徑 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SCRIPTS_DIR")"
ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

# --- 部署路徑 ---
RUNNER_SCRIPT="$HOME/Scripts/start-claude-code-ui-funnel.sh"
LOG_FILE="$HOME/Scripts/claude-code-ui-funnel.log"
PLIST_LABEL="com.claude-code-ui.tailscale-funnel"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPTS_HOME_DIR="$HOME/Scripts"

echo -e "${CYAN}--- Claude Code UI + Tailscale Funnel 設置腳本 (macOS) ---${NC}"

# --- 輔助函數 ---
read_env_value() {
    local key="$1"
    local file="$2"
    if [ -f "$file" ]; then
        grep "^${key}\s*=" "$file" 2>/dev/null | head -1 | sed "s/^${key}\s*=\s*//" | xargs
    fi
}

# --- 解析參數 ---
ACTION=""
FORCE=false
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        install)  ACTION="install" ;;
        remove)   ACTION="remove" ;;
        verify)   ACTION="verify" ;;
        --force)  FORCE=true ;;
        -y)       NON_INTERACTIVE=true ;;
        *)
            echo -e "${RED}未知參數：$1${NC}"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$ACTION" ]; then
    echo -e "\n${RED}請指定操作：install, remove, 或 verify${NC}"
    echo ""
    echo -e "${CYAN}使用範例：${NC}"
    echo -e "   ./setup-tailscale-funnel.sh install"
    echo -e "   ./setup-tailscale-funnel.sh verify"
    echo -e "   ./setup-tailscale-funnel.sh remove"
    exit 1
fi

# --- 檢查 Tailscale ---
echo -e "\n${YELLOW}1. 正在檢查 Tailscale...${NC}"

if ! command -v tailscale &>/dev/null; then
    echo -e "   ${RED}- 未找到 Tailscale${NC}"
    echo -e "   ${YELLOW}- 請先安裝 Tailscale：https://tailscale.com/download${NC}"
    exit 1
fi
echo -e "   ${GREEN}- Tailscale 已安裝${NC}"

# 檢查登入狀態
if ! tailscale status &>/dev/null; then
    echo -e "   ${RED}- 未登入 Tailscale 網路${NC}"
    echo -e "   ${YELLOW}- 請先登入：tailscale up${NC}"
    exit 1
fi
echo -e "   ${GREEN}- 已登入 Tailscale 網路${NC}"

# =============================================================================
# === 驗證操作 ===
# =============================================================================
if [ "$ACTION" = "verify" ]; then
    echo -e "\n${CYAN}=== 開始驗證服務 ===${NC}"

    ALL_GOOD=true

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    PORT=$(read_env_value "PORT" "$ENV_FILE")
    PORT="${PORT:-3001}"
    TS_HTTPS_PORT=$(read_env_value "TAILSCALE_HTTPS_PORT" "$ENV_FILE")

    # 檢查 node server 進程
    echo -e "\n${YELLOW}2. 檢查 Node.js server 進程...${NC}"
    NODE_PIDS=$(pgrep -f "node.*server" 2>/dev/null || true)
    if [ -n "$NODE_PIDS" ]; then
        echo -e "   ${GREEN}- Node.js 進程運行中 (PID: $(echo $NODE_PIDS | tr '\n' ', ' | sed 's/,$//' ))${NC}"
    else
        echo -e "   ${RED}- 未找到 Node.js server 進程${NC}"
        ALL_GOOD=false
    fi

    # 嘗試 HTTP 請求 localhost:PORT/health
    echo -e "\n${YELLOW}3. 檢查 HTTP 服務 (localhost:$PORT)...${NC}"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:$PORT/health" 2>/dev/null || echo "000")
    if [ "$HTTP_STATUS" = "200" ]; then
        echo -e "   ${GREEN}- HTTP 服務正常 (status: $HTTP_STATUS)${NC}"
    else
        echo -e "   ${RED}- HTTP 服務無法連線 (status: $HTTP_STATUS)${NC}"
        ALL_GOOD=false
    fi

    # 檢查 Tailscale Funnel 狀態
    echo -e "\n${YELLOW}4. 檢查 Tailscale Funnel 狀態...${NC}"
    FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
    if echo "$FUNNEL_STATUS" | grep -q "localhost:$PORT"; then
        echo -e "   ${GREEN}- Tailscale Funnel 運行中${NC}"
        # 提取訪問 URL
        PUBLIC_URL=$(echo "$FUNNEL_STATUS" | grep -oE 'https://[^ ]+\.ts\.net[^ ]*' | head -1 || true)
        if [ -n "$PUBLIC_URL" ]; then
            echo -e "   ${GREEN}- 公網 URL：$PUBLIC_URL${NC}"
        fi
    else
        echo -e "   ${RED}- Tailscale Funnel 未運行${NC}"
        echo -e "   ${YELLOW}- 手動啟動：tailscale funnel --bg http://localhost:$PORT${NC}"
        ALL_GOOD=false
    fi

    # 檢查 runner 腳本和 LaunchAgent
    echo -e "\n${YELLOW}5. 檢查啟動配置...${NC}"
    if [ -f "$RUNNER_SCRIPT" ]; then
        echo -e "   ${GREEN}- Runner 腳本存在${NC}"
    else
        echo -e "   ${RED}- Runner 腳本不存在：$RUNNER_SCRIPT${NC}"
        ALL_GOOD=false
    fi

    if [ -f "$PLIST_FILE" ]; then
        echo -e "   ${GREEN}- LaunchAgent 配置存在${NC}"
        if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
            echo -e "   ${GREEN}- LaunchAgent 已載入${NC}"
        else
            echo -e "   ${YELLOW}- LaunchAgent 未載入${NC}"
        fi
    else
        echo -e "   ${RED}- LaunchAgent 配置不存在：$PLIST_FILE${NC}"
        ALL_GOOD=false
    fi

    # 檢查 log 檔案
    echo -e "\n${YELLOW}6. 檢查 log 檔案...${NC}"
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(du -h "$LOG_FILE" | cut -f1)
        LOG_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LOG_FILE" 2>/dev/null || stat -c "%y" "$LOG_FILE" 2>/dev/null | cut -d. -f1)
        echo -e "   ${GRAY}- Log 檔案存在 ($LOG_SIZE, 最後更新: $LOG_DATE)${NC}"
        echo -e "   ${GRAY}- 最後幾行 log：${NC}"
        tail -5 "$LOG_FILE" | while IFS= read -r line; do
            echo -e "     ${GRAY}$line${NC}"
        done
    else
        echo -e "   ${GRAY}- Log 檔案不存在（服務可能尚未啟動過）${NC}"
    fi

    # 總結
    echo ""
    if [ "$ALL_GOOD" = true ]; then
        echo -e "${GREEN}所有服務運行正常${NC}"
    else
        echo -e "${YELLOW}部分服務未運行，請檢查上方訊息${NC}"
    fi
    exit 0
fi

# =============================================================================
# === 移除操作 ===
# =============================================================================
if [ "$ACTION" = "remove" ]; then
    echo -e "\n${CYAN}=== 開始移除 Claude Code UI + Tailscale Funnel 自動啟動配置 ===${NC}"

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    PORT=$(read_env_value "PORT" "$ENV_FILE")
    PORT="${PORT:-3001}"
    TS_HTTPS_PORT=$(read_env_value "TAILSCALE_HTTPS_PORT" "$ENV_FILE")

    # 確認操作
    if [ "$NON_INTERACTIVE" = false ]; then
        echo ""
        echo -e "${YELLOW}此操作將移除：${NC}"
        echo -e "   - Tailscale Funnel 配置"
        echo -e "   - Runner 腳本 (start-claude-code-ui-funnel.sh)"
        echo -e "   - macOS LaunchAgent 配置"
        echo -e "   - Log 檔案"
        echo ""
        read -rp "   確定要繼續嗎？(Y/N) " CONFIRM
        if [[ "$CONFIRM" != "Y" && "$CONFIRM" != "y" ]]; then
            echo -e "   ${YELLOW}- 已取消操作${NC}"
            exit 0
        fi
    fi

    # 停止 Tailscale Funnel
    echo -e "\n${YELLOW}2. 正在停止 Tailscale Funnel...${NC}"
    FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
    if echo "$FUNNEL_STATUS" | grep -q "localhost:$PORT"; then
        # 偵測實際 HTTPS port
        ACTUAL_HTTPS_PORT=$(echo "$FUNNEL_STATUS" | grep -oE ':([0-9]+)' | head -1 | tr -d ':')
        ACTUAL_HTTPS_PORT="${ACTUAL_HTTPS_PORT:-443}"
        echo -e "   ${GRAY}- 偵測到 Funnel 在 HTTPS port $ACTUAL_HTTPS_PORT 上${NC}"
        tailscale funnel --https="$ACTUAL_HTTPS_PORT" --set-path=/ off 2>/dev/null || true
        sleep 1
        RECHECK=$(tailscale funnel status 2>/dev/null || echo "")
        if ! echo "$RECHECK" | grep -q "localhost:$PORT"; then
            echo -e "   ${GREEN}- Funnel 已停止${NC}"
        else
            echo -e "   ${YELLOW}- 警告：無法自動停止 Funnel，請手動執行 tailscale funnel --https=$ACTUAL_HTTPS_PORT --set-path=/ off${NC}"
        fi
    else
        echo -e "   ${GRAY}- Funnel 未運行，跳過${NC}"
    fi

    # 卸載 LaunchAgent 並停止服務
    echo -e "\n${YELLOW}3. 正在停止服務...${NC}"
    if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
        launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || launchctl unload "$PLIST_FILE" 2>/dev/null || true
        echo -e "   ${GREEN}- 已卸載 LaunchAgent${NC}"
    else
        echo -e "   ${GRAY}- LaunchAgent 未載入${NC}"
    fi

    # 停止佔用 port 的進程
    PORT_PID=$(lsof -ti ":$PORT" 2>/dev/null | head -1 || true)
    if [ -n "$PORT_PID" ]; then
        PORT_PROC=$(ps -p "$PORT_PID" -o comm= 2>/dev/null || echo "unknown")
        echo -e "   ${GRAY}- 發現 $PORT_PROC 進程 (PID: $PORT_PID) 佔用 port $PORT${NC}"
        kill "$PORT_PID" 2>/dev/null || true
        echo -e "   ${GREEN}- 已停止${NC}"
    else
        echo -e "   ${GRAY}- 未找到 port $PORT 上的服務${NC}"
    fi

    # 刪除腳本
    echo -e "\n${YELLOW}4. 正在刪除腳本...${NC}"
    if [ -f "$RUNNER_SCRIPT" ]; then
        rm -f "$RUNNER_SCRIPT"
        echo -e "   ${GREEN}- 已刪除 runner 腳本${NC}"
    else
        echo -e "   ${GRAY}- Runner 腳本不存在，跳過${NC}"
    fi

    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
        echo -e "   ${GREEN}- 已刪除 log 檔案${NC}"
    else
        echo -e "   ${GRAY}- Log 檔案不存在，跳過${NC}"
    fi

    # 清理附帶 log 檔案
    for f in "$LOG_FILE.server.out" "$LOG_FILE.server.err"; do
        [ -f "$f" ] && rm -f "$f"
    done

    # 刪除 LaunchAgent
    echo -e "\n${YELLOW}5. 正在刪除 macOS LaunchAgent...${NC}"
    if [ -f "$PLIST_FILE" ]; then
        rm -f "$PLIST_FILE"
        echo -e "   ${GREEN}- 已刪除 LaunchAgent 配置${NC}"
    else
        echo -e "   ${GRAY}- LaunchAgent 配置不存在，跳過${NC}"
    fi

    echo ""
    echo -e "${GREEN}移除完成！${NC}"
    exit 0
fi

# =============================================================================
# === 安裝操作 ===
# =============================================================================
if [ "$ACTION" = "install" ]; then
    echo -e "\n${CYAN}=== 開始設置 Claude Code UI + Tailscale Funnel 自動啟動 ===${NC}"

    # 步驟 2: 檢查前置條件
    echo -e "\n${YELLOW}2. 正在檢查前置條件...${NC}"

    # 檢查 Node.js
    if ! command -v node &>/dev/null; then
        echo -e "   ${RED}- 未找到 Node.js${NC}"
        echo -e "   ${YELLOW}- 請先安裝 Node.js：https://nodejs.org/${NC}"
        exit 1
    fi
    NODE_VERSION=$(node --version)
    echo -e "   ${GREEN}- Node.js $NODE_VERSION${NC}"

    # 檢查 npm
    if ! command -v npm &>/dev/null; then
        echo -e "   ${RED}- 未找到 npm${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- npm 已安裝${NC}"

    # 檢查 .env 檔案
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            echo -e "   ${GRAY}- 從 .env.example 創建 .env${NC}"
            cp "$ENV_EXAMPLE" "$ENV_FILE"
        else
            echo -e "   ${RED}- 未找到 .env 或 .env.example${NC}"
            exit 1
        fi
    fi

    # 讀取 PORT 和 TAILSCALE_HTTPS_PORT
    PORT=$(read_env_value "PORT" "$ENV_FILE")
    PORT="${PORT:-3001}"
    echo -e "   ${GRAY}- 端口配置：$PORT${NC}"

    TS_HTTPS_PORT=$(read_env_value "TAILSCALE_HTTPS_PORT" "$ENV_FILE")
    TS_HTTPS_ARG=""
    if [ -n "$TS_HTTPS_PORT" ]; then
        TS_HTTPS_ARG="--https=$TS_HTTPS_PORT"
        echo -e "   ${GRAY}- Tailscale HTTPS 端口：$TS_HTTPS_PORT${NC}"
    fi

    # 檢查是否已安裝且不強制
    if [ -f "$RUNNER_SCRIPT" ] && [ -f "$PLIST_FILE" ] && [ "$FORCE" = false ]; then
        FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
        if echo "$FUNNEL_STATUS" | grep -q "localhost:$PORT"; then
            echo ""
            echo -e "${GREEN}已檢測到現有安裝配置且 Funnel 運行中${NC}"
            echo -e "   ${GRAY}- Runner 腳本：$RUNNER_SCRIPT${NC}"
            echo -e "   ${GRAY}- LaunchAgent：$PLIST_FILE${NC}"
            PUBLIC_URL=$(echo "$FUNNEL_STATUS" | grep -oE 'https://[^ ]+\.ts\.net[^ ]*' | head -1 || true)
            if [ -n "$PUBLIC_URL" ]; then
                echo -e "   ${GRAY}- 公網 URL：$PUBLIC_URL${NC}"
            fi
            echo ""
            echo -e "${YELLOW}如需重新配置，請使用 --force 參數：${NC}"
            echo -e "   ./setup-tailscale-funnel.sh install --force"
            exit 0
        fi
    fi

    # 步驟 3: 安裝依賴並建置前端
    echo -e "\n${YELLOW}3. 正在安裝依賴 (npm install)...${NC}"
    cd "$REPO_ROOT"
    if npm install > /dev/null 2>&1; then
        echo -e "   ${GREEN}- 依賴安裝成功${NC}"
    else
        echo -e "   ${RED}- 依賴安裝失敗${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}4. 正在建置前端 (npm run build)...${NC}"
    if npm run build > /dev/null 2>&1; then
        echo -e "   ${GREEN}- 前端建置成功${NC}"
    else
        echo -e "   ${RED}- 前端建置失敗${NC}"
        exit 1
    fi

    # 步驟 5: 配置 Tailscale Funnel
    echo -e "\n${YELLOW}5. 正在配置 Tailscale Funnel...${NC}"

    FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
    FUNNEL_RUNNING=false
    if echo "$FUNNEL_STATUS" | grep -q "localhost:$PORT"; then
        FUNNEL_RUNNING=true
    fi

    if [ "$FUNNEL_RUNNING" = true ] && [ "$FORCE" = true ]; then
        echo -e "   ${GRAY}- 使用 --force 參數，正在停止現有 Funnel...${NC}"
        ACTUAL_HTTPS_PORT=$(echo "$FUNNEL_STATUS" | grep -oE ':([0-9]+)' | head -1 | tr -d ':')
        ACTUAL_HTTPS_PORT="${ACTUAL_HTTPS_PORT:-443}"
        tailscale funnel --https="$ACTUAL_HTTPS_PORT" --set-path=/ off 2>/dev/null || true
        sleep 2
        FUNNEL_RUNNING=false
    fi

    if [ "$FUNNEL_RUNNING" = false ]; then
        echo -e "   ${GRAY}- 正在啟動 Funnel (localhost:$PORT)...${NC}"
        if [ -n "$TS_HTTPS_ARG" ]; then
            tailscale funnel --bg $TS_HTTPS_ARG "http://localhost:$PORT" 2>/dev/null || true
        else
            tailscale funnel --bg "http://localhost:$PORT" 2>/dev/null || true
        fi

        # 等待 Funnel 啟動
        sleep 3

        # 驗證 Funnel 狀態
        FUNNEL_CHECK=$(tailscale funnel status 2>/dev/null || echo "")
        if echo "$FUNNEL_CHECK" | grep -q "localhost:$PORT"; then
            echo -e "   ${GREEN}- Funnel 配置成功${NC}"
        else
            echo -e "   ${RED}- Funnel 配置失敗${NC}"
            echo -e "   ${YELLOW}- 故障排除：${NC}"
            echo -e "     - 檢查 Tailscale 狀態：tailscale status"
            echo -e "     - 手動配置：tailscale funnel --bg http://localhost:$PORT"
            exit 1
        fi
    else
        echo -e "   ${GREEN}- Funnel 已在運行中${NC}"
    fi

    # 提取訪問 URL
    FUNNEL_STATUS=$(tailscale funnel status 2>/dev/null || echo "")
    PUBLIC_URL=$(echo "$FUNNEL_STATUS" | grep -oE 'https://[^ ]+\.ts\.net[^ ]*' | head -1 || true)

    # 步驟 6: 創建 Runner 腳本
    echo -e "\n${YELLOW}6. 正在創建 Runner 腳本...${NC}"
    mkdir -p "$SCRIPTS_HOME_DIR"

    cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/bin/bash
# start-claude-code-ui-funnel.sh
# Auto-generated by setup-tailscale-funnel.sh
# Starts Claude Code UI server and Tailscale Funnel

# Load nvm if available (needed for launchd which has minimal PATH)
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

REPO_ROOT="$REPO_ROOT"
LOG_FILE="$LOG_FILE"
PORT="$PORT"
TS_HTTPS_ARG="$TS_HTTPS_ARG"

# Ensure we're in the project directory
cd "\$REPO_ROOT"

# Timestamp
TIMESTAMP=\$(date "+%Y-%m-%d %H:%M:%S")
echo "" >> "\$LOG_FILE"
echo "=== [\$TIMESTAMP] Starting Claude Code UI + Tailscale Funnel ===" >> "\$LOG_FILE"

# Start Express server in background
echo "Starting server (npm run server)..." >> "\$LOG_FILE"
npm run server >> "\$LOG_FILE.server.out" 2>> "\$LOG_FILE.server.err" &
SERVER_PID=\$!
echo "Server started (PID: \$SERVER_PID)" >> "\$LOG_FILE"

# Wait for server to initialize
sleep 5

# Start Tailscale Funnel (idempotent - checks if already running)
echo "Checking Tailscale Funnel..." >> "\$LOG_FILE"
if ! tailscale funnel status 2>/dev/null | grep -q "localhost:\$PORT"; then
    echo "Starting Tailscale Funnel on port \$PORT..." >> "\$LOG_FILE"
    if [ -n "\$TS_HTTPS_ARG" ]; then
        tailscale funnel --bg \$TS_HTTPS_ARG "http://localhost:\$PORT" 2>/dev/null || true
    else
        tailscale funnel --bg "http://localhost:\$PORT" 2>/dev/null || true
    fi
    echo "Funnel started" >> "\$LOG_FILE"
else
    echo "Funnel already running, skipping" >> "\$LOG_FILE"
fi

echo "=== Startup complete ===" >> "\$LOG_FILE"

# Wait for server process
wait \$SERVER_PID
RUNNER_EOF

    chmod +x "$RUNNER_SCRIPT"
    echo -e "   ${GREEN}- 已創建 runner 腳本${NC}"
    echo -e "   ${GRAY}- 位置：$RUNNER_SCRIPT${NC}"

    # 步驟 7: 創建 macOS LaunchAgent
    echo -e "\n${YELLOW}7. 正在配置 macOS LaunchAgent...${NC}"
    mkdir -p "$HOME/Library/LaunchAgents"

    # Detect node bin directory for PATH
    NODE_BIN_DIR=$(dirname "$(command -v node)")

    cat > "$PLIST_FILE" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${RUNNER_SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}.launchd.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}.launchd.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${NODE_BIN_DIR}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

    # 卸載舊的（如果存在）再載入新的
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE" 2>/dev/null || launchctl load "$PLIST_FILE" 2>/dev/null || true

    echo -e "   ${GREEN}- 已創建並載入 LaunchAgent 配置${NC}"
    echo -e "   ${GRAY}- 位置：$PLIST_FILE${NC}"

    # 步驟 8: 顯示結果
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Claude Code UI + Tailscale Funnel 自動啟動設置完成！  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}配置信息：${NC}"
    echo -e "   - 專案目錄：$REPO_ROOT"
    echo -e "   - 本地端口：$PORT"
    echo -e "   - Runner 腳本：$RUNNER_SCRIPT"
    echo -e "   - Log 檔案：$LOG_FILE"
    if [ -n "$PUBLIC_URL" ]; then
        echo -e "   - 公網 URL：$PUBLIC_URL"
    fi
    echo ""
    echo -e "${CYAN}後續步驟：${NC}"
    echo ""
    echo -e "${YELLOW}1. 立即啟動服務（不用等重開機）：${NC}"
    echo -e "   launchctl kickstart gui/\$(id -u)/$PLIST_LABEL"
    echo -e "   ${GRAY}# 或在背景執行：nohup bash \"$RUNNER_SCRIPT\" &>/dev/null &${NC}"
    echo ""
    echo -e "${YELLOW}2. 驗證服務運行狀態：${NC}"
    echo -e "   ./setup-tailscale-funnel.sh verify"
    echo ""
    echo -e "${YELLOW}3. 重開機後自動啟動：${NC}"
    echo -e "   已配置 macOS LaunchAgent，無需手動操作"
    echo ""
    echo -e "${CYAN}提示：${NC}"
    echo -e "   - 查看 log：tail -20 \"$LOG_FILE\""
    echo -e "   - Funnel 狀態：tailscale funnel status"
    echo -e "   - 移除配置：./setup-tailscale-funnel.sh remove"
    echo -e "   - 強制重裝：./setup-tailscale-funnel.sh install --force"
    echo ""
    echo -e "${CYAN}vs ngrok 的優勢：${NC}"
    echo -e "   - 完全免費（不需要 authtoken 或付費方案）"
    echo -e "   - 固定 URL（*.ts.net，不會每次變動）"
    echo -e "   - 無 endpoint 數量限制"
    exit 0
fi
