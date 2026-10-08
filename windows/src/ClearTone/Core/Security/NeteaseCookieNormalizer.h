#pragma once

#include <QString>

namespace ct {

class NeteaseCookieNormalizer {
public:
    static QString normalize(const QString& raw);
    static QString normalized(const QString& raw);
};

} // namespace ct
