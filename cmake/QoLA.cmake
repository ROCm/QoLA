# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# CMake integration for QoLA's ahead-of-time AITER kernel builder.
#
# This file owns everything between "here is a manifest" and "here are the
# headers and libraries to link", split into two independently callable
# phases:
#
#   qola_checkout_aiter()  — parse the manifest's pinned AITER commit and sync
#                            the source tree to it (or honour an override).
#   qola_build_modules()   — run `qola build --skip-checkout` for one module
#                            group and locate the resulting headers / .so's.
#
# Two-phase usage — check out once (optionally per group), build later:
#
#   include(${QOLA_DIR}/cmake/QoLA.cmake)
#   qola_checkout_aiter(
#     MANIFEST   ${CMAKE_CURRENT_LIST_DIR}/qola_manifest.toml
#     AITER_DIR  ${CMAKE_CURRENT_BINARY_DIR}/qola/third_party/aiter
#     GROUPS     aiter_gemm
#     OUT_DIR    QOLA_AITER_SOURCE_DIR)
#
#   # ...anything that needs AITER sources at configure time...
#
#   qola_build_modules(
#     GROUP        aiter_gemm
#     MANIFEST     ${CMAKE_CURRENT_LIST_DIR}/qola_manifest.toml
#     BUILD_DIR    ${CMAKE_CURRENT_BINARY_DIR}/qola
#     AITER_DIR    ${QOLA_AITER_SOURCE_DIR}
#     ARCHS        ${MY_ARCHS}
#     OUT_INCLUDE_DIR  QOLA_GEMM_INCLUDE_DIR
#     OUT_LIB_DIR      QOLA_GEMM_LIB_DIR
#     OUT_LIBS         QOLA_GEMM_LIBS)
#
# Single-call usage — qola_add_modules() does both phases for one group:
#
#   qola_add_modules(
#     GROUP        aiter_gemm
#     MANIFEST     ${CMAKE_CURRENT_LIST_DIR}/qola_manifest.toml
#     BUILD_DIR    ${CMAKE_CURRENT_BINARY_DIR}/qola
#     ARCHS        ${MY_ARCHS}
#     OUT_INCLUDE_DIR  QOLA_GEMM_INCLUDE_DIR
#     OUT_LIB_DIR      QOLA_GEMM_LIB_DIR
#     OUT_LIBS         QOLA_GEMM_LIBS
#     OUT_AITER_DIR    QOLA_AITER_SOURCE_DIR)
#
# Every group in a manifest shares one AITER tree (one commit, one patch set),
# so several groups can be built from a single checkout.
#
# Environment overrides honoured by this module:
#   QOLA_AITER_SOURCE_DIR
#       Build against an existing AITER tree and skip checkout entirely.
#   QOLA_PREBUILT_DIR_<GROUP>
#       Skip the build and consume prebuilt <dir>/lib and <dir>/include.

include_guard(GLOBAL)

set(QOLA_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")
get_filename_component(QOLA_ROOT_DIR "${QOLA_CMAKE_DIR}/.." ABSOLUTE)

# Extract the single `aiter_commit = "..."` line from a manifest.
function(qola_read_manifest_commit manifest out_var)
  if(NOT EXISTS "${manifest}")
    message(FATAL_ERROR "[QoLA] Manifest not found: ${manifest}")
  endif()
  file(STRINGS "${manifest}" _lines
       REGEX "^[ \t]*aiter_commit[ \t]*=[ \t]*\"[^\"]+\"")
  list(LENGTH _lines _count)
  if(NOT _count EQUAL 1)
    message(FATAL_ERROR
            "[QoLA] Expected exactly one 'aiter_commit = \"...\"' line in "
            "${manifest}, found ${_count}.")
  endif()
  list(GET _lines 0 _line)
  string(REGEX MATCH "\"([^\"]+)\"" _unused "${_line}")
  if("${CMAKE_MATCH_1}" STREQUAL "")
    message(FATAL_ERROR
            "[QoLA] Failed to parse 'aiter_commit' from ${manifest}.")
  endif()
  set(${out_var} "${CMAKE_MATCH_1}" PARENT_SCOPE)
endfunction()

# Locate a Python interpreter once, reusing the caller's if already found.
function(qola_find_python out_var)
  if(Python_EXECUTABLE)
    set(${out_var} "${Python_EXECUTABLE}" PARENT_SCOPE)
    return()
  endif()
  find_package(Python COMPONENTS Interpreter QUIET)
  if(NOT Python_EXECUTABLE)
    message(FATAL_ERROR
            "[QoLA] Python interpreter not found; it is required to check out "
            "and build AITER kernels.")
  endif()
  set(${out_var} "${Python_EXECUTABLE}" PARENT_SCOPE)
endfunction()

# Run `python -m qola.cli <args...>`, failing the configure step on error.
function(qola_run_cli what)
  qola_find_python(_py)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E env "PYTHONPATH=${QOLA_ROOT_DIR}:$ENV{PYTHONPATH}"
            "${_py}" -m qola.cli ${ARGN}
    RESULT_VARIABLE _rc
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE _err
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "[QoLA] ${what} failed.\n${_out}\n${_err}")
  endif()
