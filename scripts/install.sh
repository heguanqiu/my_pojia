#!/usr/bin/env bash
# Codex Session Patcher one-click installer.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
BIN_DIR="$HOME/.local/bin"
INSTALL_MODE="ask"
ASSUME_YES=0
START_AFTER_INSTALL=0
SKIP_FRONTEND_BUILD=0
UPDATE_PATH=1

if [ -t 1 ]; then
    COLOR_RESET="$(printf '\033[0m')"
    COLOR_BLUE="$(printf '\033[34m')"
    COLOR_GREEN="$(printf '\033[32m')"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_RED="$(printf '\033[31m')"
else
    COLOR_RESET=""
    COLOR_BLUE=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
fi

log_step() {
    printf '\n%s==>%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

log_ok() {
    printf '%s[OK]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

die() {
    log_error "$1"
    exit 1
}

usage() {
    cat <<'EOF'
Codex Session Patcher 一键安装脚本

用法:
  ./scripts/install.sh              交互式安装（推荐）
  ./scripts/install.sh --web        安装 CLI + Web UI
  ./scripts/install.sh --cli        只安装 CLI
  ./scripts/install.sh --yes --web  使用默认选项自动安装 Web UI

选项:
  --web                  安装 CLI + Web UI（需要 Node.js/npm）
  --cli                  只安装 CLI
  -y, --yes              对提示使用默认答案
  --start                安装完成后立即启动 Web UI（仅 Web 模式）
  --skip-frontend-build  跳过前端 npm install/build
  --no-path              不自动写入 ~/.bashrc 或 ~/.zshrc
  -h, --help             显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --web)
            INSTALL_MODE="web"
            ;;
        --cli)
            INSTALL_MODE="cli"
            ;;
        -y|--yes)
            ASSUME_YES=1
            ;;
        --start)
            START_AFTER_INSTALL=1
            ;;
        --skip-frontend-build)
            SKIP_FRONTEND_BUILD=1
            ;;
        --no-path)
            UPDATE_PATH=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数: $1。运行 ./scripts/install.sh --help 查看用法。"
            ;;
    esac
    shift
done

ask_yes_no() {
    local question="$1"
    local default_answer="$2"
    local answer
    local hint

    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        [ "$default_answer" = "y" ]
        return
    fi

    if [ "$default_answer" = "y" ]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    while true; do
        read -r -p "$question [$hint]: " answer
        answer="${answer:-$default_answer}"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf '请输入 y 或 n。\n' ;;
        esac
    done
}

choose_install_mode() {
    if [ "$INSTALL_MODE" != "ask" ]; then
        return
    fi

    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        INSTALL_MODE="web"
        return
    fi

    printf '\n请选择安装内容:\n'
    printf '  1) Web UI + CLI（推荐，图形界面，适合新手）\n'
    printf '  2) 只安装 CLI（命令行，依赖更少）\n'

    local choice
    while true; do
        read -r -p "请输入 1 或 2 [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) INSTALL_MODE="web"; return ;;
            2) INSTALL_MODE="cli"; return ;;
            *) printf '请输入 1 或 2。\n' ;;
        esac
    done
}

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python)"
    else
        die "未找到 Python。请先安装 Python 3.8 或更高版本。"
    fi
}

check_python_version() {
    "$PYTHON_BIN" - <<'PY'
import sys
if sys.version_info < (3, 8):
    raise SystemExit(1)
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
PY
}

ensure_python() {
    log_step "检查 Python"
    find_python

    local version
    if ! version="$(check_python_version)"; then
        die "Python 版本过低。当前命令是 $PYTHON_BIN，需要 Python 3.8 或更高版本。"
    fi

    log_ok "Python: $PYTHON_BIN ($version)"

    if ! "$PYTHON_BIN" -m venv --help >/dev/null 2>&1; then
        die "当前 Python 缺少 venv 模块。Ubuntu/Debian 可运行: sudo apt install python3-venv"
    fi
}

ensure_node_for_web() {
    if [ "$INSTALL_MODE" != "web" ] || [ "$SKIP_FRONTEND_BUILD" -eq 1 ]; then
        return
    fi

    log_step "检查 Node.js 和 npm"
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        log_warn "Web UI 前端构建需要 Node.js 和 npm。"
        printf '安装建议:\n'
        printf '  macOS: brew install node\n'
        printf '  Ubuntu/Debian: sudo apt install nodejs npm\n'
        printf '  Windows/WSL: https://nodejs.org 下载 LTS 版本\n'

        if ask_yes_no "没有 Node.js/npm，是否改为只安装 CLI" "y"; then
            INSTALL_MODE="cli"
            return
        fi
        die "缺少 Node.js/npm，无法继续安装 Web UI。"
    fi

    log_ok "Node.js: $(node --version)"
    log_ok "npm: $(npm --version)"
}

