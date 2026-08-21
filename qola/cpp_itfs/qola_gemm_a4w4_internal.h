// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Internal helpers shared by the a4w4 cpp_itfs entry points.  Not exported to
// consumers -- it includes AITER headers, which is exactly what the public
// qola_gemm_a4w4.h exists to keep out of downstream translation units.
#pragma once

#include <cstddef>
#include <cstring>
#include <exception>

#include "aiter_tensor.h"  // aiter_tensor_t, AiterDtype
#include "qola_gemm_a4w4.h"

namespace qola_detail {

inline AiterDtype to_aiter_dtype(int dtype)
{
    switch(dtype)
    {
    case QOLA_DTYPE_FP4X2: return AITER_DTYPE_fp4x2;
    case QOLA_DTYPE_E8M0: return AITER_DTYPE_fp8_e8m0;
    case QOLA_DTYPE_BF16: return AITER_DTYPE_bf16;
    case QOLA_DTYPE_FP16: return AITER_DTYPE_fp16;
    case QOLA_DTYPE_FP32: return AITER_DTYPE_fp32;
    case QOLA_DTYPE_U8: return AITER_DTYPE_u8;
    case QOLA_DTYPE_I8: return AITER_DTYPE_i8;
    default: return AITER_DTYPE_u8;
    }
}

// Build an aiter_tensor_t from the public descriptor.  Shares the caller's
// device pointer; no ownership is transferred.
inline aiter_tensor_t to_aiter_tensor(const qola_tensor_t& d)
{
    aiter_tensor_t t{};
    t.ptr       = d.ptr;
    t.ndim      = d.ndim;
    size_t numel = (d.ndim > 0) ? 1 : 0;
    for(int i = 0; i < d.ndim && i < 8; ++i)
    {
        t.shape[i]   = d.shape[i];
        t.strides[i] = d.strides[i];
        numel *= static_cast<size_t>(d.shape[i]);
    }
    t.numel_    = numel;
    t.dtype_    = to_aiter_dtype(d.dtype);
    t.device_id = d.device_id;
    return t;
}

// AITER's AITER_CHECK routes through aiter_detail::check_fail, which calls
// std::abort() unless the thread-local g_aiter_can_throw is set.  AITER's own
// C entry points flip it for the duration of a call (see
// csrc/include/aiter_ctypes_error.h) which is why the ASM path already reports
// failures as a status code; the CK blockscale path is a plain C++ function
// and has no such wrapper.  QoLA's C ABI promises status codes rather than
// process death, so it must establish the same guarantee itself.
//
// Save/restore rather than unconditionally clearing, so nesting inside an
// AITER entry point that already set the flag is harmless.
class CanThrowGuard
{
    public:
    CanThrowGuard()
        : prev_(aiter_detail::g_aiter_can_throw)
    {
        aiter_detail::g_aiter_can_throw = true;
    }
    ~CanThrowGuard() { aiter_detail::g_aiter_can_throw = prev_; }

    CanThrowGuard(const CanThrowGuard&)            = delete;
    CanThrowGuard& operator=(const CanThrowGuard&) = delete;

    private:
    bool prev_;
};

inline void set_error(char* err_buf, size_t err_buf_size, const char* msg)
{
    if(err_buf == nullptr || err_buf_size == 0)
        return;
    if(msg == nullptr)
        msg = "unknown error";
    std::strncpy(err_buf, msg, err_buf_size - 1);
    err_buf[err_buf_size - 1] = '\0';
}

// Runs `fn`, translating any escaping exception into the C status/message
// contract documented in qola_gemm_a4w4.h.
template <typename Fn>
inline int guarded(char* err_buf, size_t err_buf_size, Fn&& fn)
{
    CanThrowGuard can_throw;
    try
    {
        fn();
    }
    catch(const std::exception& e)
    {
        set_error(err_buf, err_buf_size, e.what());
        return 1;
    }
    catch(...)
    {
        set_error(err_buf, err_buf_size, "unknown non-std exception");
        return 1;
    }
    return 0;
}

} // namespace qola_detail
