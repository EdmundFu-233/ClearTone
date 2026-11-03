#pragma once

#include <QString>
#include <optional>

namespace ct::windowsShortcuts {

bool add(const QString& executable, const QString& programsDirectory, QString* error = nullptr);
bool remove(const QString& programsDirectory, QString* error = nullptr);
std::optional<int> runCommandLine(int argc, char** argv);

} // namespace ct::windowsShortcuts
