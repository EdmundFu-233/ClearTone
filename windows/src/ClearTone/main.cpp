#include "App/TrayIconManager.h"
#include "Core/Networking/HelperProcessManager.h"
#include "MainWindow.h"
#include "Playback/PlayerController.h"

#include <QApplication>
#include <QStyleFactory>

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("ClearTone"));
    QApplication::setOrganizationName(QStringLiteral("ClearTone"));
    QApplication::setStyle(QStyleFactory::create(QStringLiteral("Fusion")));

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

    return app.exec();
}
