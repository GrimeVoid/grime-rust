#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* Вычисление CRC-32 (IEEE 802.3) */
static uint32_t crc32_table[256];
static int table_inited = 0;

static void init_crc32(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) {
            c = (c & 1) ? (0xEDB88320L ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    table_inited = 1;
}

static uint32_t compute_crc32(const uint8_t *buf, size_t len) {
    if (!table_inited) init_crc32();
    uint32_t c = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        c = crc32_table[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

static inline uint64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv) {
    uint64_t t0 = get_time_ns();

    char buffer[65536];
    size_t bytes_read = 0;

    if (argc > 1 && strlen(argv[1]) > 0) {
        strncpy(buffer, argv[1], sizeof(buffer) - 1);
        buffer[sizeof(buffer) - 1] = '\0';
        bytes_read = strlen(buffer);
    } else {
        bytes_read = fread(buffer, 1, sizeof(buffer) - 1, stdin);
        buffer[bytes_read] = '\0';
    }

    if (bytes_read == 0) {
        fprintf(stderr, "[Consumer-C] Ошибка: пустой ввод\n");
        return 1;
    }

    /* Простой и сверхбыстрый парсинг JSON без сторонних тяжелых библиотек */
    long round_id = 0;
    long expected_sum = 0;
    unsigned long expected_crc = 0;

    char *p_round = strstr(buffer, "\"round\":");
    if (p_round) round_id = strtol(p_round + 8, NULL, 10);

    char *p_exp = strstr(buffer, "\"expected_sum\":");
    if (p_exp) expected_sum = strtol(p_exp + 15, NULL, 10);

    char *p_crc = strstr(buffer, "\"crc\":");
    if (p_crc) expected_crc = strtoul(p_crc + 6, NULL, 10);

    /* Поиск массива items */
    char *p_items = strstr(buffer, "\"items\":");
    long calculated_sum = 0;
    int items_count = 0;
    uint8_t crc_bytes[4096];
    size_t crc_len = 0;

    if (p_items) {
        char *bracket = strchr(p_items, '[');
        if (bracket) {
            char *cur = bracket + 1;
            while (*cur && *cur != ']') {
                while (*cur == ' ' || *cur == ',' || *cur == '\n' || *cur == '\r') cur++;
                if (*cur == ']' || *cur == '\0') break;
                char *next = NULL;
                long val = strtol(cur, &next, 10);
                if (next == cur) break;
                calculated_sum += val;
                if (crc_len < sizeof(crc_bytes)) {
                    crc_bytes[crc_len++] = (uint8_t)(val & 0xFF);
                }
                items_count++;
                cur = next;
            }
        }
    }

    uint32_t actual_crc = compute_crc32(crc_bytes, crc_len);
    const char *status = "VERIFIED";

    if (calculated_sum != expected_sum || actual_crc != expected_crc) {
        status = "CORRUPTED";
    }

    uint64_t t1 = get_time_ns();
    uint64_t duration_ns = t1 - t0;

    printf("{\"round\":%ld,\"status\":\"%s\",\"sum\":%ld,\"items\":%d,\"c_ns\":%lu}\n",
           round_id, status, calculated_sum, items_count, (unsigned long)duration_ns);

    return (strcmp(status, "VERIFIED") == 0) ? 0 : 2;
}
