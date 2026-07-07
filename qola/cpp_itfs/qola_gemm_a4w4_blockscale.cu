// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's CK a4w4 blockscale GEMM.

#include "qola_gemm_a4w4_blockscale.h"

#include "gemm_a4w4_blockscale.h"  // aiter::gemm_a4w4_blockscale

QOLA_NS_BEGIN

aiter_tensor_t& gemm_a4w4_blockscale(aiter_tensor_t& XQ,
                                     aiter_tensor_t& WQ,
                                     aiter_tensor_t& x_scale,
                                     aiter_tensor_t& w_scale,
                                     aiter_tensor_t& Y,
                                     int splitK,
                                     hipStream_t stream,
                                     std::string kernelName)
{
    return ::aiter::gemm_a4w4_blockscale(
        XQ, WQ, x_scale, w_scale, Y, splitK, stream, kernelName);
}

QOLA_NS_END
