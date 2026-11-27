#!/usr/bin/env bash
# ==============================================================================
#  GRIME Installer Script
#  Высокопроизводительный оркестратор разработки и системных сред
# ==============================================================================

set -euo pipefail

# Цветовая палитра для вывода
BOLD="$(printf '\033[1m')"
GREEN="$(printf '\033[0;32m')"
CYAN="$(printf '\033[0;36m')"
YELLOW="$(printf '\033[1;33m')"
RED="$(printf '\033[0;31m')"
DIM="$(printf '\033[2m')"
NC="$(printf '\033[0m')" # No Color

# Путь к каталогу самого скрипта / репозитория
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Значения по умолчанию
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/grime"
USE_SYMLINK=false
FORCE_BUILD=false
SETUP_HOOK=true
RUN_DOCTOR=true

# Вспомогательные функции логирования
log_info() {
    echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}▲ ВНИМАНИЕ:${NC} $*"
}

log_error() {
    echo -e "${RED}✗ ОШИБКА:${NC} $*" >&2
}

# Раскрытие тильды в путях
expand_path() {
    local p="$1"
    if [[ "$p" == "~"* ]]; then
        p="${p/#\~/$HOME}"
    fi
    echo "$p"
}

# Справочная информация
show_help() {
    cat << EOF
${BOLD}GRIME Installer${NC} — Автоматическая установка платформы GRIME (Rust Engine + Lua 5.4)

${BOLD}ИСПОЛЬЗОВАНИЕ:${NC}
    ./install.sh [ОПЦИИ]

${BOLD}ОПЦИИ:${NC}
    -h, --help            Вывод данной справочной информации
    -s, --symlink         Создавать символические ссылки на модули и шаблоны вместо копирования
                          (рекомендуется для разработчиков ядра и модулей)
    -b, --build           Принудительно собрать бинарники перед установкой (через cargo или nix)
        --bin-dir <DIR>   Каталог для установки исполняемых файлов (по умолчанию: ~/.local/bin)
        --config-dir <DIR> Каталог конфигурации GRIME (по умолчанию: ~/.config/grime)
        --no-doctor       Не запускать grime doctor в конце установки
        --no-hook         Пропустить настройку шелл-хуков command_not_found (Fish/Bash/Zsh)

${BOLD}ПРИМЕРЫ:${NC}
    ./install.sh                    # Стандартная установка
    ./install.sh --symlink          # Режим разработчика (симлинки на модули)
    ./install.sh --build            # Сборка из исходников и установка
    ./install.sh --bin-dir ~/bin    # Установка бинарников в альтернативный каталог
EOF
}

# Разбор аргументов командной строки
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--symlink)
            USE_SYMLINK=true
            shift
            ;;
        -b|--build)
            FORCE_BUILD=true
            shift
            ;;
        --no-hook)
            SETUP_HOOK=false
            shift
            ;;
        --no-doctor)
            RUN_DOCTOR=false
            shift
            ;;
        --bin-dir)
            if [[ $# -lt 2 ]]; then
                log_error "Опция --bin-dir требует аргумент <DIR>"
                exit 1
            fi
            BIN_DIR="$2"
            shift 2
            ;;
        --bin-dir=*)
            BIN_DIR="${1#*=}"
            shift
            ;;
        --config-dir)
            if [[ $# -lt 2 ]]; then
                log_error "Опция --config-dir требует аргумент <DIR>"
                exit 1
            fi
            CONFIG_DIR="$2"
            shift 2
            ;;
        --config-dir=*)
            CONFIG_DIR="${1#*=}"
            shift
            ;;
        *)
            log_error "Неизвестный параметр: $1"
            echo "Используйте --help для получения справки." >&2
            exit 1
            ;;
    esac
done

BIN_DIR="$(expand_path "$BIN_DIR")"
CONFIG_DIR="$(expand_path "$CONFIG_DIR")"

