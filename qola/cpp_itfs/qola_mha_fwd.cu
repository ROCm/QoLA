// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// Thin cpp_itfs entry point for AITER's mha_fwd.

#include "qola_mha_fwd.h"

QOLA_NS_BEGIN

float mha_fwd(const aiter::mha_fwd_args& args, const ck_tile::stream_config& stream_config)
{
    return ::aiter::mha_fwd(args, stream_config);
}

#if FAV_NATIVE_ON
int mha_fwd_calculate_num_splits(const aiter::mha_fwd_args& args)
{
    return ::aiter::mha_fwd_calculate_num_splits(args);
}

size_t mha_fwd_workspace_size(const aiter::mha_fwd_args& a)
{
    return ::aiter::mha_fwd_workspace_size(a);
}
#endif

QOLA_NS_END
