// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs wrapper for AITER's mha_fwd kernel.
#pragma once

#include "qola_common.h"
#include "mha_fwd.h"  // aiter::mha_fwd_args, aiter::mha_fwd()
#if ENABLE_CK
// CK-free builds (ENABLE_CK==0, e.g. the gfx1250 v3-only tier) get
// ck_tile::stream_config from ck_tile_shim.h via aiter_hip_common.h; pulling the
// real header in too would redefine the struct. Mirror mha_fwd.h's guard.
#include "ck_tile/host/stream_config.hpp"
#endif

QOLA_NS_BEGIN

__attribute__((visibility("default")))
float mha_fwd(const aiter::mha_fwd_args& args, const ck_tile::stream_config& stream_config);

QOLA_NS_END