echo -e "${BOLD}${CYAN}===================================================================${NC}"
echo -e "${BOLD}              ⚡ УСТАНОВКА И НАСТРОЙКА ПЛАТФОРМЫ GRIME            ${NC}"
echo -e "${BOLD}${CYAN}===================================================================${NC}"
echo -e "${DIM}Репозиторий:  ${SCRIPT_DIR}${NC}"
echo -e "${DIM}Каталог bin:  ${BIN_DIR}${NC}"
echo -e "${DIM}Каталог cfg:  ${CONFIG_DIR}${NC}"
echo -e "${DIM}Режим модулей:$(if $USE_SYMLINK; then echo " Симлинки (режим разработчика)"; else echo " Копирование файлов"; fi)${NC}"
echo ""

# ------------------------------------------------------------------------------
# ШАГ 1: Обнаружение и установка бинарника grime
# ------------------------------------------------------------------------------
log_info "[1/4] Обнаружение и подготовка бинарника ядра GRIME..."

SRC_GRIME=""

find_existing_binaries() {
    # 1. target/release
    if [[ -x "$SCRIPT_DIR/target/release/grime" ]]; then
        SRC_GRIME="$SCRIPT_DIR/target/release/grime"
        return 0
    fi
    # 2. result/bin (Nix build)
    if [[ -x "$SCRIPT_DIR/result/bin/grime" ]]; then
        SRC_GRIME="$SCRIPT_DIR/result/bin/grime"
        return 0
    fi
    # 3. Существующие в целевом BIN_DIR или ~/.local/bin
    if [[ -x "$BIN_DIR/grime" ]]; then
        SRC_GRIME="$BIN_DIR/grime"
        return 0
    fi
    if [[ -x "$HOME/.local/bin/grime" ]]; then
        SRC_GRIME="$HOME/.local/bin/grime"
        return 0
    fi
    return 1
}

build_binaries() {
    log_info "Запуск компиляции GRIME из исходного кода..."
    if command -v cargo >/dev/null 2>&1; then
        log_info "Используется Cargo для сборки в режиме --release..."
        (cd "$SCRIPT_DIR" && cargo build --release)
        SRC_GRIME="$SCRIPT_DIR/target/release/grime"
    elif command -v nix >/dev/null 2>&1; then
        log_info "Используется Nix Flakes для сборки пакета..."
        (cd "$SCRIPT_DIR" && nix build --extra-experimental-features "nix-command flakes")
        SRC_GRIME="$SCRIPT_DIR/result/bin/grime"
    else
        log_error "Инструменты сборки (cargo, nix) не найдены в системе. Сборка невозможна."
        exit 1
    fi
}

if [[ "$FORCE_BUILD" == "true" ]]; then
    build_binaries
else
    if ! find_existing_binaries; then
        log_info "Скомпилированный бинарник не обнаружен. Попытка автоматической сборки..."
        build_binaries
    else
        log_success "Найден бинарник ядра: $SRC_GRIME"
    fi
fi

if [[ -z "$SRC_GRIME" || ! -f "$SRC_GRIME" ]]; then
    log_error "Не удалось найти или собрать бинарный файл grime!"
    exit 1
fi

mkdir -p "$BIN_DIR"

# Установка grime
if [[ "$SRC_GRIME" != "$BIN_DIR/grime" ]]; then
    install -m 755 "$SRC_GRIME" "$BIN_DIR/grime"
    log_success "Установлен бинарник: $BIN_DIR/grime"
else
    chmod +x "$BIN_DIR/grime" 2>/dev/null || true
    log_info "Бинарник $BIN_DIR/grime уже находится в целевом каталоге."
fi

# Проверка $PATH
case ":$PATH:" in
    *":$BIN_DIR:"*)
        log_success "Каталог бинарников ($BIN_DIR) присутствует в \$PATH."
        ;;
    *)
        echo ""
        log_warning "Каталог '$BIN_DIR' отсутствует в вашей переменной \$PATH!"
        echo -e "${YELLOW}Чтобы вызывать команду 'grime' из любого терминала, добавьте путь в конфиг шелла:${NC}"
        echo -e "  • Для Fish shell: ${BOLD}fish_add_path $BIN_DIR${NC}"
        echo -e "  • Для Bash:       ${BOLD}echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc${NC}"
        echo -e "  • Для Zsh:        ${BOLD}echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc${NC}"
        echo ""
        ;;
