#include "CHarnessBase64.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static const uint8_t kMap[256] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3E, 0xFF, 0xFF, 0xFF, 0x3F,
    0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
    0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
};

_Static_assert(sizeof(kMap) == 256, "base64 map must cover every byte");

// `pad` is 0, 1, or 2 and applies only to the final quantum. Returns bytes written, or -1.
static int write_quantum(const uint8_t *src, uint8_t *dst, int pad, int *non_ascii) {
    uint8_t v0 = kMap[src[0]];
    uint8_t v1 = kMap[src[1]];
    uint8_t v2 = pad == 2 ? 0 : kMap[src[2]];
    uint8_t v3 = pad >= 1 ? 0 : kMap[src[3]];
    if (v0 == 0xFF || v1 == 0xFF || v2 == 0xFF || v3 == 0xFF) return -1;
    if (pad == 2 && (src[2] != '=' || src[3] != '=')) return -1;
    if (pad == 1 && src[3] != '=') return -1;
    if (pad == 0 && (src[2] == '=' || src[3] == '=')) return -1;
    dst[0] = (uint8_t)((v0 << 2) | (v1 >> 4));
    if (pad < 2) dst[1] = (uint8_t)((v1 << 4) | (v2 >> 2));
    if (pad < 1) dst[2] = (uint8_t)((v2 << 6) | v3);
    uint8_t bits = dst[0];
    if (pad < 2) bits |= dst[1];
    if (pad < 1) bits |= dst[2];
    if (bits & 0x80) *non_ascii = 1;
    return 3 - pad;
}

#if defined(__aarch64__)
static intptr_t decode_neon(const uint8_t *src, intptr_t count, uint8_t *dst, int *non_ascii) {
    *non_ascii = 0;
    if (count == 0) return 0;
    int pad = 0;
    if (src[count - 1] == '=') pad++;
    if (count >= 2 && src[count - 2] == '=') pad++;
    if (pad > 2) return -1;
    intptr_t body = count - (pad ? 4 : 0);
    intptr_t chunk = body & ~((intptr_t)15);
    const uint8x16_t upper_a = vdupq_n_u8('A');
    const uint8x16_t upper_z = vdupq_n_u8('Z');
    const uint8x16_t lower_a = vdupq_n_u8('a');
    const uint8x16_t lower_z = vdupq_n_u8('z');
    const uint8x16_t digit_0 = vdupq_n_u8('0');
    const uint8x16_t digit_9 = vdupq_n_u8('9');
    const uint8x16_t plus = vdupq_n_u8('+');
    const uint8x16_t slash = vdupq_n_u8('/');
    const uint8x16_t plus_26 = vdupq_n_u8(26);
    const uint8x16_t plus_52 = vdupq_n_u8(52);
    const uint8x16_t value_62 = vdupq_n_u8(62);
    const uint8x16_t value_63 = vdupq_n_u8(63);
    // Packed bytes land as [out2, out1, out0, 0] per quantum. Gather the three
    // output bytes. The last four indices are unused; the store is 16 wide and
    // the caller keeps four bytes of slack past the decoded length.
    const uint8x16_t gather = {2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 0, 0, 0, 0};
    const uint8x16_t keep = {
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0
    };
    int any_high = 0;
    for (intptr_t i = 0; i < chunk; i += 16) {
        uint8x16_t in = vld1q_u8(src + i);
        uint8x16_t is_upper = vandq_u8(vcgeq_u8(in, upper_a), vcleq_u8(in, upper_z));
        uint8x16_t is_lower = vandq_u8(vcgeq_u8(in, lower_a), vcleq_u8(in, lower_z));
        uint8x16_t is_digit = vandq_u8(vcgeq_u8(in, digit_0), vcleq_u8(in, digit_9));
        uint8x16_t is_plus = vceqq_u8(in, plus);
        uint8x16_t is_slash = vceqq_u8(in, slash);
        uint8x16_t valid = vorrq_u8(
            is_upper, vorrq_u8(is_lower, vorrq_u8(is_digit, vorrq_u8(is_plus, is_slash))));
        if (vminvq_u8(valid) == 0) return -1;
        uint8x16_t value = vbslq_u8(is_upper, vsubq_u8(in, upper_a), vdupq_n_u8(0));
        value = vbslq_u8(is_lower, vaddq_u8(vsubq_u8(in, lower_a), plus_26), value);
        value = vbslq_u8(is_digit, vaddq_u8(vsubq_u8(in, digit_0), plus_52), value);
        value = vbslq_u8(is_plus, value_62, value);
        value = vbslq_u8(is_slash, value_63, value);
        uint32x4_t lanes = vreinterpretq_u32_u8(value);
        uint32x4_t a = vandq_u32(lanes, vdupq_n_u32(0x3F));
        uint32x4_t b = vandq_u32(vshrq_n_u32(lanes, 8), vdupq_n_u32(0x3F));
        uint32x4_t c = vandq_u32(vshrq_n_u32(lanes, 16), vdupq_n_u32(0x3F));
        uint32x4_t d = vshrq_n_u32(lanes, 24);
        uint32x4_t packed = vorrq_u32(
            vorrq_u32(vshlq_n_u32(a, 18), vshlq_n_u32(b, 12)),
            vorrq_u32(vshlq_n_u32(c, 6), d));
        uint8x16_t out = vqtbl1q_u8(vreinterpretq_u8_u32(packed), gather);
        // 16-byte store, 12 bytes consumed. The extra 4 overlap the next chunk
        // or the slack past the decoded length.
        vst1q_u8(dst + (i / 16) * 12, out);
        if (vmaxvq_u8(vandq_u8(out, keep)) & 0x80) any_high = 1;
    }
    intptr_t produced = (chunk / 4) * 3;
    for (intptr_t offset = chunk; offset < body; offset += 4) {
        if (write_quantum(src + offset, dst + produced, 0, non_ascii) < 0) return -1;
        produced += 3;
    }
    if (pad) {
        int wrote = write_quantum(src + body, dst + produced, pad, non_ascii);
        if (wrote < 0) return -1;
        produced += wrote;
    }
    if (any_high) *non_ascii = 1;
    return produced;
}
#else
static intptr_t decode_scalar(const uint8_t *src, intptr_t count, uint8_t *dst, int *non_ascii) {
    *non_ascii = 0;
    if (count == 0) return 0;
    int pad = 0;
    if (src[count - 1] == '=') pad++;
    if (count >= 2 && src[count - 2] == '=') pad++;
    if (pad > 2) return -1;
    intptr_t quants = count / 4;
    intptr_t full = quants - (pad ? 1 : 0);
    for (intptr_t q = 0; q < full; q++) {
        if (write_quantum(src + q * 4, dst + q * 3, 0, non_ascii) < 0) return -1;
    }
    if (pad && write_quantum(src + full * 4, dst + full * 3, pad, non_ascii) < 0) return -1;
    return quants * 3 - pad;
}
#endif

intptr_t harness_base64_decode(const uint8_t *src, intptr_t count, uint8_t *dst, int *non_ascii) {
    if (count < 0 || (count & 3) != 0) {
        *non_ascii = 0;
        return -1;
    }
#if defined(__aarch64__)
    return decode_neon(src, count, dst, non_ascii);
#else
    return decode_scalar(src, count, dst, non_ascii);
#endif
}
