#!/bin/bash
#
# Setup Claude Code UI with ngrok tunnel for auto-start on Linux boot
#
# Configures Claude Code UI (Express server + ngrok tunnel) to start automatically
# when the user logs in via systemd user service.
#
# This is a user-level script that does NOT require root privileges.
#
# Requirements:
#   - Node.js and npm must be installed
#   - NGROK_AUTHTOKEN must be set in the project .env file
#   - npm dependencies must be installed (npm install)
#   - systemd with user session support (most modern distros)
#
# Usage:
#   ./setup-ngrok-tunnel.sh install          Build and configure auto-start
#   ./setup-ngrok-tunnel.sh install --force   Force reconfiguration
#   ./setup-ngrok-tunnel.sh verify           Verify services are running
#   ./setup-ngrok-tunnel.sh remove           Remove auto-start configuration
#   ./setup-ngrok-tunnel.sh remove -y        Remove without confirmation
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
RUNNER_SCRIPT="$HOME/Scripts/start-claude-code-ui-ngrok.sh"
LOG_FILE="$HOME/Scripts/claude-code-ui-ngrok.log"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="claude-code-ui-ngrok"
SERVICE_FILE="$SYSTEMD_DIR/${SERVICE_NAME}.service"
SCRIPTS_HOME_DIR="$HOME/Scripts"

echo -e "${CYAN}--- Claude Code UI + ngrok Tunnel 設置腳本 (Linux) ---${NC}"

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
    echo -e "   ./setup-ngrok-tunnel.sh install"
    echo -e "   ./setup-ngrok-tunnel.sh verify"
    echo -e "   ./setup-ngrok-tunnel.sh remove"
    exit 1
fi

# =============================================================================
# === 驗證操作 ===
# =============================================================================
if [ "$ACTION" = "verify" ]; then
    echo -e "\n${CYAN}=== 開始驗證服務 ===${NC}"

    ALL_GOOD=true

    # 檢查 node server 進程
    echo -e "\n${YELLOW}1. 檢查 Node.js server 進程...${NC}"
    NODE_PIDS=$(pgrep -f "node.*server" 2>/dev/null || true)
    if [ -n "$NODE_PIDS" ]; then
        echo -e "   ${GREEN}- Node.js 進程運行中 (PID: $(echo $NODE_PIDS | tr '\n' ', ' | sed 's/,$//' ))${NC}"
    else
        echo -e "   ${RED}- 未找到 Node.js server 進程${NC}"
        ALL_GOOD=false
    fi

    # 檢查 ngrok 進程
    echo -e "\n${YELLOW}2. 檢查 ngrok 進程...${NC}"
    NGROK_PIDS=$(pgrep -f "ngrok" 2>/dev/null || true)
    if [ -n "$NGROK_PIDS" ]; then
        echo -e "   ${GREEN}- ngrok 進程運行中 (PID: $(echo $NGROK_PIDS | tr '\n' ', ' | sed 's/,$//' ))${NC}"
    else
        echo -e "   ${GRAY}- 未找到獨立 ngrok 進程（ngrok SDK 透過 Node.js 運行，這可能是正常的）${NC}"
    fi

    # 嘗試 HTTP 請求 localhost:3001/health
    echo -e "\n${YELLOW}3. 檢查 HTTP 服務 (localhost:3001)...${NC}"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:3001/health" 2>/dev/null || echo "000")
    if [ "$HTTP_STATUS" = "200" ]; then
        echo -e "   ${GREEN}- HTTP 服務正常 (status: $HTTP_STATUS)${NC}"
    else
        echo -e "   ${RED}- HTTP 服務無法連線 (status: $HTTP_STATUS)${NC}"
        ALL_GOOD=false
    fi

    # 檢查 ngrok tunnel 狀態（透過 ngrok API）
    echo -e "\n${YELLOW}4. 檢查 ngrok tunnel 狀態...${NC}"
    TUNNEL_RESPONSE=$(curl -s --connect-timeout 5 "http://localhost:4040/api/tunnels" 2>/dev/null || echo "")
    if [ -n "$TUNNEL_RESPONSE" ]; then
        TUNNEL_COUNT=$(echo "$TUNNEL_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('tunnels',[])))" 2>/dev/null || echo "0")
        if [ "$TUNNEL_COUNT" -gt 0 ]; then
            echo "$TUNNEL_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('tunnels', []):
    print(f'   - Tunnel: {t[\"public_url\"]} -> {t[\"config\"][\"addr\"]}')
