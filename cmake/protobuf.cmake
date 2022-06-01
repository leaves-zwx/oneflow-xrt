include(ExternalProject)

set(PROTOBUF_INSTALL_DIR ${CMAKE_CURRENT_BINARY_DIR}/install/protobuf)
set(PROTOBUF_INSTALL_INCLUDEDIR include)
set(PROTOBUF_INSTALL_LIBDIR lib)
set(PROTOBUF_INSTALL_BINDIR bin)
set(PROTOBUF_INCLUDE_DIR ${PROTOBUF_INSTALL_DIR}/${PROTOBUF_INSTALL_INCLUDEDIR})
set(PROTOBUF_LIBRARY_DIR ${PROTOBUF_INSTALL_DIR}/${PROTOBUF_INSTALL_LIBDIR})
set(PROTOBUF_BINARY_DIR ${PROTOBUF_INSTALL_DIR}/${PROTOBUF_INSTALL_BINDIR})

set(PROTOBUF_SRC_DIR ${CMAKE_CURRENT_BINARY_DIR}/protobuf/src/protobuf/src)
set(PROTOBUF_URL "https://github.com/protocolbuffers/protobuf/archive/v3.16.0.zip")
set(PROTOBUF_MD5 83c982b55cbe5ec390b28c8f812da779)

if(WIN32)
  set(PROTOBUF_LIBRARY_NAMES libprotobufd.lib)
  set(PROTOC_EXECUTABLE_NAME protoc.exe)
  set(PROTOBUF_ADDITIONAL_CMAKE_OPTIONS -Dprotobuf_MSVC_STATIC_RUNTIME:BOOL=ON -A x64)
else()
  if(BUILD_SHARED_LIBS)
    if("${CMAKE_SHARED_LIBRARY_SUFFIX}" STREQUAL ".dylib")
      set(PROTOBUF_LIBRARY_NAMES libprotobuf.dylib)
    elseif("${CMAKE_SHARED_LIBRARY_SUFFIX}" STREQUAL ".so")
      set(PROTOBUF_LIBRARY_NAMES libprotobuf.so)
    else()
      message(FATAL_ERROR "${CMAKE_SHARED_LIBRARY_SUFFIX} not support for protobuf")
    endif()
    set(PROTOBUF_BUILD_SHARED_LIBS ON)
  else()
    set(PROTOBUF_LIBRARY_NAMES libprotobuf.a)
    set(PROTOBUF_BUILD_SHARED_LIBS OFF)
  endif()
  set(PROTOC_EXECUTABLE_NAME protoc)
endif()

foreach(LIBRARY_NAME ${PROTOBUF_LIBRARY_NAMES})
  list(APPEND PROTOBUF_STATIC_LIBRARIES ${PROTOBUF_LIBRARY_DIR}/${LIBRARY_NAME})
endforeach()

set(PROTOBUF_PROTOC_EXECUTABLE ${PROTOBUF_BINARY_DIR}/${PROTOC_EXECUTABLE_NAME})

