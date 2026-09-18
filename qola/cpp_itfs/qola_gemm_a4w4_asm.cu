// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's ASM a4w4 GEMM (f4gemm).

#include "qola_gemm_a4w4_internal.h"

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

extern "C" int QOLA_C(gemm_a4w4_asm)(const qola_tensor_t* A,
                                     const qola_tensor_t* B,
                                     const qola_tensor_t* a_scale,
                                     const qola_tensor_t* b_scale,
                                     const qola_tensor_t* out,
                                     const qola_tensor_t* bias,
                                     const char* kernel_name,
                                     float alpha,
                                     float beta,
                                     int bpreshuffle,
                                     int log2_k_split,
                                     hipStream_t stream,
                                     char* err_buf,
                                     size_t err_buf_size)
{
    if(A == nullptr || B == nullptr || a_scale == nullptr || b_scale == nullptr || out == nullptr)
    {
        qola_detail::set_error(err_buf, err_buf_size, "null tensor descriptor");
        return 1;
    }
    // AITER's entrypoint already reports failures as a status code, so the
    // only thing that can throw here is descriptor translation.
    int rc = 0;
    int guard_rc = qola_detail::guarded(err_buf, err_buf_size, [&] {
        aiter_tensor_t a_a  = qola_detail::to_aiter_tensor(*A);
        aiter_tensor_t a_b  = qola_detail::to_aiter_tensor(*B);
        aiter_tensor_t a_as = qola_detail::to_aiter_tensor(*a_scale);
        aiter_tensor_t a_bs = qola_detail::to_aiter_tensor(*b_scale);
        aiter_tensor_t a_o  = qola_detail::to_aiter_tensor(*out);
        aiter_tensor_t a_bias;
        aiter_tensor_t* a_bias_ptr = nullptr;
        if(bias != nullptr && bias->ptr != nullptr)
        {
            a_bias     = qola_detail::to_aiter_tensor(*bias);
            a_bias_ptr = &a_bias;
        }
        rc = ::gemm_a4w4_asm(&a_a,
                             &a_b,
                             &a_as,
                             &a_bs,
                             &a_o,
                             kernel_name ? kernel_name : "",
                             a_bias_ptr,
                             alpha,
                             beta,
                             bpreshuffle,
                             log2_k_split,
                             stream);
        if(rc != 0)
        {
            const char* msg = ::aiter_get_last_error();
            qola_detail::set_error(
                err_buf, err_buf_size, msg ? msg : "aiter gemm_a4w4_asm failed");
        }
    });
    return guard_rc != 0 ? guard_rc : rc;
}
