#pragma once

#include <QColor>
#include <QString>

namespace ct {

class CTColors {
public:
    static const QColor ImmersiveBase;

    static const QColor DarkBackground;
    static const QColor DarkPanel;
    static const QColor DarkOverlay;
    static const QColor DarkTextPrimary;
    static const QColor DarkTextSecondary;
    static const QColor DarkAccent;

    static const QColor LightBackground;
    static const QColor LightPanel;
    static const QColor LightOverlay;
    static const QColor LightTextPrimary;
    static const QColor LightTextSecondary;
    static const QColor LightAccent;

    static bool isDark();

    static QColor background();
    static QColor panel();
    static QColor overlay();
    static QColor textPrimary();
    static QColor textSecondary();
    static QColor accent();
};

class CTSpacing {
public:
    static constexpr double Xs = 4;
    static constexpr double Sm = 8;
    static constexpr double Md = 12;
    static constexpr double Lg = 16;
    static constexpr double Xl = 24;
    static constexpr double Xxl = 32;
};

class CTRadius {
public:
    static constexpr double Small = 6;
    static constexpr double Medium = 10;
    static constexpr double Large = 14;
};

class CTTypography {
public:
    static constexpr double PageTitle = 30;
    static constexpr double SectionTitle = 20;
    static constexpr double Body = 14;
    static constexpr double Caption = 12;
};

class CTFormatting {
public:
    static QString time(double seconds);
    static QString count(int value);
};

} // namespace ct
