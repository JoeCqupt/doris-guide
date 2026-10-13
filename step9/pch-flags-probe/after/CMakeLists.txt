cmake_minimum_required(VERSION 3.20)
project(PchFlagsProbe LANGUAGES C CXX)
set(ENABLE_PCH ON)
set(COMPILER_CLANG ON)
set(SRC_DIR "/Users/jiangyuan/doris-guide/step9/pch-flags-probe/")
# Only apply the OpenMP-related adjustments when PCH is enabled, to avoid
# impacting non-PCH builds.
if (ENABLE_PCH)
    # Ensure consistent OpenMP usage across the whole BE (including PCH) to avoid
    # AST version mismatches in Clang when some targets use OpenMP and others don't.
    # We try to find OpenMP quietly and, if found, apply its flags globally.
    find_package(OpenMP QUIET)
    if (OpenMP_CXX_FOUND OR OpenMP_FOUND)
        if (DEFINED OpenMP_CXX_FLAGS AND NOT OpenMP_CXX_FLAGS STREQUAL "")
            # Apply the OpenMP flags to all C++ compilations so PCH and all TUs match.
            # FindOpenMP can return multiple arguments, such as AppleClang's -Xclang -fopenmp.
            add_compile_options("$<$<COMPILE_LANGUAGE:CXX>:SHELL:${OpenMP_CXX_FLAGS}>")
        endif()
        # Ensure final link includes the OpenMP runtime when needed.
        if (TARGET OpenMP::OpenMP_CXX)
            set(DORIS_LINK_LIBS ${DORIS_LINK_LIBS} OpenMP::OpenMP_CXX)
        endif()
    endif()

    add_library(pch STATIC ${SRC_DIR}pch/pch.cc)
    target_precompile_headers(
        pch
        PUBLIC
            ${SRC_DIR}pch/pch.h
    )
    if (OpenMP_CXX_FOUND OR OpenMP_FOUND)
        # Propagate OpenMP to the PCH target so that sources compiled with
        # -fopenmp can reuse the PCH without version conflicts.
        target_link_libraries(pch PUBLIC OpenMP::OpenMP_CXX)
        # Also add flags explicitly to be robust if usage requirements don’t apply during PCH.
        if (DEFINED OpenMP_CXX_FLAGS AND NOT OpenMP_CXX_FLAGS STREQUAL "")
            target_compile_options(pch PUBLIC "SHELL:${OpenMP_CXX_FLAGS}")
        endif()
        # Copy usage requirements from the imported OpenMP target onto PCH.
        if (TARGET OpenMP::OpenMP_CXX)
            get_property(_omp_copts TARGET OpenMP::OpenMP_CXX PROPERTY INTERFACE_COMPILE_OPTIONS)
            if (_omp_copts)
                target_compile_options(pch PUBLIC ${_omp_copts})
            endif()
            get_property(_omp_cdefs TARGET OpenMP::OpenMP_CXX PROPERTY INTERFACE_COMPILE_DEFINITIONS)
            if (_omp_cdefs)
                target_compile_definitions(pch PUBLIC ${_omp_cdefs})
            endif()
            get_property(_omp_cincs TARGET OpenMP::OpenMP_CXX PROPERTY INTERFACE_INCLUDE_DIRECTORIES)
            if (_omp_cincs)
                target_include_directories(pch PUBLIC ${_omp_cincs})
            endif()
        endif()
    endif()
    if (COMPILER_CLANG)
        target_compile_options(pch PRIVATE -Xclang -fno-pch-timestamp)
    endif()
endif()


add_executable(probe "/Users/jiangyuan/doris-guide/step9/pch-flags-probe/main.cpp")
target_link_libraries(probe PRIVATE pch)
target_precompile_headers(probe REUSE_FROM pch)
