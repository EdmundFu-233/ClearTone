#include "App/TrayIconManager.h"
#include "Core/Logging/CTLog.h"
#include "Core/Networking/HelperProcessManager.h"
#include "MainWindow.h"
#include "Playback/PlayerController.h"

#include <QApplication>
#include <QStyleFactory>
#include <QTimer>

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("ClearTone"));
    QApplication::setOrganizationName(QStringLiteral("ClearTone"));
    QApplication::setStyle(QStyleFactory::create(QStringLiteral("Fusion")));

    // CI / 打包后的启动冒烟：正常建窗跑一段时间再退出；崩溃会以非 0 退出码暴露。
    int smokeSeconds = 0;
    const QStringList arguments = QCoreApplication::arguments();
    const int smokeIndex = arguments.indexOf(QStringLiteral("--smoke-test"));
    if (smokeIndex >= 0) {
        smokeSeconds = 20;
        if (smokeIndex + 1 < arguments.size()) {
            bool ok = false;
            const int parsed = arguments.at(smokeIndex + 1).toInt(&ok);
            if (ok && parsed > 0) smokeSeconds = parsed;
        }
    }

    ct::MainWindow window;
    ct::TrayIconManager::shared().initialize(&window);
    window.show();

    QObject::connect(&app, &QCoreApplication::aboutToQuit, [] {
        try {
            ct::PlayerController::shared().persistNow();
        } catch (...) {
        }
        try {
            ct::HelperProcessManager::shared().stop();
        } catch (...) {
        }
    });

    if (smokeSeconds > 0) {
        ct::CTLog::general().info(QStringLiteral("冒烟测试模式：%1 秒后自动退出").arg(smokeSeconds));
        QTimer::singleShot(smokeSeconds * 1000, &app, &QCoreApplication::quit);
    }

    return app.exec();
}
