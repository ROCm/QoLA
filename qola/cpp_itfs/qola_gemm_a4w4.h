// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs C API for AITER's a4w4 (FP4 x FP4) GEMM kernels.
//
// This header deliberately pulls in nothing from AITER.  Consumers see only
// a QoLA-owned POD descriptor and C-linkage entry points, so they can link
// the kernel libraries without exposing AITER headers (or AITER's enum
// ordering) to their own translation units.
//
// Error contract: every entry point returns 0 on success and non-zero on
// failure.  A human-readable message is written to the caller-supplied
// `err_buf` when one is provided.  The message is an out-parameter rather
// than a thread-local accessor on purpose -- the a4w4 backends ship as
// separate shared objects, so a shared `last_error()` symbol would resolve
// to whichever library the dynamic linker bound first and silently report
// the wrong (or an empty) message.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "qola_common.h"

// Element type of an operand.  Values are QoLA's own and are translated to
// AITER's AiterDtype inside the implementation, so this ABI is unaffected by
// reordering of AITER's enum.
typedef enum {
  QOLA_DTYPE_FP4X2 = 0, /* two packed FP4 (E2M1) values per byte */
  QOLA_DTYPE_E8M0 = 1,  /* 8-bit exponent-only microscale (1 byte) */
  QOLA_DTYPE_BF16 = 2,
  QOLA_DTYPE_FP16 = 3,
  QOLA_DTYPE_FP32 = 4,
  QOLA_DTYPE_U8 = 5,
  QOLA_DTYPE_I8 = 6,
} qola_dtype_t;

// Lightweight device-tensor descriptor.  The caller owns the storage; the
// descriptor must outlive the call but the storage need not.
//
// Field order is chosen for natural alignment and the explicit padding keeps
// the layout identical across compilers, so consumers may safely define a
// structurally identical type instead of including this header.
typedef struct {
  void *ptr;
  int32_t ndim;
  int32_t dtype; /* one of qola_dtype_t */
  int32_t device_id;
  int32_t reserved;
  int64_t shape[8];
  int64_t strides[8];
} qola_tensor_t;

QOLA_C_BEGIN

/* CK blockscale a4w4 GEMM: Y = XQ @ WQ^T with per-1x32 microscaling.
 *   XQ      [M, K/2]  fp4x2
 *   WQ      [N, K/2]  fp4x2
 *   x_scale [M, K/32] e8m0
 *   w_scale [N, K/32] e8m0
 *   Y       [M, N]    bf16 / fp16   (output, pre-allocated)
 *
 * `kernel_name` may be NULL or empty to request the default heuristic;
 * a non-empty name must exist in the compiled registry.  Kernel selection
 * and weight/scale pre-shuffling are the caller's responsibility.
 */
QOLA_EXPORT int QOLA_C(gemm_a4w4_blockscale)(const qola_tensor_t *XQ, const qola_tensor_t *WQ,
                                             const qola_tensor_t *x_scale,
                                             const qola_tensor_t *w_scale, const qola_tensor_t *Y,
                                             int split_k, const char *kernel_name,
                                             hipStream_t stream, char *err_buf, size_t err_buf_size);

/* ASM (f4gemm) a4w4 GEMM: D = alpha*A*B + beta*C.
 * `bias` may be NULL; `kernel_name` may be NULL or empty for the heuristic.
 */
QOLA_EXPORT int QOLA_C(gemm_a4w4_asm)(const qola_tensor_t *A, const qola_tensor_t *B,
                                      const qola_tensor_t *a_scale, const qola_tensor_t *b_scale,
                                      const qola_tensor_t *out, const qola_tensor_t *bias,
                                      const char *kernel_name, float alpha, float beta,
                                      int bpreshuffle, int log2_k_split, hipStream_t stream,
                                      char *err_buf, size_t err_buf_size);

QOLA_C_END
