#!/usr/bin/env bash
# ==============================================================================
#  Бенчмарк GRIME (hyperfine). Сравнение с Python-версией — опционально.
#
#  Переменные окружения:
#    GRIME_BIN   путь к бинарнику Rust (по умолчанию: <репозиторий>/target/release/grime,
#                иначе grime из $PATH)
#    OUT_DIR     каталог результатов (по умолчанию: <репозиторий>/benchmark_results)
#    PY_BIN      интерпретатор Python для сравнения (по умолчанию: python3, если задан PY_SCRIPT)
#    PY_SCRIPT   путь к grime.py; если не задан — Python-замеры пропускаются
#    PIPE_SEP    разделитель звеньев конвейера (по умолчанию ':'; для старого Python — '->')
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${GRIME_BIN:-}" ]]; then
    if [[ -x "$SCRIPT_DIR/target/release/grime" ]]; then
        GRIME_BIN="$SCRIPT_DIR/target/release/grime"
    else
        GRIME_BIN="$(command -v grime || true)"
    fi
fi
if [[ -z "$GRIME_BIN" || ! -x "$GRIME_BIN" ]]; then
    echo "Бинарник grime не найден: задайте GRIME_BIN" >&2
    exit 1
fi
command -v hyperfine >/dev/null 2>&1 || { echo "Требуется hyperfine" >&2; exit 1; }

OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/benchmark_results}"
PY_SCRIPT="${PY_SCRIPT:-}"
PY_BIN="${PY_BIN:-python3}"
SEP="${PIPE_SEP:-:}"
WITH_PY=false
if [[ -n "$PY_SCRIPT" ]]; then
    [[ -f "$PY_SCRIPT" ]] || { echo "PY_SCRIPT не найден: $PY_SCRIPT" >&2; exit 1; }
    WITH_PY=true
fi

mkdir -p "$OUT_DIR"

# Запуск hyperfine: bench <файл> <warmup> <runs> <аргументы grime...>
# Для Python добавляется парная команда, если задан PY_SCRIPT.
bench() {
    local name="$1" warmup="$2" runs="$3" args="$4"
    local cmds=(-n "Rust: $args" "$GRIME_BIN $args")
    if $WITH_PY; then
        cmds+=(-n "Python: $args" "$PY_BIN $PY_SCRIPT $args")
    fi
    hyperfine --warmup "$warmup" --runs "$runs" --export-json "$OUT_DIR/$name.json" "${cmds[@]}"
}

PIPE3="bus set test.count 100 '$SEP' bus get test.count '$SEP' cmd awk '{print \$1 * 2}'"
PIPE5="$PIPE3 '$SEP' bus set test.double '$SEP' bus get test.double"

echo "=== СТАРТ БЕНЧМАРКИНГА GRIME (бинарник: $GRIME_BIN; Python: $WITH_PY) ==="

echo "--- 1. Сценарий A: холодный запуск CLI (--help) ---"
bench scenario_a_help 3 25 "--help"

echo "--- 2. Сценарий A: холодный запуск CLI (--version) ---"
bench scenario_a_version 3 25 "--version"

echo "--- 3. Сценарий B: модуль host ---"
bench scenario_b_host 3 20 "host"

echo "--- 4. Сценарий B: модуль doctor ---"
bench scenario_b_doctor 2 15 "doctor"

echo "--- 5. Сценарий C: конвейер (3 звена) ---"
bench scenario_c_3steps 3 20 "$PIPE3"

echo "--- 6. Сценарий C: конвейер (5 звеньев) ---"
bench scenario_c_5steps 3 20 "$PIPE5"

echo "--- 7. Сценарий D: StateBus set ---"
bench scenario_d_bus_set 3 25 "bus set pipeline.mode production"

echo "--- 8. Пиковое потребление памяти (RSS) ---"
measure_rss() {
    local label="$1"
    shift
    local out
    out=$(command time -v "$@" 2>&1 >/dev/null | grep "Maximum resident set size" | awk '{print $NF}' || true)
    echo "$label: ${out} KB"
}

{
    measure_rss "Rust CLI (--help)" "$GRIME_BIN" --help
    measure_rss "Rust 5-step pipeline" bash -c "$GRIME_BIN $PIPE5"
    if $WITH_PY; then
        measure_rss "Python CLI (--help)" "$PY_BIN" "$PY_SCRIPT" --help
        measure_rss "Python 5-step pipeline" bash -c "$PY_BIN $PY_SCRIPT $PIPE5"
    fi
} > "$OUT_DIR/rss_summary.txt"

cat "$OUT_DIR/rss_summary.txt"
echo "=== БЕНЧМАРКИНГ ЗАВЕРШЁН (результаты: $OUT_DIR) ==="
