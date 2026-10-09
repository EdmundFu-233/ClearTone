#include "DesignSystem/CTTheme.h"

#include <QGuiApplication>
#include <QApplication>
#include <QFontDatabase>
#include <QPainter>
#include <QWidget>
#include <QListWidget>
#include <QPushButton>
#include <optional>
#include <QStyleHints>

#include <cmath>

namespace ct {

namespace {
std::optional<bool> themeDark;
CTThemeMode themeMode = CTThemeMode::System;

QString applicationStyle()
{
    return QStringLiteral(R"(
        QWidget { color: %1; font-size: 13px; }
        QLabel { background: transparent; }
        QToolTip { color: %1; background: %2; border: 1px solid %3; padding: 6px; }
        QPushButton { min-height: 24px; border: 1px solid transparent; border-radius: 8px; }
        QPushButton:focus { border: 1px solid %4; }
        QPushButton[ctRole="primary"] { background: %4; color: %8; padding: 6px 18px; font-weight: 600; }
        QPushButton[ctRole="primary"]:hover { background: %5; }
        QPushButton[ctRole="ghost"] { background: %2; color: %1; border: 1px solid %3; padding: 6px 16px; }
        QPushButton[ctRole="ghost"]:hover { background: %6; border-color: %4; }
        QPushButton[ctRole="link"] { background: transparent; color: %7; padding: 4px 8px; }
        QPushButton[ctRole="link"]:hover { color: %4; background: %6; }
        QPushButton:disabled { color: %7; }
        QLineEdit, QComboBox, QDoubleSpinBox, QTextEdit, QPlainTextEdit {
            background: %2; color: %1; border: 1px solid %3; border-radius: 8px; padding: 8px 10px;
            selection-background-color: %4;
        }
        QLineEdit:focus, QComboBox:focus, QDoubleSpinBox:focus, QTextEdit:focus { border-color: %4; }
        QComboBox { padding-right: 28px; min-height: 22px; }
        QComboBox QAbstractItemView { background: %2; color: %1; selection-background-color: %6; selection-color: %1; padding: 4px; }
        QCheckBox { spacing: 10px; min-height: 28px; }
        QScrollArea { border: none; background: transparent; }
        QScrollBar:vertical { background: transparent; width: 10px; margin: 2px; }
        QScrollBar::handle:vertical { background: %3; border-radius: 3px; min-height: 32px; }
        QScrollBar::handle:vertical:hover { background: %7; }
        QScrollBar:horizontal { background: transparent; height: 10px; margin: 2px; }
        QScrollBar::handle:horizontal { background: %3; border-radius: 3px; min-width: 32px; }
        QScrollBar::add-line, QScrollBar::sub-line { width: 0px; height: 0px; }
        QScrollBar::add-page, QScrollBar::sub-page { background: transparent; }
        QProgressBar { background: %6; border: none; border-radius: 3px; max-height: 6px; }
        QProgressBar::chunk { background: %4; border-radius: 3px; }
        QMenu { background: %2; color: %1; border: 1px solid %3; border-radius: 8px; padding: 6px; }
        QMenu::item { padding: 8px 24px; border-radius: 5px; }
        QMenu::item:selected { background: %6; }
        QMenu::separator { height: 1px; background: %3; margin: 4px 8px; }
        QFrame#ctStatusPanel, QFrame#ctErrorPanel { background: %2; border: 1px solid %3; border-radius: 12px; }
        QFrame#ctCardButton { background: transparent; border: 1px solid transparent; border-radius: 12px; }
        QFrame#ctCardButton:hover, QFrame#ctCardButton:focus, QFrame#ctCardButton[highlighted="true"] {
            background: %2; border-color: %3;
        }
    )").arg(CTColors::textPrimary().name(), CTColors::panel().name(), CTColors::border().name(),
        CTColors::accent().name(), CTColors::accent().darker(110).name(), CTColors::overlay().name(),
        CTColors::textSecondary().name(), CTColors::isDark() ? QStringLiteral("#171b24") : QStringLiteral("#ffffff"));
}
}

