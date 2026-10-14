#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "  Запуск автоматизированного скрипта тестирования Grime   "
echo "=========================================================="

echo "[1/4] Диагностика окружения Grime Doctor..."
grime doctor

echo "[2/4] Запись параметров конвейера в StateBus..."
grime bus set script.run_timestamp "$(date +%s)"
grime bus set script.caller "automated_test_suite"

echo "[3/4] Запуск многомодульного конвейера Grime (git -> bus -> app -> log)..."
grime git status "->" bus set user.git_branch "->" app TestApp "->" log INFO

echo "[4/4] Чтение последних записей системного журнала..."
grime log 3

echo "Проверка сохраненного значения в StateBus:"
RUN_USER=$(grime bus get session.user)
echo "Текущий пользователь в StateBus: ${RUN_USER}"

echo "=========================================================="
echo "  Скрипт Grime успешно завершен без единой ошибки!        "
echo "=========================================================="
