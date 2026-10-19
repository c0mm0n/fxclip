#pragma once
#ifdef FXCLIP_UPDATE_TESTING
#include "app_updater.h"
#include <QApplication>
#include <QAbstractButton>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMessageBox>
#include <QPushButton>
#include <QSaveFile>
#include <QWidget>
#include <QDebug>
#include <memory>

// Drives real widgets and network code only in isolated, unpublished updater fixtures.
inline void startUpdateTest(QWidget *window) {
    const auto mode = qEnvironmentVariable("FXCLIP_UPDATE_TEST_MODE");
    const auto output = qEnvironmentVariable("FXCLIP_UPDATE_TEST_OUTPUT");
    auto *updater = window->findChild<AppUpdater *>();
    qInfo().noquote() << "Updater fixture:" << mode << output;
    auto phase = std::make_shared<int>(0);
    auto complete = std::make_shared<bool>(false);
    auto finish = [=](bool passed) {
        if (*complete) return; *complete = true;
        qInfo().noquote() << "Updater fixture result:" << mode << passed;
        window->grab().save(output + ".png");
        QSaveFile file(output);
        if (file.open(QIODevice::WriteOnly)) {
            file.write(QJsonDocument(QJsonObject{{"passed", passed}, {"mode", mode}, {"version", QCoreApplication::applicationVersion()}, {"status", updater ? updater->status() : "Updater missing"}}).toJson());
            file.commit();
        }
        qApp->exit(passed ? 0 : 1);
    };
    if (!updater || output.isEmpty()) { finish(false); return; }
    auto question = [](QMessageBox::StandardButton answer) {
        QTimer::singleShot(0, qApp, [answer] {
            if (auto *box = qobject_cast<QMessageBox *>(QApplication::activeModalWidget()))
                if (auto *button = box->button(answer)) button->click();
        });
    };
    auto click = [window](const char *name) {
        if (auto *button = window->findChild<QPushButton *>(name)) { button->click(); return true; }
        return false;
    };
    QTimer::singleShot(60000, window, [=] { finish(false); });
    if (mode == "offline" || mode == "daily") {
        QTimer::singleShot(1500, window, [=] {
            const bool valid = !updater->busy() && (updater->automatic() == (mode == "daily"));
            if (mode == "daily") updater->setAutomatic(false);
            finish(valid);
        });
        return;
    }
    QObject::connect(updater, &AppUpdater::quitForUpdate, window, [=] { finish(mode == "install"); });
    QObject::connect(updater, &AppUpdater::changed, window, [=] {
        if (*complete) return;
        if (*phase == 1 && !updater->busy()) {
            if (mode == "network") { finish(!updater->available() && updater->status().contains("connection")); return; }
            if (mode == "older" || mode == "equal" || mode == "draft" || mode == "prerelease") { finish(!updater->available()); return; }
            if (!updater->available()) { finish(false); return; }
            if (mode == "automatic") { finish(updater->automatic() && !updater->ready()); return; }
            *phase = 2;
            question(mode == "decline-download" ? QMessageBox::No : QMessageBox::Yes);
            if (!click("downloadUpdate")) { finish(false); return; }
            if (mode == "decline-download") finish(!updater->downloading() && !updater->ready());
            return;
        }
        if (*phase == 2) {
            if (mode == "cancel" && updater->downloading() && updater->progress() > 0) { *phase = 3; click("cancelUpdate"); return; }
            if (updater->busy()) return;
            if (mode == "corrupt") { finish(!updater->ready() && updater->status().contains("verify")); return; }
            if (!updater->ready()) { finish(false); return; }
            *phase = 3;
            question(mode == "decline-install" ? QMessageBox::No : QMessageBox::Yes);
            if (!click("installUpdate")) { finish(false); return; }
            if (mode == "decline-install") finish(updater->ready() && !updater->busy());
            return;
        }
        if (*phase == 3 && mode == "cancel" && !updater->busy()) finish(!updater->ready() && updater->status().contains("cancelled"));
    });
    QTimer::singleShot(0, window, [=] {
        if (mode == "automatic") { updater->setAutomatic(true); *phase = 1; }
        else { *phase = 1; if (!click("checkForUpdates")) finish(false); }
    });
}
#endif
