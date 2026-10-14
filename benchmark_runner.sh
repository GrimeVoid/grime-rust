#!/usr/bin/env bash
set -e

RUST_BIN="/home/danny/.local/bin/grime"
PY_BIN="/home/danny/Archive/_Programing_/python/grimeProject/venv/bin/python3"
PY_SCRIPT="/home/danny/Archive/_Programing_/python/grimeProject/grime.py"

echo "=== СТАРТ ГЛУБОКОГО БЕНЧМАРКИНГА GRIME (RUST VS PYTHON) ==="
mkdir -p benchmark_results

echo "--- 1. Сценарий A: Холодный запуск CLI (--help) ---"
hyperfine --warmup 3 --runs 25 --export-json benchmark_results/scenario_a_help.json \
  -n "Rust: grime --help" "$RUST_BIN --help" \
  -n "Python (default): grime --help" "$PY_BIN $PY_SCRIPT --help" \
  -n "Python (PYTHONOPTIMIZE=2)" "PYTHONOPTIMIZE=2 $PY_BIN $PY_SCRIPT --help" \
  -n "Python (PYTHONDONTWRITEBYTECODE=1)" "PYTHONDONTWRITEBYTECODE=1 $PY_BIN $PY_SCRIPT --help"

echo "--- 2. Сценарий A: Холодный запуск CLI (--version) ---"
hyperfine --warmup 3 --runs 25 --export-json benchmark_results/scenario_a_version.json \
  -n "Rust: grime --version" "$RUST_BIN --version" \
  -n "Python (default): grime --version" "$PY_BIN $PY_SCRIPT --version" \
  -n "Python (PYTHONOPTIMIZE=2)" "PYTHONOPTIMIZE=2 $PY_BIN $PY_SCRIPT --version"

echo "--- 3. Сценарий B: Парсинг и запуск модуля host ---"
hyperfine --warmup 3 --runs 20 --export-json benchmark_results/scenario_b_host.json \
  -n "Rust: grime host" "$RUST_BIN host" \
  -n "Python: grime host" "$PY_BIN $PY_SCRIPT host"

echo "--- 4. Сценарий B: Парсинг и запуск модуля doctor ---"
hyperfine --warmup 2 --runs 15 --export-json benchmark_results/scenario_b_doctor.json \
  -n "Rust: grime doctor" "$RUST_BIN doctor" \
  -n "Python: grime doctor" "$PY_BIN $PY_SCRIPT doctor"

echo "--- 5. Сценарий C: Многозвенный конвейер (3 звена) ---"
hyperfine --warmup 3 --runs 20 --export-json benchmark_results/scenario_c_3steps.json \
  -n "Rust (3 steps)" "$RUST_BIN bus set test.count 100 '->' bus get test.count '->' cmd awk '{print \$1 * 2}'" \
  -n "Python (3 steps)" "$PY_BIN $PY_SCRIPT bus set test.count 100 '->' bus get test.count '->' cmd awk '{print \$1 * 2}'"

echo "--- 6. Сценарий C: Многозвенный конвейер (5 звеньев) ---"
hyperfine --warmup 3 --runs 20 --export-json benchmark_results/scenario_c_5steps.json \
  -n "Rust (5 steps)" "$RUST_BIN bus set test.count 100 '->' bus get test.count '->' cmd awk '{print \$1 * 2}' '->' bus set test.double '->' bus get test.double" \
  -n "Python (5 steps)" "$PY_BIN $PY_SCRIPT bus set test.count 100 '->' bus get test.count '->' cmd awk '{print \$1 * 2}' '->' bus set test.double '->' bus get test.double"

echo "--- 7. Сценарий D: Работа с шиной данных (StateBus set) ---"
hyperfine --warmup 3 --runs 25 --export-json benchmark_results/scenario_d_bus_set.json \
  -n "Rust: bus set pipeline.mode production" "$RUST_BIN bus set pipeline.mode production" \
  -n "Python: bus set pipeline.mode production" "$PY_BIN $PY_SCRIPT bus set pipeline.mode production"

echo "--- 8. Замер пикового потребления памяти (RSS) ---"
measure_rss() {
  local label="$1"
  shift
  local out
  out=$(command time -v "$@" 2>&1 | grep "Maximum resident set size" | awk '{print $6}')
  echo "$label: ${out} KB"
}

measure_rss "Rust CLI (--help)" "$RUST_BIN" --help > benchmark_results/rss_summary.txt
measure_rss "Python CLI (--help)" "$PY_BIN" "$PY_SCRIPT" --help >> benchmark_results/rss_summary.txt
measure_rss "Rust 5-step pipeline" "$RUST_BIN" bus set test.count 100 "->" bus get test.count "->" cmd awk '{print $1 * 2}' "->" bus set test.double "->" bus get test.double >> benchmark_results/rss_summary.txt
measure_rss "Python 5-step pipeline" "$PY_BIN" "$PY_SCRIPT" bus set test.count 100 "->" bus get test.count "->" cmd awk '{print $1 * 2}' "->" bus set test.double "->" bus get test.double >> benchmark_results/rss_summary.txt

cat benchmark_results/rss_summary.txt
echo "=== БЕНЧМАРКИНГ УСПЕШНО ЗАВЕРШЕН ==="