void CTTheme::apply(CTThemeMode mode)
{
    static const int fontId = QFontDatabase::addApplicationFont(QStringLiteral(":/Assets/lucide.ttf"));
    Q_UNUSED(fontId);
    static const bool connected = [] {
        QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, qApp, [] {
            if (themeMode == CTThemeMode::System) CTTheme::apply(CTThemeMode::System);
        });
        QFont font = QApplication::font();
#ifdef Q_OS_WIN
        // Windows 11 的界面字体：Segoe UI Variable（拉丁）+ 微软雅黑 UI（中文），
        // Qt 按字体族列表逐字符回退；Win10 没有 Variable 时退回 Segoe UI。
        font.setFamilies({QStringLiteral("Segoe UI Variable Text"), QStringLiteral("Segoe UI"),
            QStringLiteral("Microsoft YaHei UI")});
#endif
        font.setPixelSize(13);
        QApplication::setFont(font);
        return true;
    }();
    Q_UNUSED(connected);
    const QList<QColor> before = {CTColors::background(), CTColors::panel(), CTColors::overlay(),
        CTColors::textPrimary(), CTColors::textSecondary(), CTColors::accent(), CTColors::border(), CTColors::accentSoft()};
    themeMode = mode;
    themeDark = mode == CTThemeMode::Dark || (mode == CTThemeMode::System
        && QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark);
    const QList<QColor> after = {CTColors::background(), CTColors::panel(), CTColors::overlay(),
        CTColors::textPrimary(), CTColors::textSecondary(), CTColors::accent(), CTColors::border(), CTColors::accentSoft()};
    QPalette palette;
    palette.setColor(QPalette::Window, CTColors::background());
    palette.setColor(QPalette::Base, CTColors::panel());
    palette.setColor(QPalette::AlternateBase, CTColors::overlay());
    palette.setColor(QPalette::WindowText, CTColors::textPrimary());
    palette.setColor(QPalette::Text, CTColors::textPrimary());
    palette.setColor(QPalette::Button, CTColors::panel());
    palette.setColor(QPalette::ButtonText, CTColors::textPrimary());
    palette.setColor(QPalette::Highlight, CTColors::accent());
    palette.setColor(QPalette::HighlightedText, CTColors::isDark() ? CTColors::DarkBackground : Qt::white);
    palette.setColor(QPalette::PlaceholderText, CTColors::textSecondary());
    palette.setColor(QPalette::Disabled, QPalette::Text, CTColors::textSecondary());
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, CTColors::textSecondary());
    QApplication::setPalette(palette);
    if (before != after) {
        for (QWidget* widget : QApplication::allWidgets()) {
            bool immersive = false;
            for (QWidget* ancestor = widget; ancestor; ancestor = ancestor->parentWidget()) {
                if (ancestor->property("ctImmersive").toBool()) { immersive = true; break; }
            }
            if (immersive) continue;
            QString style = widget->styleSheet();
            for (int i = 0; i < before.size(); ++i)
                style.replace(before[i].name(), QStringLiteral("@ct%1@").arg(i), Qt::CaseInsensitive);
            for (int i = 0; i < after.size(); ++i)
                style.replace(QStringLiteral("@ct%1@").arg(i), after[i].name());
            if (style != widget->styleSheet()) widget->setStyleSheet(style);
            widget->update();
        }
    }
    qApp->setStyleSheet(applicationStyle());
    for (QWidget* widget : QApplication::allWidgets()) {
        if (auto* list = qobject_cast<QListWidget*>(widget)) {
            for (int i = 0; i < list->count(); ++i) {
                auto* item = list->item(i);
                const QString glyph = item->data(Qt::UserRole + 1).toString();
                if (!glyph.isEmpty()) item->setIcon(icon(glyph));
            }
        }
        if (auto* button = qobject_cast<QPushButton*>(widget)) {
            const QString glyph = button->property("ctIconGlyph").toString();
            if (!glyph.isEmpty()) button->setIcon(icon(glyph));
        }
    }
}

