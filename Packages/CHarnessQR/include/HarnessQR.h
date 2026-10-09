#include "qrcodegen.h"

// Expose the expression macro as a constant that Swift can import.
enum { HarnessQRBufferLength = qrcodegen_BUFFER_LEN_MAX };
