#pragma once

#include <QWidget>

namespace ct {

class PlaceholderView : public QWidget {
    Q_OBJECT

public:
    explicit PlaceholderView(const QString& title, QWidget* parent = nullptr);
};

} // namespace ct
