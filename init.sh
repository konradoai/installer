#!/bin/bash
set -e
export PATH="/usr/local/bin:$PATH"

# ---------------------------------------------------------------------------
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/konradoai/installer/main/init.sh) \
#       --api-key=<konrado_api_key> \
#       --callback-url=<https://app.konrado.ai/api/integrations/servers/install>
#
# Or via custom domain (if configured):
#   bash <(curl -s https://repo.konrado.ai/init.sh) \
#       --api-key=<konrado_api_key> \
#       --callback-url=<https://app.konrado.ai/api/integrations/servers/install>
#
# Optional:
#   --server-url=<http://your-public-ip:8001>   override auto-detected URL
#   --port=<8001>                                override default proxy port
# ---------------------------------------------------------------------------

# Function to check python version (>= 3.10)
check_python_version() {
    local exe="$1"
    ver="$("$exe" -c 'import sys; v=sys.version_info; print(f"{v.major}.{v.minor}")')" 2>/dev/null
    if [[ -n "$ver" ]]; then
        if [[ "$(printf '%s\n' "$ver" "3.10" | sort -V | head -n1)" == "3.10" ]]; then
            echo "$exe"
            return 0
        fi
    fi
    return 1
}

# Find and return the best python executable (3.10+)
get_python() {
    for exe in python3.12 python3.11 python311 "/opt/alt/python311/bin/python3" python3.10 python3; do
        py_path=$(command -v "$exe" 2>/dev/null)
        if [[ -n "$py_path" ]]; then
            found=$(check_python_version "$py_path" 2>/dev/null)
            if [[ -n "$found" ]]; then
                echo "$found"
                return 0
            fi
        fi
    done
    echo "Error: Python 3.10 or newer is required." >&2
    return 1
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
if ! command -v curl &> /dev/null; then
    echo "curl is not installed. Please install curl and try again."
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "unzip is not installed. Please install unzip and try again."
    exit 1
fi

if ! command -v systemctl &> /dev/null; then
    echo "systemd is not installed. Please install systemd and try again."
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
API_KEY=""
CALLBACK_URL=""
SERVER_URL=""
PORT=""

for arg in "$@"; do
    case $arg in
        --api-key=*)        API_KEY="${arg#*=}" ;;
        --callback-url=*)   CALLBACK_URL="${arg#*=}" ;;
        --server-url=*)     SERVER_URL="${arg#*=}" ;;
        --port=*)           PORT="${arg#*=}" ;;
    esac
done

if [[ -z "$API_KEY" || -z "$CALLBACK_URL" ]]; then
    echo "Error: --api-key and --callback-url are required."
    echo ""
    echo "Usage:"
    echo "  bash <(curl -s https://repo.konrado.ai/init.sh) \\"
    echo "      --api-key=<konrado_api_key> \\"
    echo "      --callback-url=<https://app.konrado.ai/api/integrations/servers/install>"
    exit 1
fi

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
if [ -f /usr/sbin/plesk ]; then
    PLATFORM="plesk"
elif [ -d /usr/local/directadmin ]; then
    PLATFORM="directadmin"
elif [ -d /usr/local/cpanel ]; then
    PLATFORM="cpanel"
else
    PLATFORM="linux"
fi

echo "Detected platform: $PLATFORM"

# ---------------------------------------------------------------------------
# System user / group
# ---------------------------------------------------------------------------
if ! getent group proxy-mcp >/dev/null 2>&1; then
    echo "Creating group 'proxy-mcp'..."
    groupadd --system proxy-mcp
else
    echo "Group 'proxy-mcp' already exists."
fi

if ! getent passwd proxy-mcp >/dev/null 2>&1; then
    echo "Creating user 'proxy-mcp'..."
    useradd --system -g proxy-mcp --home-dir /opt/ProxyMcp --shell /bin/bash --create-home proxy-mcp
else
    echo "User 'proxy-mcp' already exists."
fi

if ! groups proxy-mcp | grep -q proxy-mcp; then
    usermod -a -G proxy-mcp proxy-mcp
fi

# ---------------------------------------------------------------------------
# Python virtualenv
# ---------------------------------------------------------------------------
PYTHON_EXE=$(get_python)
if [[ -z "$PYTHON_EXE" ]]; then
    exit 1
fi
echo "Using Python: $PYTHON_EXE"

"$PYTHON_EXE" -m venv /opt/ProxyMcp/.venv

chmod -R 750 /opt/ProxyMcp/
chown -R proxy-mcp:proxy-mcp /opt/ProxyMcp/

cd /opt/ProxyMcp/
source /opt/ProxyMcp/.venv/bin/activate

# ---------------------------------------------------------------------------
# Install package
# ---------------------------------------------------------------------------
pip install -U pip

pip install --no-cache-dir --force-reinstall \
    --extra-index-url http://repo.konrado.ai:3141/konrado/dev/ \
    --trusted-host repo.konrado.ai \
    ProxyMcp

# ---------------------------------------------------------------------------
# Unpack scripts / data
# ---------------------------------------------------------------------------
proxy-mcp-unpack-data

# ---------------------------------------------------------------------------
# Auto-configure .env (generates API_KEY, sets defaults — non-interactive)
# ---------------------------------------------------------------------------
proxy-mcp-configure-env --auto

# Override port in .env if --port was provided on command line
if [[ -n "$PORT" ]]; then
    if grep -q "^SERVER_PORT=" .env 2>/dev/null; then
        sed -i "s|^SERVER_PORT=.*|SERVER_PORT=$PORT|" .env
    else
        echo "SERVER_PORT=$PORT" >> .env
    fi
fi

# ---------------------------------------------------------------------------
# Interactive configuration — user fills in server settings
# Current .env values are shown as defaults; just press Enter to keep them.
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Configure Proxy MCP settings"
echo " (Press Enter to keep the current value)"
echo "============================================"
proxy-mcp-configure-env

# ---------------------------------------------------------------------------
# Install and start systemd service
# ---------------------------------------------------------------------------
bash /opt/ProxyMcp/scripts/install.sh

# ---------------------------------------------------------------------------
# Register integration with Konrado.AI backend
# ---------------------------------------------------------------------------
CONNECT_ARGS=(
    "--api-key=$API_KEY"
    "--callback-url=$CALLBACK_URL"
)

if [[ -n "$SERVER_URL" ]]; then
    CONNECT_ARGS+=("--server-url=$SERVER_URL")
fi

if [[ -n "$PORT" ]]; then
    CONNECT_ARGS+=("--port=$PORT")
fi

proxy-mcp-connect "${CONNECT_ARGS[@]}"

# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Proxy MCP installed successfully"
echo " Platform : $PLATFORM"
echo " Service  : proxy-mcp.service"
echo " Status   : $(systemctl is-active proxy-mcp.service 2>/dev/null || echo 'unknown')"
echo "============================================"
