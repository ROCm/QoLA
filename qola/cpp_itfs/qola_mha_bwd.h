// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// QoLA cpp_itfs wrapper for AITER's mha_bwd kernel.
#pragma once

#include <cstddef>

#include "qola_common.h"
#include "mha_bwd.h"  // aiter::mha_bwd_args, aiter::mha_bwd()
#if ENABLE_CK
// CK-full build: pull stream_config from the real Composable Kernel headers.
// When ENABLE_CK=0 (asm-v3-only build, e.g. gfx1250) ck_tile::stream_config is
// already provided by ck_tile_shim.h via mha_bwd.h -> aiter_hip_common.h, and
// the CK include path is not on the compile line.
#include "fmha_bwd.hpp"  // fmha_bwd_traits, fmha_bwd_launcher
#include "ck_tile/host/stream_config.hpp"
#endif

QOLA_NS_BEGIN

__attribute__((visibility("default")))
float mha_bwd(const aiter::mha_bwd_args& args, const ck_tile::stream_config& stream_config);

#if ENABLE_CK
// Device workspace bytes the CK (v2) bwd path needs for its launcher metadata and
// dq_acc accumulator, computed host-side from the traits (no kernel launch).
// Exposed so ahead-of-time callers can reserve the buffer their workspace_alloc
// callback carves from: the underlying fmha_bwd_launcher symbol is forced local by
// QoLA's export script, so this query must be evaluated inside the QoLA library.
// CK-free builds (ENABLE_CK==0, e.g. the gfx1250 v3-only tier) have no v2 launcher
// and no fmha_bwd_traits, so the query is gated out alongside its dependencies.
__attribute__((visibility("default")))
size_t mha_bwd_workspace_size(const fmha_bwd_traits& traits);
#endif

QOLA_NS_END
