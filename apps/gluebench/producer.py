#!/usr/bin/env python3
"""
Программа A (Python): Генератор структурированных пакетов данных для полиглотного IPC-бенчмарка Grime.
"""
import sys
import json
import time
import zlib

def make_payload(round_id: int, size: int = 100) -> str:
    # Генерируем воспроизводимый массив чисел для раунда
    base = round_id * 17
    items = [(base + i * 3) % 1000 for i in range(size)]
    expected_sum = sum(items)
    
    # Контрольная сумма от байт массива
    data_bytes = bytes([x & 0xFF for x in items])
    crc = zlib.crc32(data_bytes)
    
    packet = {
        "round": round_id,
        "ts_ns": time.time_ns(),
        "size": size,
        "expected_sum": expected_sum,
        "crc": crc,
        "items": items
    }
    return json.dumps(packet)

def verify_response(expected_round: int, response_str: str) -> bool:
    try:
        resp = json.loads(response_str)
        if resp.get("round") != expected_round:
            return False
        if resp.get("status") != "VERIFIED":
            return False
        return True
    except Exception:
        return False

def main():
    if len(sys.argv) < 2:
        print("Использование: producer.py produce <round_id> [size] | verify <round_id> <response>", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "produce":
        round_id = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        size = int(sys.argv[3]) if len(sys.argv) > 3 else 100
        print(make_payload(round_id, size))
    elif cmd == "verify":
        round_id = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        raw_resp = sys.argv[3] if len(sys.argv) > 3 else sys.stdin.read()
        if verify_response(round_id, raw_resp):
            print("OK")
            sys.exit(0)
        else:
            print("FAIL")
            sys.exit(1)
    else:
        print(f"Неизвестная команда: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
