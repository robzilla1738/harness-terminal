#ifndef HARNESS_IMAGE_H
#define HARNESS_IMAGE_H
#include <stddef.h>
#include <stdint.h>
// Memory-only PNG/JPEG. Returns premultiplied RGBA8, owned by caller until free.
uint8_t *harness_image_decode(const uint8_t *data, size_t length, int *width, int *height);
void harness_image_free(uint8_t *pixels);
#endif
