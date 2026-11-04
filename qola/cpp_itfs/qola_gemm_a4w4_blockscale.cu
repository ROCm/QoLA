// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's CK a4w4 blockscale GEMM.

#include "qola_gemm_a4w4_internal.h"

#include "gemm_a4w4_blockscale.h"  // aiter::gemm_a4w4_blockscale

extern "C" int QOLA_C(gemm_a4w4_blockscale)(const qola_tensor_t* XQ,
                                            const qola_tensor_t* WQ,
                                            const qola_tensor_t* x_scale,
                                            const qola_tensor_t* w_scale,
                                            const qola_tensor_t* Y,
                                            int split_k,
                                            const char* kernel_name,
                                            hipStream_t stream,
                                            char* err_buf,
                                            size_t err_buf_size)
{
    if(XQ == nullptr || WQ == nullptr || x_scale == nullptr || w_scale == nullptr || Y == nullptr)
    {
        qola_detail::set_error(err_buf, err_buf_size, "null tensor descriptor");
        return 1;
    }
    return qola_detail::guarded(err_buf, err_buf_size, [&] {
        aiter_tensor_t a_xq = qola_detail::to_aiter_tensor(*XQ);
        aiter_tensor_t a_wq = qola_detail::to_aiter_tensor(*WQ);
        aiter_tensor_t a_xs = qola_detail::to_aiter_tensor(*x_scale);
        aiter_tensor_t a_ws = qola_detail::to_aiter_tensor(*w_scale);
        aiter_tensor_t a_y  = qola_detail::to_aiter_tensor(*Y);
        ::aiter::gemm_a4w4_blockscale(a_xq,
                                      a_wq,
                                      a_xs,
                                      a_ws,
                                      a_y,
                                      split_k,
                                      stream,
                                      kernel_name ? std::string(kernel_name) : std::string());
    });
}
