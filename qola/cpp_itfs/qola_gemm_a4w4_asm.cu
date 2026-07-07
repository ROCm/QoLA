// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's ASM a4w4 GEMM (f4gemm).

#include <stdexcept>

#include "qola_gemm_a4w4_asm.h"

// The torch-free ASM entrypoint is a C-ABI symbol defined in AITER's
// csrc/py_itfs_cu/asm_gemm_a4w4.cu via AITER_CTYPES_DEFINE_ENTRYPOINT_VOID.
// It returns 0 on success or -1 on failure, with the message stored in a
// thread-local retrievable through aiter_get_last_error().  We declare both
// here rather than pull in a torch-tainted AITER header.
extern "C" int gemm_a4w4_asm(aiter_tensor_t* A,
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
extern "C" const char* aiter_get_last_error();

QOLA_NS_BEGIN

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
                   hipStream_t stream)
{
    int rc = ::gemm_a4w4_asm(
        A, B, A_scale, B_scale, out, kernelName, bias, alpha, beta, bpreshuffle, log2_k_split, stream);
    if(rc != 0)
    {
        const char* msg = ::aiter_get_last_error();
        throw std::runtime_error(msg ? msg : "aiter gemm_a4w4_asm failed");
    }
}

QOLA_NS_END
