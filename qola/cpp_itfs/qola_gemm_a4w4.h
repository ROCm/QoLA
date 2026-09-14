// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's gemm_a4w4_blockscale.
#pragma once
#include "qola_common.h"
#include "gemm_a4w4_blockscale.h" // aiter::gemm_a4w4_blockscale, aiter_tensor_t
#include <string>

QOLA_NS_BEGIN

__attribute__((visibility("default")))
aiter_tensor_t& gemm_a4w4_blockscale(aiter_tensor_t& XQ,
                                      aiter_tensor_t& WQ,
                                      aiter_tensor_t& x_scale,
                                      aiter_tensor_t& w_scale,
                                      aiter_tensor_t& Y,
                                      int splitK,
                                      hipStream_t stream,
                                      std::string kernelName = "");

QOLA_NS_END
