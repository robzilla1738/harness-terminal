#include "HarnessImage.h"
#if defined(__linux__)
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// Keep every stb temporary allocation inside a per-decode budget, including PNG
// inflate buffers. Thread-local accounting permits independent pane processors.
#define HARNESS_DECODE_BUDGET ((size_t)192 * 1024 * 1024)
#define HARNESS_ENCODED_LIMIT ((size_t)32 * 1024 * 1024)
#define HARNESS_PIXEL_LIMIT ((size_t)4096 * 4096)
typedef union { max_align_t alignment; size_t size; } AllocationHeader;
static _Thread_local size_t allocated_bytes;
static _Thread_local int accounting_active;

static void *bounded_malloc(size_t size) {
    if (size > HARNESS_DECODE_BUDGET - allocated_bytes || size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *header = malloc(sizeof(*header) + size);
    if (!header) return NULL;
    header->size = size;
    allocated_bytes += size;
    return header + 1;
}
static void bounded_free(void *pointer) {
    if (!pointer) return;
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    if (accounting_active) allocated_bytes -= header->size;
    free(header);
}
static void *bounded_realloc(void *pointer, size_t size) {
    if (!pointer) return bounded_malloc(size);
    AllocationHeader *old = (AllocationHeader *)pointer - 1;
    const size_t previous = old->size;
    if (size > HARNESS_DECODE_BUDGET - (allocated_bytes - previous) || size > SIZE_MAX - sizeof(*old)) return NULL;
    AllocationHeader *header = realloc(old, sizeof(*old) + size);
    if (!header) return NULL;
    header->size = size;
    allocated_bytes = allocated_bytes - previous + size;
    return header + 1;
}
#define STBI_MALLOC(size) bounded_malloc(size)
#define STBI_REALLOC(pointer, size) bounded_realloc(pointer, size)
#define STBI_FREE(pointer) bounded_free(pointer)
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_FAILURE_STRINGS
#define STBI_MAX_DIMENSIONS 100000
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

uint8_t *harness_image_decode(const uint8_t *data, size_t length, int *width, int *height) {
    if (!data || !width || !height || length > HARNESS_ENCODED_LIMIT || length < 3 || length > INT_MAX) return NULL;
    allocated_bytes = 0;
    accounting_active = 1;
    int x = 0, y = 0, channels = 0;
    uint8_t *pixels = NULL;
    if (stbi_info_from_memory(data, (int)length, &x, &y, &channels) && x > 0 && y > 0 &&
        x <= STBI_MAX_DIMENSIONS && y <= STBI_MAX_DIMENSIONS && (size_t)x <= HARNESS_PIXEL_LIMIT / (size_t)y) {
        const int expected_x = x, expected_y = y;
        pixels = stbi_load_from_memory(data, (int)length, &x, &y, &channels, 4);
        if (pixels && (x != expected_x || y != expected_y)) {
            bounded_free(pixels);
            pixels = NULL;
        }
        if (pixels) {
            for (size_t i = 0, count = (size_t)x * (size_t)y * 4; i < count; i += 4) {
                const unsigned alpha = pixels[i + 3];
                for (size_t channel = 0; channel < 3; ++channel)
                    pixels[i + channel] = (uint8_t)((pixels[i + channel] * alpha + 127) / 255);
            }
            *width = x;
            *height = y;
        }
    }
    accounting_active = 0;
    return pixels;
}
void harness_image_free(uint8_t *pixels) { bounded_free(pixels); }
#endif
