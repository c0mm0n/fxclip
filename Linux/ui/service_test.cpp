// Exercise real UI controls against a real systemd user manager on a disposable CI user.
#define FXCLIP_UI_TESTING
#include "main.cpp"
#include <QElapsedTimer>
#include <QThread>
#include <iostream>
#include <stdexcept>

static void requireService(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
static void awaitService(const std::function<bool()> &ready) {
    QElapsedTimer timer; timer.start();
    while (!ready()) {
        if (timer.elapsed() > 15000) throw std::runtime_error("UI service operation timed out");
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(25);
    }
}
static QString systemctlResult(const QString &command) {
    QProcess p; p.start("systemctl", {"--user", command, "fxclip.service"});
    if (!p.waitForFinished(2000)) throw std::runtime_error("systemctl timed out");
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed();
}
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationVersion(QStringLiteral(FXCLIP_VERSION));
    try {
        MainWindow window(false); window.show();
        for (auto *button : window.findChildren<QPushButton *>())
            if (button->accessibleName() == "Settings") button->click();
        QPushButton *start = nullptr, *stop = nullptr;
        for (auto *button : window.findChildren<QPushButton *>()) {
            if (button->text() == "Start service") start = button;
            if (button->text() == "Stop service") stop = button;
        }
        requireService(start && stop, "Service controls missing");
        awaitService([&] { return stop->isEnabled(); });
        requireService(systemctlResult("is-active") == "active", "Service not initially running");
        stop->click();
        awaitService([&] { return start->isEnabled() && !stop->isEnabled(); });
        requireService(systemctlResult("is-active") == "inactive", "UI did not stop real service");
        start->click();
        awaitService([&] { return stop->isEnabled() && !start->isEnabled(); });
        requireService(systemctlResult("is-active") == "active", "UI did not restart real service");
        QCheckBox *login = nullptr;
        for (auto *check : window.findChildren<QCheckBox *>())
            if (check->text().contains("desktop login")) login = check;
        requireService(login, "Login preference missing");
        awaitService([&] { return login->isEnabled() && login->isChecked(); });
        login->click();
        awaitService([&] { return login->isEnabled() && !login->isChecked(); });
        requireService(systemctlResult("is-enabled") == "disabled", "UI did not disable login startup");
        login->click();
        awaitService([&] { return login->isEnabled() && login->isChecked(); });
        requireService(systemctlResult("is-enabled") == "enabled", "UI did not enable login startup");
        // processEvents alone does not flush DeferredDelete outside app.exec().
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QCoreApplication::processEvents();
        const auto capture = qEnvironmentVariable("FXCLIP_UI_SERVICE_CAPTURE");
        if (!capture.isEmpty()) requireService(window.grab().save(capture), "Service screenshot failed");
        std::cout << "Real Qt start/stop/restart and login controls passed against systemd.\n";
        return 0;
    } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