esac

# ------------------------------------------------------------------------------
# ШАГ 2: Развёртывание каталогов и декларативных модулей
# ------------------------------------------------------------------------------
echo ""
log_info "[2/4] Развёртывание каталогов и Lua-модулей GRIME..."

mkdir -p "$CONFIG_DIR/modules"
mkdir -p "$CONFIG_DIR/templates"
mkdir -p "$CONFIG_DIR/apps"
mkdir -p "$CONFIG_DIR/logs"

# Безопасное удаление: только внутри каталога конфигурации GRIME
safe_remove() {
    local target="$1"
    case "$target" in
        "$CONFIG_DIR"/?*) ;;
        *)
            log_error "Отказ в удалении вне каталога установки: $target"
            exit 1
            ;;
    esac
    # Символическая ссылка удаляется как ссылка (цель не затрагивается)
    if [[ -e "$target" || -L "$target" ]]; then
        rm -rf -- "$target"
    fi
}

# Идемпотентное развёртывание содержимого каталога src в dst (внутри CONFIG_DIR).
# Каждый элемент предварительно удаляется, поэтому переключение режимов
# копирование <-> симлинки не пишет через старые ссылки и не плодит вложенные каталоги.
deploy_dir() {
    local src="$1" dst="$2" label="$3" item base
    # Сам dst должен быть настоящим каталогом, а не ссылкой (иначе cp пишет в репозиторий)
    if [[ -L "$dst" ]]; then
        safe_remove "$dst"
    fi
    mkdir -p "$dst"
    # Висячие ссылки от прошлых установок
    find "$dst" -maxdepth 1 -xtype l -exec rm -f -- {} +
    local had_dotglob=false had_nullglob=false
    shopt -q dotglob && had_dotglob=true
    shopt -q nullglob && had_nullglob=true
    shopt -s dotglob nullglob
    for item in "$src"/*; do
        base="$(basename "$item")"
        safe_remove "$dst/$base"
        if [[ "$USE_SYMLINK" == "true" ]]; then
            ln -sfnT -- "$item" "$dst/$base"
        else
            cp -aT -- "$item" "$dst/$base"
        fi
    done
    "$had_dotglob" || shopt -u dotglob
    "$had_nullglob" || shopt -u nullglob
    if [[ "$USE_SYMLINK" == "true" ]]; then
        log_success "$label: симлинки на $src созданы."
    else
        log_success "$label: файлы скопированы."
    fi
}

# Развёртывание модулей (ядро ищет их в <config>/modules)
if [[ -d "$SCRIPT_DIR/modules" ]]; then
    deploy_dir "$SCRIPT_DIR/modules" "$CONFIG_DIR/modules" "Модули"
else
    log_warning "Каталог modules/ не найден в $SCRIPT_DIR!"
fi

# Развёртывание шаблонов
if [[ -d "$SCRIPT_DIR/templates" ]]; then
    deploy_dir "$SCRIPT_DIR/templates" "$CONFIG_DIR/templates" "Шаблоны"
fi

# ------------------------------------------------------------------------------
# ШАГ 3: Настройка шелл-хуков command_not_found
# ------------------------------------------------------------------------------
echo ""
log_info "[3/4] Настройка шелл-интеграции command_not_found..."

if [[ "$SETUP_HOOK" == "true" ]]; then
    # 1. Fish shell
    if [[ -d "$HOME/.config/fish" ]] || command -v fish >/dev/null 2>&1; then
        fish_fn_dir="$HOME/.config/fish/functions"
        fish_fn="$fish_fn_dir/fish_command_not_found.fish"
        mkdir -p "$fish_fn_dir"
        if [[ -e "$fish_fn" || -L "$fish_fn" ]] && ! grep -q "grime pkg" "$fish_fn" 2>/dev/null; then
            fish_bak="$fish_fn.bak.$(date +%Y%m%d%H%M%S)"
            mv -- "$fish_fn" "$fish_bak"
            log_warning "Найден чужой fish_command_not_found.fish, резервная копия: $fish_bak"
        fi
        cat << 'EOF' > "$fish_fn"
# GRIME ephemeral command-not-found hook
function fish_command_not_found
    grime pkg -not-found --no-confirm -- $argv
end
EOF
        log_success "Настроен хук Fish: ~/.config/fish/functions/fish_command_not_found.fish"
    fi

    # 2. Bash shell
    if [[ -f "$HOME/.bashrc" ]]; then
        if grep -q "grime pkg -\?not-found" "$HOME/.bashrc"; then
            log_info "Хук GRIME уже присутствует в ~/.bashrc."
        else
            cat << 'EOF' >> "$HOME/.bashrc"

# GRIME ephemeral command-not-found hook
command_not_found_handle() {
    grime pkg -not-found --no-confirm -- "$@"
}
EOF
            log_success "Добавлен хук в ~/.bashrc"
        fi
    fi

    # 3. Zsh shell
    if [[ -f "$HOME/.zshrc" ]]; then
        if grep -q "grime pkg -\?not-found" "$HOME/.zshrc"; then
            log_info "Хук GRIME уже присутствует в ~/.zshrc."
        else
            cat << 'EOF' >> "$HOME/.zshrc"

# GRIME ephemeral command-not-found hook
command_not_found_handler() {
    grime pkg -not-found --no-confirm -- "$@"
}
EOF
            log_success "Добавлен хук в ~/.zshrc"
        fi
    fi
else
    log_info "Настройка шелл-хуков пропущена (--no-hook)."
fi

# ------------------------------------------------------------------------------
# ШАГ 4: Финальная проверка и диагностика
# ------------------------------------------------------------------------------
echo ""
log_info "[4/4] Запуск системной проверки GRIME Doctor..."
echo ""

if [[ "$RUN_DOCTOR" != "true" ]]; then
    log_info "Диагностика пропущена (--no-doctor)."
elif [[ -x "$BIN_DIR/grime" ]]; then
    "$BIN_DIR/grime" doctor || true
else
    log_warning "Бинарник $BIN_DIR/grime не найден для запуска doctor."
fi

echo ""
echo -e "${BOLD}${GREEN}===================================================================${NC}"
echo -e "${BOLD}${GREEN}              🎉 УСТАНОВКА GRIME УСПЕШНО ЗАВЕРШЕНА!                ${NC}"
echo -e "${BOLD}${GREEN}===================================================================${NC}"
echo -e "  • ${BOLD}Исполняемый файл:${NC} $BIN_DIR/grime"
echo -e "  • ${BOLD}Конфигурация:${NC} $CONFIG_DIR"
echo -e "  • ${BOLD}Модули:${NC}       $CONFIG_DIR/modules ($(if $USE_SYMLINK; then echo "символические ссылки"; else echo "копии файлов"; fi))"
echo -e "  • ${BOLD}Шаблоны:${NC}      $CONFIG_DIR/templates"
echo -e "  • ${BOLD}Приложения:${NC}   $CONFIG_DIR/apps"
echo -e "  • ${BOLD}Журнал логов:${NC} $CONFIG_DIR/logs"
echo ""
echo -e "${BOLD}Полезные команды для начала работы:${NC}"
echo -e "  ${CYAN}grime --help${NC}              Справка по всем модулям"
echo -e "  ${CYAN}grime doctor${NC}              Комплексная диагностика окружения"
echo -e "  ${CYAN}grime project -init cpp MyGame${NC} Создание нового проекта (cpp, rust, python, java)"
echo -e "  ${CYAN}grime app -new MyApp${NC}             Создание изолированного микроприложения"
echo -e "  ${CYAN}grime pkg list${NC}            Инспекция установленного системного ПО"
echo -e "${BOLD}${GREEN}===================================================================${NC}"
