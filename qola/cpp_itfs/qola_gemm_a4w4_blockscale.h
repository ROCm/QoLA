// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs wrapper for AITER's CK a4w4 blockscale GEMM.
#pragma once

#include <string>

#include "qola_common.h"
#include "aiter_tensor.h"  // aiter_tensor_t

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
