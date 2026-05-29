// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs wrapper for AITER's mha_bwd kernel.
#pragma once

#include "qola_common.h"
#include "mha_bwd.h"  // aiter::mha_bwd_args, aiter::mha_bwd()
#if ENABLE_CK
// CK-full build: pull stream_config from the real Composable Kernel headers.
// When ENABLE_CK=0 (asm-v3-only build, e.g. gfx1250) ck_tile::stream_config is
// already provided by ck_tile_shim.h via mha_bwd.h -> aiter_hip_common.h, and
// the CK include path is not on the compile line.
#include "ck_tile/host/stream_config.hpp"
#endif

QOLA_NS_BEGIN

__attribute__((visibility("default")))
float mha_bwd(const aiter::mha_bwd_args& args, const ck_tile::stream_config& stream_config);

QOLA_NS_END