endfunction()

# Resolve the QOLA_PREBUILT_DIR_<GROUP> bypass for one group.
#
# Sets <out_var> to the prebuilt directory, or "" when the group is not
# bypassed.  A prebuilt group needs neither a checkout nor a build.
function(qola_prebuilt_dir group out_var)
  string(TOUPPER "${group}" _group_uc)
  set(_env "QOLA_PREBUILT_DIR_${_group_uc}")
  if(DEFINED ENV{${_env}} AND NOT "$ENV{${_env}}" STREQUAL "")
    set(${out_var} "$ENV{${_env}}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

# Sync the AITER source tree named by a manifest, unless overridden.
#
# This is the checkout phase on its own — call it when the tree must exist
# before the kernels are built (deferred / per-group builds, or when other
# parts of the configure step need AITER headers):
#
#   qola_checkout_aiter(
#     MANIFEST   ${_manifest}
#     AITER_DIR  ${CMAKE_BINARY_DIR}/qola/third_party/aiter
#     GROUPS     aiter_gemm ck_fused_attn   # optional; validated, not filtered
#     OUT_DIR    AITER_SOURCE_DIR)
#
#   qola_build_modules(GROUP aiter_gemm AITER_DIR ${AITER_SOURCE_DIR} ...)
#
# Destination is AITER_DIR, else DEFAULT_DIR; one of the two is required.
# GROUPS does not change the resulting tree — a manifest pins one commit and
# one patch set, so all its groups share a checkout — it only fails the
# configure step early on a group name the manifest does not declare.
#
# Sets <OUT_DIR> to the tree to build against.  Idempotent across consumers:
# the first caller performs the checkout and later callers with the same
# commit + destination short-circuit.
function(qola_checkout_aiter)
  set(_opts)
  set(_one MANIFEST AITER_DIR DEFAULT_DIR OUT_DIR)
  set(_multi GROUPS)
  cmake_parse_arguments(QCA "${_opts}" "${_one}" "${_multi}" ${ARGN})

  if(NOT QCA_MANIFEST)
    message(FATAL_ERROR "[QoLA] qola_checkout_aiter: MANIFEST is required.")
  endif()
  if(QCA_AITER_DIR)
    set(QCA_DEFAULT_DIR "${QCA_AITER_DIR}")
  endif()
  if(NOT QCA_DEFAULT_DIR)
    message(FATAL_ERROR
            "[QoLA] qola_checkout_aiter: one of AITER_DIR or DEFAULT_DIR is "
            "required (destination for the AITER source tree).")
  endif()

  set(_aiter_dir "${QCA_DEFAULT_DIR}")
  set(_skip FALSE)
  foreach(_env QOLA_AITER_SOURCE_DIR)
    if(DEFINED ENV{${_env}} AND NOT "$ENV{${_env}}" STREQUAL "")
      set(_aiter_dir "$ENV{${_env}}")
      set(_skip TRUE)
      message(STATUS "[QoLA] Using AITER source from ${_env}=${_aiter_dir}; skipping checkout.")
      break()
    endif()
  endforeach()

  qola_read_manifest_commit("${QCA_MANIFEST}" _sha)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${QCA_MANIFEST}")

  if(NOT _skip)
    # Two consumers sharing a manifest must not each re-run the checkout:
    # it is idempotent but not free, and it re-touches patched headers.
    get_property(_done GLOBAL PROPERTY QOLA_CHECKOUT_DONE_${_sha}_${_aiter_dir})
    if(_done)
      message(STATUS "[QoLA] AITER already synced to ${_sha} at ${_aiter_dir}.")
    else()
      set(_group_args)
      foreach(_group ${QCA_GROUPS})
        list(APPEND _group_args --group "${_group}")
      endforeach()
      qola_run_cli("AITER checkout to ${_sha}"
                   checkout
                   --manifest "${QCA_MANIFEST}"
                   --aiter-root "${_aiter_dir}"
                   ${_group_args})
      set_property(GLOBAL PROPERTY QOLA_CHECKOUT_DONE_${_sha}_${_aiter_dir} TRUE)
      message(STATUS "[QoLA] Synced ${_aiter_dir} to ${_sha}")
    endif()
  endif()

  if(NOT EXISTS "${_aiter_dir}/csrc/include")
    message(FATAL_ERROR
            "[QoLA] Could not find AITER sources at ${_aiter_dir}/csrc/include.")
  endif()
  set(${QCA_OUT_DIR} "${_aiter_dir}" PARENT_SCOPE)
endfunction()

# Build (or locate prebuilt) kernel libraries for one manifest module group,
# against an AITER tree that has already been checked out.
#
# This is the build phase on its own: it never touches the AITER checkout, so
# a consumer can run qola_checkout_aiter() early (or once for several groups)
# and defer each group's build to whenever it is ready.  AITER_DIR is required
# unless the group is bypassed via QOLA_PREBUILT_DIR_<GROUP>.
#
# Use qola_add_modules() instead when one call should do both phases.
function(qola_build_modules)
  set(_opts)
  set(_one GROUP MANIFEST BUILD_DIR AITER_DIR
           OUT_INCLUDE_DIR OUT_LIB_DIR OUT_LIBS OUT_CONFIG_DIR)
  set(_multi ARCHS LIBS)
  cmake_parse_arguments(QAM "${_opts}" "${_one}" "${_multi}" ${ARGN})

  if(NOT QAM_GROUP)
    message(FATAL_ERROR "[QoLA] qola_build_modules: GROUP is required.")
  endif()
  if(NOT QAM_BUILD_DIR)
    message(FATAL_ERROR "[QoLA] qola_build_modules: BUILD_DIR is required.")
  endif()

  # Prebuilt bypass: consume an existing lib/ + include/ pair.
  qola_prebuilt_dir("${QAM_GROUP}" _prebuilt)
  if(_prebuilt)
    message(STATUS "[QoLA] ${QAM_GROUP}: using prebuilt libraries from ${_prebuilt}")
    set(_include_dir "${_prebuilt}/include")
    set(_lib_dir "${_prebuilt}/lib")
    set(_config_dir "${_prebuilt}/configs")
  else()
    if(NOT QAM_MANIFEST)
      message(FATAL_ERROR "[QoLA] qola_build_modules: MANIFEST is required.")
    endif()
    if(NOT QAM_AITER_DIR)
      message(FATAL_ERROR
              "[QoLA] qola_build_modules: AITER_DIR is required — this "
              "function builds only. Run qola_checkout_aiter() first and pass "
              "its OUT_DIR, or call qola_add_modules() to do both phases.")
    endif()
    if(NOT EXISTS "${QAM_AITER_DIR}/csrc/include")
      message(FATAL_ERROR
              "[QoLA] ${QAM_GROUP}: AITER_DIR ${QAM_AITER_DIR} does not look "
              "like a checked-out AITER tree (no csrc/include). Run "
              "qola_checkout_aiter() before building.")
    endif()
    set(_aiter_dir "${QAM_AITER_DIR}")

    string(REPLACE ";" ";" _archs "${QAM_ARCHS}")
    list(JOIN _archs ";" _archs_str)
    message(STATUS "[QoLA] ${QAM_GROUP}: building kernels for ${_archs_str}")
    qola_run_cli("build of group '${QAM_GROUP}'"
                 build
                 --manifest "${QAM_MANIFEST}"
                 --aiter-root "${_aiter_dir}"
                 --output-dir "${QAM_BUILD_DIR}"
                 --group "${QAM_GROUP}"
                 --arch "${_archs_str}"
                 --skip-checkout)
    set(_include_dir "${QAM_BUILD_DIR}/include")
    set(_lib_dir "${QAM_BUILD_DIR}/lib")
    set(_config_dir "${QAM_BUILD_DIR}/configs")
  endif()

  if(NOT EXISTS "${_include_dir}/qola_config.h")
    message(FATAL_ERROR
            "[QoLA] ${QAM_GROUP}: public headers missing at ${_include_dir}.")
  endif()

  # Resolve the built shared objects.  Explicit LIBS win; otherwise take
  # whatever the group produced in lib/.
  set(_libs)
  if(QAM_LIBS)
    foreach(_lib ${QAM_LIBS})
      if(NOT EXISTS "${_lib_dir}/${_lib}")
        message(FATAL_ERROR
                "[QoLA] ${QAM_GROUP}: expected library ${_lib} not found in ${_lib_dir}.")
      endif()
      list(APPEND _libs "${_lib}")
    endforeach()
  else()
    file(GLOB _found RELATIVE "${_lib_dir}" "${_lib_dir}/*.so")
    if(NOT _found)
      message(FATAL_ERROR "[QoLA] ${QAM_GROUP}: no shared objects in ${_lib_dir}.")
    endif()
    set(_libs ${_found})
  endif()

  if(QAM_OUT_INCLUDE_DIR)
    set(${QAM_OUT_INCLUDE_DIR} "${_include_dir}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_LIB_DIR)
    set(${QAM_OUT_LIB_DIR} "${_lib_dir}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_LIBS)
    set(${QAM_OUT_LIBS} "${_libs}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_CONFIG_DIR)
    set(${QAM_OUT_CONFIG_DIR} "${_config_dir}" PARENT_SCOPE)
  endif()
endfunction()

# Check out AITER (if needed) and build one manifest module group.
#
# Convenience wrapper over qola_checkout_aiter() + qola_build_modules() for
# consumers that want both phases in one call.  Pass AITER_DIR to reuse a tree
# a previous call already prepared; omit it to check out into
# <BUILD_DIR>/third_party/aiter.  A group bypassed via
# QOLA_PREBUILT_DIR_<GROUP> skips both phases.
function(qola_add_modules)
  set(_opts)
  set(_one GROUP MANIFEST BUILD_DIR AITER_DIR
           OUT_INCLUDE_DIR OUT_LIB_DIR OUT_LIBS OUT_AITER_DIR OUT_CONFIG_DIR)
  set(_multi ARCHS LIBS)
  cmake_parse_arguments(QAM "${_opts}" "${_one}" "${_multi}" ${ARGN})

  if(NOT QAM_GROUP)
    message(FATAL_ERROR "[QoLA] qola_add_modules: GROUP is required.")
  endif()
  if(NOT QAM_MANIFEST)
    message(FATAL_ERROR "[QoLA] qola_add_modules: MANIFEST is required.")
  endif()
  if(NOT QAM_BUILD_DIR)
    message(FATAL_ERROR "[QoLA] qola_add_modules: BUILD_DIR is required.")
  endif()

  # A prebuilt group needs no AITER tree at all — don't pay for a checkout.
  qola_prebuilt_dir("${QAM_GROUP}" _prebuilt)
  set(_aiter_dir "${QAM_AITER_DIR}")
  if(NOT _prebuilt AND NOT _aiter_dir)
    qola_checkout_aiter(
      MANIFEST "${QAM_MANIFEST}"
      DEFAULT_DIR "${QAM_BUILD_DIR}/third_party/aiter"
      GROUPS "${QAM_GROUP}"
      OUT_DIR _aiter_dir)
  endif()

  qola_build_modules(
    GROUP "${QAM_GROUP}"
    MANIFEST "${QAM_MANIFEST}"
    BUILD_DIR "${QAM_BUILD_DIR}"
    AITER_DIR "${_aiter_dir}"
    ARCHS ${QAM_ARCHS}
    LIBS ${QAM_LIBS}
    OUT_INCLUDE_DIR _include_dir
    OUT_LIB_DIR _lib_dir
    OUT_LIBS _libs
    OUT_CONFIG_DIR _config_dir)

  # qola_build_modules' PARENT_SCOPE writes land here; re-export to our caller.
  if(QAM_OUT_INCLUDE_DIR)
    set(${QAM_OUT_INCLUDE_DIR} "${_include_dir}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_LIB_DIR)
    set(${QAM_OUT_LIB_DIR} "${_lib_dir}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_LIBS)
    set(${QAM_OUT_LIBS} "${_libs}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_CONFIG_DIR)
    set(${QAM_OUT_CONFIG_DIR} "${_config_dir}" PARENT_SCOPE)
  endif()
  if(QAM_OUT_AITER_DIR)
    set(${QAM_OUT_AITER_DIR} "${_aiter_dir}" PARENT_SCOPE)
  endif()
endfunction()
