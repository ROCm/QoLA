// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs wrapper for AITER's ASM a4w4 GEMM (f4gemm).
#pragma once

#include "qola_common.h"
#include "aiter_tensor.h"  // aiter_tensor_t

QOLA_NS_BEGIN

// Executes AITER's ASM a4w4 GEMM (D = alpha*A*B + beta*C).  The underlying
// AITER symbol is a C-ABI entrypoint returning a status code; this wrapper
// throws std::runtime_error on failure so callers get a uniform C++ contract.
// Kernel selection and weight/scale pre-shuffling are the caller's
// responsibility -- `kernelName` may be empty to request the ASM heuristic,
// and `bias` may be nullptr.
__attribute__((visibility("default")))
void gemm_a4w4_asm(aiter_tensor_t* A,
                   aiter_tensor_t* B,
                   aiter_tensor_t* A_scale,
                   aiter_tensor_t* B_scale,
                   aiter_tensor_t* out,
                   const char* kernelName,
                   aiter_tensor_t* bias,
                   float alpha,
                   float beta,
                   int bpreshuffle,
                   int log2_k_split,
                   hipStream_t stream);

QOLA_NS_END
