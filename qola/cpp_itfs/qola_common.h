// SPDX-License-Identifier: MIT
// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#pragma once

#include <hip/hip_runtime.h>
#include "qola_config.h"

// Allow consumers to wrap exports in a unique namespace to prevent symbol
// collisions when multiple QoLA-built libraries coexist in one process.
//   QOLA_NAMESPACE=te  ->  namespace qola { namespace te { ... } }
//   (unset)            ->  namespace qola { ... }
#ifdef QOLA_NAMESPACE
#define QOLA_NS_BEGIN namespace qola { namespace QOLA_NAMESPACE {
#define QOLA_NS_END   } }
#define QOLA_NS(sym)  qola::QOLA_NAMESPACE::sym
#else
#define QOLA_NS_BEGIN namespace qola {
#define QOLA_NS_END   }
#define QOLA_NS(sym)  qola::sym
#endif

// C-linkage exports cannot live in a namespace, so the same collision
// avoidance is applied as a symbol prefix instead.
//   QOLA_NAMESPACE=te  ->  QOLA_C(foo) == qola_te_foo
//   (unset)            ->  QOLA_C(foo) == qola_foo
// Consumers get the correct spelling for free by including the generated
// qola_config.h, so they never hardcode the namespace.
#define QOLA_C_CAT_(a, b) a##b
#define QOLA_C_CAT(a, b)  QOLA_C_CAT_(a, b)
#ifdef QOLA_NAMESPACE
#define QOLA_C(sym) QOLA_C_CAT(QOLA_C_CAT(qola_, QOLA_NAMESPACE), QOLA_C_CAT(_, sym))
#else
#define QOLA_C(sym) QOLA_C_CAT(qola_, sym)
#endif

#ifdef __cplusplus
#define QOLA_C_BEGIN extern "C" {
#define QOLA_C_END   }
#else
#define QOLA_C_BEGIN
#define QOLA_C_END
#endif

#define QOLA_EXPORT __attribute__((visibility("default")))
