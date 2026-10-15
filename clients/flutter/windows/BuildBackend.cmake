# Called by the runner build so flutter run/build includes the matching backend.
if(CONFIG STREQUAL "Debug")
  set(PROFILE_ARGS)
else()
  set(PROFILE_ARGS --release)
endif()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${REPO_ROOT}/target"
    "${CARGO}" build --manifest-path "${REPO_ROOT}/Cargo.toml" --locked
    -p narad --target x86_64-pc-windows-msvc ${PROFILE_ARGS}
  WORKING_DIRECTORY "${REPO_ROOT}"
  RESULT_VARIABLE RESULT)
if(NOT RESULT EQUAL 0)
  message(FATAL_ERROR "Narad Rust backend build failed (${RESULT})")
endif()
