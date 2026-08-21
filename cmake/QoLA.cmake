# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# CMake integration for QoLA's ahead-of-time AITER kernel builder.
#
# Consumers include this file and call qola_add_modules() once per module
# group.  It owns everything between "here is a manifest" and "here are the
# headers and libraries to link":
#
#   * parsing the manifest's pinned AITER commit,
#   * syncing the AITER source tree to it (or honouring an override),
#   * invoking `qola build` for the requested group and architectures,
#   * locating the resulting public headers and shared objects.
#
# Usage:
#
#   include(${QOLA_DIR}/cmake/QoLA.cmake)
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
# Environment overrides honoured by this module:
#   QOLA_AITER_SOURCE_DIR / NVTE_AITER_SOURCE_DIR
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

# Sync the AITER source tree named by a manifest, unless overridden.
#
# Sets <out_dir_var> to the tree to build against.  Idempotent across
# consumers: the first caller performs the checkout and later callers with the
# same manifest + destination short-circuit.
function(qola_checkout_aiter)
  set(_opts)
  set(_one MANIFEST DEFAULT_DIR OUT_DIR)
  set(_multi)
  cmake_parse_arguments(QCA "${_opts}" "${_one}" "${_multi}" ${ARGN})

  set(_aiter_dir "${QCA_DEFAULT_DIR}")
  set(_skip FALSE)
  foreach(_env QOLA_AITER_SOURCE_DIR NVTE_AITER_SOURCE_DIR)
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
      qola_run_cli("AITER checkout to ${_sha}"
                   checkout
                   --manifest "${QCA_MANIFEST}"
                   --aiter-root "${_aiter_dir}")
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

# Build (or locate prebuilt) kernel libraries for one manifest module group.
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

  # Prebuilt bypass: consume an existing lib/ + include/ pair.
  string(TOUPPER "${QAM_GROUP}" _group_uc)
  set(_prebuilt_env "QOLA_PREBUILT_DIR_${_group_uc}")
  if(DEFINED ENV{${_prebuilt_env}} AND NOT "$ENV{${_prebuilt_env}}" STREQUAL "")
    set(_prebuilt "$ENV{${_prebuilt_env}}")
    message(STATUS "[QoLA] ${QAM_GROUP}: using prebuilt libraries from ${_prebuilt}")
    set(_include_dir "${_prebuilt}/include")
    set(_lib_dir "${_prebuilt}/lib")
    set(_config_dir "${_prebuilt}/configs")
  else()
    if(QAM_AITER_DIR)
      set(_aiter_dir "${QAM_AITER_DIR}")
    else()
      qola_checkout_aiter(
        MANIFEST "${QAM_MANIFEST}"
        DEFAULT_DIR "${QAM_BUILD_DIR}/third_party/aiter"
        OUT_DIR _aiter_dir)
    endif()

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
    if(QAM_OUT_AITER_DIR)
      set(${QAM_OUT_AITER_DIR} "${_aiter_dir}" PARENT_SCOPE)
    endif()
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
