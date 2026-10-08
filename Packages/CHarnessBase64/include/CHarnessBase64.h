#ifndef C_HARNESS_BASE64_H
#define C_HARNESS_BASE64_H

#include <stdint.h>

// Strict base64: alphabet A–Z a–z 0–9 + /, '=' only as padding on the final
// quantum, length a multiple of 4. Returns the decoded byte count, or -1.
// `non_ascii` is set to 1 when any decoded byte is >= 0x80, else 0.
//
// OSC 52 feeds this a borrowed 600 KiB body on the terminal `feed` path.
// Foundation's decoder is correct and too slow for that body; this is the
// arm64 hot path. Callers that get -1 try Foundation, which still accepts a
// few non-standard paddings this rejects.
intptr_t harness_base64_decode(const uint8_t *src, intptr_t count, uint8_t *dst, int *non_ascii);

// Kitty graphics `t=s`: copy up to `size` bytes (0: all) from `offset` of the POSIX shared
// memory object `name` into a malloc'd buffer at `*out` (the caller frees it), then unlink the
// object as the protocol asks. Returns the byte count, or -1 (missing, too large for `limit`).
intptr_t harness_shm_take(const char *name, intptr_t offset, intptr_t size, intptr_t limit, uint8_t **out);

// Create the shared memory object `name` holding `bytes` (0600, fails if it exists). For tests
// and tools that send Kitty images by `t=s`. Returns 0, or -1.
int harness_shm_put(const char *name, const uint8_t *bytes, intptr_t count);

#endif /* C_HARNESS_BASE64_H */