ExternalProject_Add(
  protobuf
  PREFIX protobuf
  URL ${PROTOBUF_URL}
  URL_MD5 ${PROTOBUF_MD5}
  UPDATE_COMMAND ""
  BUILD_IN_SOURCE 1
  SOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/protobuf/src/protobuf
  SOURCE_SUBDIR cmake
  BUILD_BYPRODUCTS ${PROTOBUF_STATIC_LIBRARIES}
  CMAKE_CACHE_ARGS
    -DCMAKE_C_COMPILER_LAUNCHER:STRING=${CMAKE_C_COMPILER_LAUNCHER}
    -DCMAKE_CXX_COMPILER_LAUNCHER:STRING=${CMAKE_CXX_COMPILER_LAUNCHER}
    -DCMAKE_POLICY_DEFAULT_CMP0074:STRING=NEW
    -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
    -DCMAKE_VERBOSE_MAKEFILE:BOOL=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
    -DZLIB_ROOT:PATH=${ZLIB_INSTALL}
    -Dprotobuf_WITH_ZLIB:BOOL=${WITH_ZLIB}
    -DCMAKE_CXX_FLAGS_DEBUG:STRING=${CMAKE_CXX_FLAGS_DEBUG}
    -DBUILD_SHARED_LIBS:BOOL=${PROTOBUF_BUILD_SHARED_LIBS}
    -Dprotobuf_BUILD_SHARED_LIBS:BOOL=${PROTOBUF_BUILD_SHARED_LIBS}
    -Dprotobuf_BUILD_TESTS:BOOL=OFF
    -DCMAKE_INSTALL_PREFIX:STRING=${PROTOBUF_INSTALL_DIR}
    -DCMAKE_INSTALL_INCLUDEDIR:STRING=${PROTOBUF_INSTALL_INCLUDEDIR}
    -DCMAKE_INSTALL_LIBDIR:STRING=${PROTOBUF_INSTALL_LIBDIR}
    -DCMAKE_INSTALL_BINDIR:STRING=${PROTOBUF_INSTALL_BINDIR}
    -DCMAKE_INSTALL_MESSAGE:STRING=${CMAKE_INSTALL_MESSAGE}
    -Dprotobuf_DEBUG_POSTFIX:STRING=
    ${PROTOBUF_ADDITIONAL_CMAKE_OPTIONS})

# add_library(protobuf UNKNOWN IMPORTED)
# set_property(TARGET protobuf PROPERTY IMPORTED_LOCATION "${PROTOBUF_STATIC_LIBRARIES}")

if(NOT PROTOBUF_GENERATE_CPP)
  set(PROTOBUF_GENERATE_CPP_APPEND_PATH TRUE)

  function(PROTOBUF_GENERATE_CPP SRCS HDRS)
    if(NOT ARGN)
      message(SEND_ERROR "Error: PROTOBUF_GENERATE_CPP() called without any proto files")
      return()
    endif()

    if(PROTOBUF_GENERATE_CPP_APPEND_PATH)
      # Create an include path for each file specified
      foreach(FIL ${ARGN})
        get_filename_component(ABS_FIL ${FIL} ABSOLUTE)
        get_filename_component(ABS_PATH ${ABS_FIL} PATH)
        list(FIND _protobuf_include_path ${ABS_PATH} _contains_already)
        if(${_contains_already} EQUAL -1)
            list(APPEND _protobuf_include_path -I ${ABS_PATH})
        endif()
      endforeach()
    else()
      set(_protobuf_include_path -I ${CMAKE_CURRENT_SOURCE_DIR})
    endif()

    if(DEFINED PROTOBUF_IMPORT_DIRS)
      foreach(DIR ${PROTOBUF_IMPORT_DIRS})
        get_filename_component(ABS_PATH ${DIR} ABSOLUTE)
        list(FIND _protobuf_include_path ${ABS_PATH} _contains_already)
        if(${_contains_already} EQUAL -1)
            list(APPEND _protobuf_include_path -I ${ABS_PATH})
        endif()
      endforeach()
    endif()

    set(${SRCS})
    set(${HDRS})
    foreach(FIL ${ARGN})
      get_filename_component(ABS_FIL ${FIL} ABSOLUTE)
      get_filename_component(FIL_WE ${FIL} NAME_WE)

      list(APPEND ${SRCS} "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}.pb.cc")
      list(APPEND ${HDRS} "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}.pb.h")

      add_custom_command(
        OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}.pb.cc"
               "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}.pb.h"
        COMMAND  ${PROTOBUF_PROTOC_EXECUTABLE}
        ARGS --cpp_out  ${CMAKE_CURRENT_BINARY_DIR} ${_protobuf_include_path} ${ABS_FIL}
        DEPENDS ${ABS_FIL} ${PROTOBUF_PROTOC_EXECUTABLE}
        COMMENT "Running C++ protocol buffer compiler on ${FIL}"
        VERBATIM )
    endforeach()

    set_source_files_properties(${${SRCS}} ${${HDRS}} PROPERTIES GENERATED TRUE)
    set(${SRCS} ${${SRCS}} PARENT_SCOPE)
    set(${HDRS} ${${HDRS}} PARENT_SCOPE)
  endfunction()
endif()
