#include "Features/Shared/PlaceholderView.h"

#include "DesignSystem/CTTheme.h"

#include <QLabel>
#include <QVBoxLayout>

namespace ct {

PlaceholderView::PlaceholderView(const QString& title, QWidget* parent)
    : QWidget(parent)
{
    auto* layout = new QVBoxLayout(this);
    layout->setAlignment(Qt::AlignCenter);
    auto* label = new QLabel(title, this);
    label->setAlignment(Qt::AlignCenter);
    label->setStyleSheet(QStringLiteral("color: %1; font-size: 18px;").arg(CTColors::textSecondary().name()));
    layout->addWidget(label);
}

} // namespace ct
