#include "settings_store.h"
#include "focus_output.h"
#include "focus_detector.h"

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>
#include <QTemporaryDir>
#include <QTimer>

#include <cstdlib>
#include <iostream>

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    require(focusedAppFromCheckOutput(QStringLiteral("Compositor: KDE\nFocused app: org.example.Chat\n")) == "org.example.Chat",
            "focus helper parses the exact focused-app field");
    require(focusedAppFromCheckOutput(QStringLiteral("Focused app: unavailable (previews disabled)\n")).isEmpty(),
            "focus helper rejects unavailable focus");
    require(focusedAppFromCheckOutput(QStringLiteral("log Focused app: org.example.Chat\n")).isEmpty(),
            "focus helper ignores unrelated output lines");
    require(focusedAppFromCheckOutput(QStringLiteral("Focused app: org.example.Chat extra\n")).isEmpty(),
            "focus helper rejects malformed app IDs");
    require(focusedAppFromCheckOutput(QStringLiteral("Focused app: First\nFocused app: Second\n")).isEmpty(),
            "focus helper rejects ambiguous output");

    QTemporaryDir helperTemp;
    require(helperTemp.isValid(), "focus helper temporary directory");
    const auto fakeCheck = helperTemp.filePath("fake-fxclip");
    QFile fakeScript(fakeCheck);
    require(fakeScript.open(QIODevice::WriteOnly), "create fake fxclip check command");
    fakeScript.write("#!/bin/sh\nprintf '%s\\n' 'Focused app: org.example.Chat'\n");
    fakeScript.close();
    require(fakeScript.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner), "make fake fxclip executable");

    FocusDetector detector;
    QEventLoop detectedLoop;
    QString detectedId, detectionError;
    int countdownTicks = 0;
    QObject::connect(&detector, &FocusDetector::countdownTick, &detectedLoop, [&countdownTicks](int) { ++countdownTicks; });
    QObject::connect(&detector, &FocusDetector::detected, &detectedLoop, [&detectedId, &detectedLoop](const QString &id) {
        detectedId = id;
        detectedLoop.quit();
    });
    QObject::connect(&detector, &FocusDetector::failed, &detectedLoop, [&detectionError, &detectedLoop](const QString &error) {
        detectionError = error;
        detectedLoop.quit();
    });
    QTimer::singleShot(3000, &detectedLoop, &QEventLoop::quit);
    require(detector.start(fakeCheck, 120, 20), "start asynchronous app ID detection");
    detectedLoop.exec();
    require(detectionError.isEmpty(), "fake app ID command succeeds");
    require(detectedId == "org.example.Chat", "detector emits parsed app ID from fake fxclip check");
    require(countdownTicks >= 6, "multi-tick countdown continues through the check");
    require(!detector.active(), "detector returns to idle after process completion");

    FocusDetector canceledCountdown;
    bool canceledCountdownSignal = false;
    bool canceledCountdownDetected = false;
    QEventLoop canceledCountdownLoop;
    QObject::connect(&canceledCountdown, &FocusDetector::canceled, &canceledCountdownLoop, [&] {
        canceledCountdownSignal = true;
        canceledCountdownLoop.quit();
    });
    QObject::connect(&canceledCountdown, &FocusDetector::detected, &canceledCountdownLoop, [&] { canceledCountdownDetected = true; });
    require(canceledCountdown.start(fakeCheck, 200, 10), "start cancellable countdown");
    QTimer::singleShot(25, &canceledCountdown, &FocusDetector::cancel);
    QTimer::singleShot(1000, &canceledCountdownLoop, &QEventLoop::quit);
    canceledCountdownLoop.exec();
    require(canceledCountdownSignal && !canceledCountdownDetected && !canceledCountdown.active(),
            "canceling countdown prevents process launch and result callbacks");

    const auto slowCheck = helperTemp.filePath("slow-fxclip");
    QFile slowScript(slowCheck);
    require(slowScript.open(QIODevice::WriteOnly), "create slow fake check command");
    slowScript.write("#!/bin/sh\nexec sleep 1\n");
    slowScript.close();
    require(slowScript.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner), "make slow fake command executable");
    FocusDetector canceledProcess;
    bool canceledProcessSignal = false;
    bool canceledProcessDetected = false;
    QEventLoop canceledProcessLoop;
    QObject::connect(&canceledProcess, &FocusDetector::canceled, &canceledProcessLoop, [&] {
        canceledProcessSignal = true;
        canceledProcessLoop.quit();
    });
    QObject::connect(&canceledProcess, &FocusDetector::detected, &canceledProcessLoop, [&] { canceledProcessDetected = true; });
    QObject::connect(&canceledProcess, &FocusDetector::checking, &canceledProcessLoop, [&] {
        QTimer::singleShot(10, &canceledProcess, &FocusDetector::cancel);
    });
    require(canceledProcess.start(slowCheck, 0), "start immediate fake app ID check");
    QTimer::singleShot(1000, &canceledProcessLoop, &QEventLoop::quit);
    canceledProcessLoop.exec();
    require(canceledProcessSignal && !canceledProcessDetected && !canceledProcess.active(),
            "canceling the running app check prevents late result callbacks");

    QTemporaryDir temp;
    require(temp.isValid(), "temporary test directory");
    const auto settingsPath = temp.filePath("config/fxclip/settings.json");
    SettingsStore store;
    require(store.load(QStringLiteral(FXCLIP_RULES_PATH), settingsPath), "load built-in rules");
    require(store.editable(), "new settings are editable");

    bool telegramFound = false;
    for (const auto &value : store.apps()) {
        const auto app = value.toObject();
        if (app.value("id").toString() != "telegram") continue;
        for (const auto &identifier : app.value("linux").toArray())
            if (identifier.toString() == "org.telegram.desktop") telegramFound = true;
    }
    require(telegramFound, "built-in Telegram Linux identifier maps to the Telegram app choice");
    require(store.addLinuxApp("Test Chat", "org.example.chat"), "add custom Linux app");
    bool customFound = false;
    for (const auto &value : store.apps()) {
        const auto app = value.toObject();
        if (app.value("name").toString() == "Test Chat" &&
            app.value("linux").toArray().first().toString() == "org.example.chat") customFound = true;
    }
    require(customFound, "custom app identifier remains mapped to its preview choice");

    QFile initial(settingsPath);
    require(initial.open(QIODevice::WriteOnly), "write initial settings fixture");
    initial.write(R"({"unrecognized":{"keep":true},"previews":{"x":{"enabled":true,"apps":["telegram"],"vendorField":"retain"}}})");
    initial.close();
    require(store.load(QStringLiteral(FXCLIP_RULES_PATH), settingsPath), "reload settings fixture");
    require(store.setPreview("x", true, {"telegram"}), "save preview choice");
    QFile saved(settingsPath);
    require(saved.open(QIODevice::ReadOnly), "read saved settings");
    const auto document = QJsonDocument::fromJson(saved.readAll());
    const auto root = document.object();
    require(root.value("unrecognized").toObject().value("keep").toBool(), "unknown top-level keys survive atomic save");
    require(root.value("previews").toObject().value("x").toObject().value("vendorField").toString() == "retain",
            "unknown preview fields survive atomic save");

    require(SettingsStore::canonicalPreviewHost(" \tPREVIEW.Example.\r\n") == "preview.example", "provider host is canonicalized");
    const auto maxHost = QString(63, 'a') + "." + QString(63, 'a') + "." + QString(63, 'a') + "." + QString(61, 'b');
    require(SettingsStore::canonicalPreviewHost(maxHost + ".") == maxHost, "253-character provider host is accepted");
    require(SettingsStore::canonicalPreviewHost(maxHost + "b").isEmpty(), "provider host longer than 253 characters is rejected");
    for (const auto &host : QStringList{"localhost", "https://preview.example", "preview.example/path", "preview.example:443",
             "user@preview.example", "preview.example?x", "preview.example#x", "pre view.example", "preview_1.example",
             QString::fromUtf8("préview.example"), "-preview.example", "preview-.example", "preview..example", "preview.example..",
             QString(64, 'a') + ".example", QString("preview.") + QChar(1) + "example"})
        require(SettingsStore::canonicalPreviewHost(host).isEmpty(), "invalid provider host is rejected");
    require(store.setPreviewTargetHost("x", "PREVIEW.Example."), "save provider choice");
    auto providerSetting = store.settings().value("previews").toObject().value("x").toObject();
    require(providerSetting.value("targetHost").toString() == "preview.example", "provider is saved canonically");
    require(providerSetting.value("vendorField").toString() == "retain" && providerSetting.value("enabled").toBool() &&
            providerSetting.value("apps").toArray() == QJsonArray{"telegram"}, "provider edit preserves other preview fields");
    require(!store.setPreviewTargetHost("x", "https://preview.example"), "invalid provider edit is refused");
    require(store.settings().value("previews").toObject().value("x").toObject() == providerSetting, "invalid provider edit leaves settings intact");
    require(store.setPreviewTargetHost("x", ""), "clear provider choice");
    require(!store.settings().value("previews").toObject().value("x").toObject().contains("targetHost"), "clearing removes provider key");
    require(store.setPreviewTargetHost("reddit", "preview.example"), "provider can be the first preview edit");
    providerSetting = store.settings().value("previews").toObject().value("reddit").toObject();
    require(providerSetting.value("enabled").toBool() && providerSetting.value("apps").toArray() == QJsonArray{"telegram"},
            "first provider edit supplies the built-in enabled and apps defaults");

    QFile external(settingsPath);
    require(external.open(QIODevice::ReadOnly), "read current settings before external edit");
    auto externalRoot = QJsonDocument::fromJson(external.readAll()).object();
    external.close();
    externalRoot.insert("writtenElsewhere", true);
    QSaveFile externalSave(settingsPath);
    require(externalSave.open(QIODevice::WriteOnly), "write external config update atomically");
    externalSave.write(QJsonDocument(externalRoot).toJson(QJsonDocument::Indented));
    require(externalSave.commit(), "commit external config update");
    require(!store.setPreview("x", false, {}), "concurrent config edits are refused");
    QFile concurrent(settingsPath);
    require(concurrent.open(QIODevice::ReadOnly), "read concurrent config after refused save");
    require(QJsonDocument::fromJson(concurrent.readAll()).object().value("writtenElsewhere").toBool(),
            "external config keys are not lost to stale UI state");
    require(store.reload(), "reload settings after external change");
    require(store.editable(), "reloaded current settings can be edited");
    require(store.setPreview("x", false, {}), "save after explicit reload");
    QFile reloaded(settingsPath);
    require(reloaded.open(QIODevice::ReadOnly) &&
            QJsonDocument::fromJson(reloaded.readAll()).object().value("writtenElsewhere").toBool(),
            "external keys survive save after reload");

    const auto malformedPath = temp.filePath("bad/settings.json");
    QDir().mkpath(QFileInfo(malformedPath).absolutePath());
    QFile malformed(malformedPath);
    require(malformed.open(QIODevice::WriteOnly), "write malformed config fixture");
    malformed.write("{bad json");
    malformed.close();
    require(store.load(QStringLiteral(FXCLIP_RULES_PATH), malformedPath), "invalid settings do not prevent UI startup");
    require(!store.editable(), "invalid settings disable editing");
    require(!store.setTrackersEverywhere(false), "invalid settings cannot be overwritten");
    QFile unchanged(malformedPath);
    require(unchanged.open(QIODevice::ReadOnly) && unchanged.readAll() == "{bad json",
            "invalid user file remains byte-for-byte unchanged");

    const auto wrongTypePath = temp.filePath("wrong/settings.json");
    QDir().mkpath(QFileInfo(wrongTypePath).absolutePath());
    QFile wrongType(wrongTypePath);
    require(wrongType.open(QIODevice::WriteOnly), "write wrong-type config fixture");
    wrongType.write(R"({"trackersEverywhere":"false","futureKey":17})");
    wrongType.close();
    require(store.load(QStringLiteral(FXCLIP_RULES_PATH), wrongTypePath), "wrong setting type does not block UI startup");
    require(!store.editable(), "wrong setting types disable edits");
    require(!store.setTrackersEverywhere(false), "wrong setting types are not overwritten");
    QFile wrongTypeUnchanged(wrongTypePath);
    require(wrongTypeUnchanged.open(QIODevice::ReadOnly) &&
            wrongTypeUnchanged.readAll() == R"({"trackersEverywhere":"false","futureKey":17})",
            "wrong-type settings remain byte-for-byte unchanged");
    const auto legacyPath = temp.filePath("legacy.json");
    QFile legacy(legacyPath);
    require(legacy.open(QIODevice::WriteOnly), "write legacy preview refusal");
    const auto legacyBytes = QByteArray(R"({"previews":{"x":{"enabled":false,"apps":["telegram"]},"instagram":{"enabled":false,"apps":["telegram"]}}})");
    legacy.write(legacyBytes);
    legacy.close();
    SettingsStore legacyStore;
    require(legacyStore.load(QStringLiteral(FXCLIP_RULES_PATH), legacyPath), "load legacy preview refusal");
    require(!legacyStore.previewDefaultsEnabled() && !legacyStore.previewEnabled("reddit"), "legacy refusal disables new default previews");
    require(legacy.open(QIODevice::ReadOnly) && legacy.readAll() == legacyBytes, "migration does not write settings during load");
    legacy.close();
    require(legacyStore.setPreviewTargetHost("reddit", "preview.example"), "set provider on a legacy default-off rule");
    require(!legacyStore.previewEnabled("reddit"), "first provider edit preserves inferred disabled default");
    require(legacyStore.setPreview("x", true, {"telegram"}) && legacyStore.reload(), "save and reload one enabled preview");
    require(!legacyStore.previewDefaultsEnabled() && legacyStore.previewEnabled("x") && !legacyStore.previewEnabled("reddit"),
            "individual choice and inferred refusal both survive persistence");
    require(legacyStore.setPreview("reddit", true, {"telegram"}) && legacyStore.reload(), "explicitly enable Reddit");
    require(legacyStore.previewEnabled("reddit") && !legacyStore.previewEnabled("instagram") && !legacyStore.previewEnabled("future"),
            "explicit Reddit choice keeps other and future previews disabled");
    require(legacy.open(QIODevice::WriteOnly | QIODevice::Truncate), "write explicit preview defaults fixture");
    legacy.write(R"({"previewDefaultsEnabled":true,"previews":{"x":{"enabled":false,"apps":[]},"instagram":{"enabled":false,"apps":[]}}})");
    legacy.close();
    require(legacyStore.reload() && legacyStore.previewEnabled("reddit") && !legacyStore.previewEnabled("x"), "explicit default wins legacy inference");
    require(legacy.open(QIODevice::WriteOnly | QIODevice::Truncate), "write partial preview refusal fixture");
    legacy.write(R"({"previews":{"x":{"enabled":false,"apps":[]}}})");
    legacy.close();
    require(legacyStore.reload() && legacyStore.previewEnabled("instagram") && legacyStore.previewEnabled("reddit"),
            "partial X refusal keeps other built-in defaults");
    std::cout << "Settings atomicity and Linux app mapping passed.\n";
    return 0;
}