create_venv() {
    log_step "准备 Python 虚拟环境"
    if [ ! -d "$VENV_DIR" ]; then
        if ! "$PYTHON_BIN" -m venv "$VENV_DIR"; then
            die "虚拟环境创建失败。Ubuntu/Debian 可运行: sudo apt install python3-venv；如果仍失败，请安装与你的 Python 版本匹配的包，例如 sudo apt install python3.12-venv"
        fi
        log_ok "已创建 $VENV_DIR"
    else
        log_ok "复用已有 $VENV_DIR"
    fi

    VENV_PYTHON="$VENV_DIR/bin/python"

    [ -x "$VENV_PYTHON" ] || die "虚拟环境异常，找不到 $VENV_PYTHON"

    "$VENV_PYTHON" -m pip --version >/dev/null 2>&1 || {
        "$VENV_PYTHON" -m ensurepip --upgrade >/dev/null 2>&1 || die "无法启用 pip，请检查 Python 安装。"
    }
}

install_python_package() {
    log_step "安装 Python 包"
    local package_spec
    local success_message

    if [ "$INSTALL_MODE" = "web" ]; then
        package_spec="$PROJECT_DIR[web]"
        success_message="已安装 CLI + Web 后端依赖"
    else
        package_spec="$PROJECT_DIR"
        success_message="已安装 CLI"
    fi

    if ! "$VENV_PYTHON" -m pip install --no-build-isolation -e "$package_spec"; then
        log_warn "离线安装方式失败，改用标准 pip 安装方式重试。"
        "$VENV_PYTHON" -m pip install -e "$package_spec"
    fi

    log_ok "$success_message"
}

build_frontend() {
    if [ "$INSTALL_MODE" != "web" ] || [ "$SKIP_FRONTEND_BUILD" -eq 1 ]; then
        return
    fi

    log_step "安装并构建 Web UI 前端"
    cd "$PROJECT_DIR/web/frontend"

    if [ -f package-lock.json ]; then
        npm ci
    else
        npm install
    fi

    npm run build
    log_ok "Web UI 前端构建完成"
}

write_launcher() {
    local target="$1"
    local content="$2"

    mkdir -p "$BIN_DIR"
    printf '%s\n' "$content" > "$target"
    chmod +x "$target"
}

install_launchers() {
    log_step "创建启动命令"

    write_launcher "$BIN_DIR/codex-patcher" "#!/usr/bin/env bash
exec \"$VENV_DIR/bin/codex-patcher\" \"\$@\""
    log_ok "已创建 $BIN_DIR/codex-patcher"

    if [ "$INSTALL_MODE" = "web" ]; then
        write_launcher "$BIN_DIR/codex-patcher-web" "#!/usr/bin/env bash
cd \"$PROJECT_DIR\"
exec \"$VENV_DIR/bin/python\" -m uvicorn web.backend.main:app --host 127.0.0.1 --port 8080 \"\$@\""
        log_ok "已创建 $BIN_DIR/codex-patcher-web"
    fi
}

detect_shell_rc() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        zsh) printf '%s/.zshrc' "$HOME" ;;
        bash) printf '%s/.bashrc' "$HOME" ;;
        *) printf '%s/.profile' "$HOME" ;;
    esac
}

ensure_path() {
    if [ "$UPDATE_PATH" -eq 0 ]; then
        return
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*)
            log_ok "$BIN_DIR 已在 PATH 中"
            return
            ;;
    esac

    local rc_file
    rc_file="$(detect_shell_rc)"

    if ask_yes_no "是否把 $BIN_DIR 加入 PATH（以后可直接输入 codex-patcher）" "y"; then
        mkdir -p "$(dirname "$rc_file")"
        touch "$rc_file"
        if ! grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$rc_file" >/dev/null 2>&1; then
            {
                printf '\n# Codex Session Patcher\n'
                printf 'export PATH="$HOME/.local/bin:$PATH"\n'
            } >> "$rc_file"
        fi
        export PATH="$BIN_DIR:$PATH"
        log_ok "已写入 $rc_file"
    else
        log_warn "$BIN_DIR 不在 PATH 中。你仍可用完整路径运行: $BIN_DIR/codex-patcher"
    fi
}

print_summary() {
    printf '\n%s安装完成%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    printf '项目目录: %s\n' "$PROJECT_DIR"
    printf '虚拟环境: %s\n' "$VENV_DIR"
    printf '\n常用命令:\n'
    printf '  codex-patcher --help\n'
    printf '  codex-patcher --latest\n'
    printf '  codex-patcher --ctf-status\n'

    if [ "$INSTALL_MODE" = "web" ]; then
        printf '  codex-patcher-web\n'
        printf '\nWeb UI 地址: http://127.0.0.1:8080\n'
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            printf '\n当前终端还未加载 PATH 时，可先运行:\n'
            printf '  export PATH="$HOME/.local/bin:$PATH"\n'
            ;;
    esac
}

main() {
    printf 'Codex Session Patcher 一键安装\n'
    printf '项目目录: %s\n' "$PROJECT_DIR"

    choose_install_mode
    ensure_python
    ensure_node_for_web
    create_venv
    install_python_package
    build_frontend
    install_launchers
    ensure_path
    print_summary

    if [ "$INSTALL_MODE" = "web" ] && [ "$START_AFTER_INSTALL" -eq 1 ]; then
        log_step "启动 Web UI"
        exec "$BIN_DIR/codex-patcher-web"
    fi
}

main "$@"
