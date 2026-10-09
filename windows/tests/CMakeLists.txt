find_package(Qt6 REQUIRED COMPONENTS Test)

file(GLOB CT_TEST_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tst_*.cpp")

foreach(test_source ${CT_TEST_SOURCES})
    get_filename_component(test_name "${test_source}" NAME_WE)
    add_executable("${test_name}" "${test_source}")
    target_link_libraries("${test_name}" PRIVATE cleartone_lib Qt6::Test)
    add_test(NAME "${test_name}" COMMAND "${test_name}")
    # 界面布局测试要真实平台字体/窗口度量；Windows 的 offscreen 插件没有系统字体，
    # 文字尺寸断言会全挂，这里在 Windows 上改用原生 windows 平台。
    set(ct_test_platform "offscreen")
    if(WIN32 AND test_name STREQUAL "tst_gui_layout")
        set(ct_test_platform "windows")
    endif()
    set_tests_properties("${test_name}" PROPERTIES
        ENVIRONMENT "CLEARTONE_TEST_STORAGE_DIR=${CMAKE_CURRENT_BINARY_DIR}/storage/${test_name};QT_QPA_PLATFORM=${ct_test_platform}"
        TIMEOUT 120)
endforeach()