QIcon CTTheme::icon(const QString& glyph, const QColor& color)
{
    QIcon result;
    QFont font(QStringLiteral("lucide"));
    font.setPixelSize(20);
    for (auto mode : {QIcon::Normal, QIcon::Selected, QIcon::Disabled}) {
        for (int scale : {1, 2, 3}) {
            QPixmap image(24 * scale, 24 * scale);
            image.setDevicePixelRatio(scale);
            image.fill(Qt::transparent);
            QPainter painter(&image);
            painter.setFont(font);
            painter.setPen(mode == QIcon::Selected ? CTColors::accent()
                : mode == QIcon::Disabled ? CTColors::textSecondary()
                : color.isValid() ? color : CTColors::textSecondary());
            painter.drawText(QRect(0, 0, 24, 24), Qt::AlignCenter, glyph);
            painter.end();
            result.addPixmap(image, mode);
        }
    }
    return result;
}

const QColor CTColors::ImmersiveBase = QColor(0x12, 0x12, 0x17);

const QColor CTColors::DarkBackground = QColor(QStringLiteral("#10141C"));
const QColor CTColors::DarkPanel = QColor(QStringLiteral("#191F2A"));
const QColor CTColors::DarkOverlay = QColor(QStringLiteral("#262F3E"));
const QColor CTColors::DarkTextPrimary = QColor(QStringLiteral("#F0F3F8"));
const QColor CTColors::DarkTextSecondary = QColor(QStringLiteral("#A8B3C5"));
const QColor CTColors::DarkAccent = QColor(QStringLiteral("#F58B7B"));

const QColor CTColors::LightBackground = QColor(QStringLiteral("#F6F7F9"));
const QColor CTColors::LightPanel = QColor(QStringLiteral("#FFFFFF"));
const QColor CTColors::LightOverlay = QColor(QStringLiteral("#EDF0F5"));
const QColor CTColors::LightTextPrimary = QColor(QStringLiteral("#1C2433"));
const QColor CTColors::LightTextSecondary = QColor(QStringLiteral("#657186"));
const QColor CTColors::LightAccent = QColor(QStringLiteral("#B83F36"));

bool CTColors::isDark()
{
    if (themeDark) return *themeDark;
    if (QStyleHints* hints = QGuiApplication::styleHints()) {
        return hints->colorScheme() == Qt::ColorScheme::Dark;
    }
    return false;
}

QColor CTColors::background() { return isDark() ? DarkBackground : LightBackground; }
QColor CTColors::panel() { return isDark() ? DarkPanel : LightPanel; }
QColor CTColors::overlay() { return isDark() ? DarkOverlay : LightOverlay; }
QColor CTColors::textPrimary() { return isDark() ? DarkTextPrimary : LightTextPrimary; }
QColor CTColors::textSecondary() { return isDark() ? DarkTextSecondary : LightTextSecondary; }
QColor CTColors::accent() { return isDark() ? DarkAccent : LightAccent; }

QColor CTColors::border() { return isDark() ? QColor("#343E4F") : QColor("#DCE1E9"); }
QColor CTColors::accentSoft() { return isDark() ? QColor("#3B2B30") : QColor("#FBECE8"); }

QString CTFormatting::time(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0) seconds = 0;
    const int total = static_cast<int>(std::floor(seconds));
    int minutes = total / 60;
    const int secs = total % 60;
    if (minutes >= 60) {
        const int hours = minutes / 60;
        minutes %= 60;
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QLatin1Char('0'))
            .arg(secs, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2").arg(minutes).arg(secs, 2, 10, QLatin1Char('0'));
}

namespace {

QString oneDecimal(double value)
{
    QString text = QString::number(value, 'f', 1);
    if (text.endsWith(QLatin1String(".0"))) text.chop(2);
    return text;
}

} // namespace

QString CTFormatting::count(int value)
{
    if (value >= 100000000) return oneDecimal(value / 100000000.0) + QStringLiteral("亿");
    if (value >= 10000) return oneDecimal(value / 10000.0) + QStringLiteral("万");
    return QString::number(value);
}

} // namespace ct