" 2>/dev/null || true
        else
            echo -e "   ${YELLOW}- 未找到活躍 tunnel${NC}"
            ALL_GOOD=false
        fi
    else
        echo -e "   ${GRAY}- 無法查詢 ngrok API（ngrok SDK 模式可能不提供 4040 API）${NC}"
        echo -e "   ${GRAY}- 如果 HTTP 服務正常，tunnel 很可能也在運行${NC}"
    fi

    # 檢查 runner 腳本和 systemd service
    echo -e "\n${YELLOW}5. 檢查啟動配置...${NC}"
    if [ -f "$RUNNER_SCRIPT" ]; then
        echo -e "   ${GREEN}- Runner 腳本存在${NC}"
    else
        echo -e "   ${RED}- Runner 腳本不存在：$RUNNER_SCRIPT${NC}"
        ALL_GOOD=false
    fi

    if [ -f "$SERVICE_FILE" ]; then
        echo -e "   ${GREEN}- systemd service 配置存在${NC}"
        # 檢查是否已啟用
        if systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null; then
            echo -e "   ${GREEN}- systemd service 已啟用${NC}"
        else
            echo -e "   ${YELLOW}- systemd service 未啟用${NC}"
        fi
        # 檢查是否正在運行
        if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
            echo -e "   ${GREEN}- systemd service 運行中${NC}"
        else
            echo -e "   ${YELLOW}- systemd service 未運行${NC}"
        fi
    else
        echo -e "   ${RED}- systemd service 配置不存在：$SERVICE_FILE${NC}"
        ALL_GOOD=false
    fi

    # 檢查 log 檔案
    echo -e "\n${YELLOW}6. 檢查 log 檔案...${NC}"
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(du -h "$LOG_FILE" | cut -f1)
        LOG_DATE=$(stat -c "%y" "$LOG_FILE" 2>/dev/null | cut -d. -f1 || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LOG_FILE" 2>/dev/null)
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
    echo -e "\n${CYAN}=== 開始移除 Claude Code UI 自動啟動配置 ===${NC}"

    # 確認操作
    if [ "$NON_INTERACTIVE" = false ]; then
        echo ""
        echo -e "${YELLOW}此操作將移除：${NC}"
        echo -e "   - Runner 腳本 (start-claude-code-ui-ngrok.sh)"
        echo -e "   - systemd user service"
        echo -e "   - Log 檔案"
        echo ""
        read -rp "   確定要繼續嗎？(Y/N) " CONFIRM
        if [[ "$CONFIRM" != "Y" && "$CONFIRM" != "y" ]]; then
            echo -e "   ${YELLOW}- 已取消操作${NC}"
            exit 0
        fi
    fi

    # 停止 systemd service
    echo -e "\n${YELLOW}1. 正在停止服務...${NC}"
    if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        echo -e "   ${GREEN}- 已停止 systemd service${NC}"
    fi
    if systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null; then
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        echo -e "   ${GREEN}- 已禁用 systemd service${NC}"
    fi

    NODE_PIDS=$(pgrep -f "node.*server" 2>/dev/null || true)
    if [ -n "$NODE_PIDS" ]; then
        echo -e "   ${GRAY}- 發現 Node.js 進程，但不自動終止（可能有其他 Node 應用）${NC}"
        echo -e "   ${GRAY}- 如需手動停止，請執行：kill $NODE_PIDS${NC}"
    else
        echo -e "   ${GRAY}- 沒有運行中的 Node.js server 進程${NC}"
    fi

    # 刪除腳本
    echo -e "\n${YELLOW}2. 正在刪除腳本...${NC}"
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
    for f in "$LOG_FILE.server.out" "$LOG_FILE.server.err" "$LOG_FILE.ngrok.out" "$LOG_FILE.ngrok.err"; do
        [ -f "$f" ] && rm -f "$f"
    done

    # 刪除 systemd service
    echo -e "\n${YELLOW}3. 正在刪除 systemd service...${NC}"
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        systemctl --user daemon-reload 2>/dev/null || true
        echo -e "   ${GREEN}- 已刪除 systemd service 配置${NC}"
    else
        echo -e "   ${GRAY}- systemd service 配置不存在，跳過${NC}"
    fi

    echo ""
    echo -e "${GREEN}移除完成！${NC}"
    exit 0
fi

# =============================================================================
# === 安裝操作 ===
# =============================================================================
if [ "$ACTION" = "install" ]; then
    echo -e "\n${CYAN}=== 開始設置 Claude Code UI 自動啟動 ===${NC}"

    # 步驟 1: 檢查前置條件
    echo -e "\n${YELLOW}1. 正在檢查前置條件...${NC}"

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

    # 讀取 NGROK_AUTHTOKEN
    AUTHTOKEN=$(read_env_value "NGROK_AUTHTOKEN" "$ENV_FILE")
    if [ -z "$AUTHTOKEN" ]; then
        echo -e "   ${RED}- .env 中未設定 NGROK_AUTHTOKEN${NC}"
        echo -e "   ${YELLOW}- 請在 .env 中設定你的 ngrok authtoken${NC}"
        echo -e "   ${YELLOW}- 取得 authtoken：https://dashboard.ngrok.com/signup${NC}"
        exit 1
    fi
    if [ "$AUTHTOKEN" = "your_authtoken_here" ]; then
        echo -e "   ${RED}- NGROK_AUTHTOKEN 尚未設定（仍為預設值）${NC}"
        echo -e "   ${YELLOW}- 請在 .env 中填入你的 ngrok authtoken${NC}"
        exit 1
    fi
    echo -e "   ${GREEN}- NGROK_AUTHTOKEN 已設定${NC}"

    # 讀取 NGROK_DOMAIN（可選）
    NGROK_DOMAIN=$(read_env_value "NGROK_DOMAIN" "$ENV_FILE")
    if [ -n "$NGROK_DOMAIN" ]; then
        echo -e "   ${GREEN}- NGROK_DOMAIN: $NGROK_DOMAIN${NC}"
    fi

    # 讀取 PORT
    PORT=$(read_env_value "PORT" "$ENV_FILE")
    PORT="${PORT:-3001}"
    echo -e "   ${GRAY}- 端口配置：$PORT${NC}"

    # 檢查是否已安裝且不強制
    if [ -f "$RUNNER_SCRIPT" ] && [ -f "$SERVICE_FILE" ] && [ "$FORCE" = false ]; then
        echo ""
        echo -e "${GREEN}已檢測到現有安裝配置${NC}"
        echo -e "   ${GRAY}- Runner 腳本：$RUNNER_SCRIPT${NC}"
        echo -e "   ${GRAY}- systemd service：$SERVICE_FILE${NC}"
        echo ""
        echo -e "${YELLOW}如需重新配置，請使用 --force 參數：${NC}"
        echo -e "   ./setup-ngrok-tunnel.sh install --force"
        exit 0
    fi

    # 步驟 2: 建置前端
    echo -e "\n${YELLOW}2. 正在建置前端 (npm run build)...${NC}"
    cd "$REPO_ROOT"
    if npm run build > /dev/null 2>&1; then
        echo -e "   ${GREEN}- 前端建置成功${NC}"
    else
        echo -e "   ${RED}- 前端建置失敗${NC}"
        exit 1
    fi

    # 步驟 3: 創建 Runner 腳本
    echo -e "\n${YELLOW}3. 正在創建 Runner 腳本...${NC}"
    mkdir -p "$SCRIPTS_HOME_DIR"

    # Detect node/npm paths for systemd
    NODE_PATH=$(command -v node)
    NPM_PATH=$(command -v npm)
    NODE_BIN_DIR=$(dirname "$NODE_PATH")

    cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/bin/bash
# start-claude-code-ui-ngrok.sh
# Auto-generated by setup-ngrok-tunnel.sh
# Starts Claude Code UI server and ngrok tunnel

# Load nvm if available (needed for systemd which has minimal PATH)
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
export PATH="$NODE_BIN_DIR:\$PATH"

REPO_ROOT="$REPO_ROOT"
LOG_FILE="$LOG_FILE"

# Ensure we're in the project directory
cd "\$REPO_ROOT"

# Timestamp
TIMESTAMP=\$(date "+%Y-%m-%d %H:%M:%S")
echo "" >> "\$LOG_FILE"
echo "=== [\$TIMESTAMP] Starting Claude Code UI ===" >> "\$LOG_FILE"

# Start Express server in background
echo "Starting server (npm run server)..." >> "\$LOG_FILE"
npm run server >> "\$LOG_FILE.server.out" 2>> "\$LOG_FILE.server.err" &
SERVER_PID=\$!
echo "Server started (PID: \$SERVER_PID)" >> "\$LOG_FILE"

# Wait a moment for server to initialize
sleep 5

# Start ngrok tunnel in background
echo "Starting ngrok tunnel (npm run ngrok)..." >> "\$LOG_FILE"
npm run ngrok >> "\$LOG_FILE.ngrok.out" 2>> "\$LOG_FILE.ngrok.err" &
NGROK_PID=\$!
echo "ngrok started (PID: \$NGROK_PID)" >> "\$LOG_FILE"

echo "=== Startup complete ===" >> "\$LOG_FILE"

# Wait for all background processes
wait
RUNNER_EOF

    chmod +x "$RUNNER_SCRIPT"
    echo -e "   ${GREEN}- 已創建 runner 腳本${NC}"
    echo -e "   ${GRAY}- 位置：$RUNNER_SCRIPT${NC}"

    # 步驟 4: 創建 systemd user service
    echo -e "\n${YELLOW}4. 正在配置 systemd user service...${NC}"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=Claude Code UI + ngrok Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${RUNNER_SCRIPT}
WorkingDirectory=${REPO_ROOT}
Restart=on-failure
RestartSec=10
Environment=PATH=${NODE_BIN_DIR}:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SERVICE_EOF

    # 重新載入 systemd 並啟用服務
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME" 2>/dev/null || true
    echo -e "   ${GREEN}- 已創建並啟用 systemd service${NC}"
    echo -e "   ${GRAY}- 位置：$SERVICE_FILE${NC}"

    # 啟用 lingering 以便在使用者未登入時也能運行
    if command -v loginctl &>/dev/null; then
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
        echo -e "   ${GRAY}- 已啟用 loginctl linger（允許開機自動運行）${NC}"
    fi

    # 步驟 5: 顯示結果
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Claude Code UI 自動啟動設置完成！                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}配置信息：${NC}"
    echo -e "   - 專案目錄：$REPO_ROOT"
    echo -e "   - 本地端口：$PORT"
    echo -e "   - Runner 腳本：$RUNNER_SCRIPT"
    echo -e "   - Log 檔案：$LOG_FILE"
    if [ -n "$NGROK_DOMAIN" ]; then
        echo -e "   - ngrok Domain：$NGROK_DOMAIN"
        echo -e "   - 訪問 URL：https://$NGROK_DOMAIN"
    else
        echo -e "   ${GRAY}- ngrok Domain：（隨機，每次啟動不同）${NC}"
    fi
    echo ""
    echo -e "${CYAN}後續步驟：${NC}"
    echo ""
    echo -e "${YELLOW}1. 立即啟動服務（不用等重開機）：${NC}"
    echo -e "   systemctl --user start $SERVICE_NAME"
    echo ""
    echo -e "${YELLOW}2. 驗證服務運行狀態：${NC}"
    echo -e "   ./setup-ngrok-tunnel.sh verify"
    echo ""
    echo -e "${YELLOW}3. 重開機後自動啟動：${NC}"
    echo -e "   已配置 systemd user service，無需手動操作"
    echo ""
    echo -e "${CYAN}提示：${NC}"
    echo -e "   - 查看 log：tail -20 \"$LOG_FILE\""
    echo -e "   - 查看 service log：journalctl --user -u $SERVICE_NAME"
    echo -e "   - 移除配置：./setup-ngrok-tunnel.sh remove"
    echo -e "   - 強制重裝：./setup-ngrok-tunnel.sh install --force"
    exit 0
fi
