#pragma once

#include <QString>

namespace ct {

class StoragePaths {
public:
    // 环境变量 CLEARTONE_STORAGE_DIR / CLEARTONE_TEST_STORAGE_DIR 可重定向，
    // 离线测试脚本依赖这一点把持久化隔离到临时目录。
    static QString root();
};

} // namespace ct
