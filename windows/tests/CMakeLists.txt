find_package(Qt6 REQUIRED COMPONENTS Test)

file(GLOB CT_TEST_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tst_*.cpp")

foreach(test_source ${CT_TEST_SOURCES})
    get_filename_component(test_name "${test_source}" NAME_WE)
    add_executable("${test_name}" "${test_source}")
    target_link_libraries("${test_name}" PRIVATE cleartone_lib Qt6::Test)
    add_test(NAME "${test_name}" COMMAND "${test_name}")
    set_tests_properties("${test_name}" PROPERTIES
        ENVIRONMENT "CLEARTONE_TEST_STORAGE_DIR=${CMAKE_CURRENT_BINARY_DIR}/storage/${test_name};QT_QPA_PLATFORM=offscreen"
        TIMEOUT 120)
endforeach()
