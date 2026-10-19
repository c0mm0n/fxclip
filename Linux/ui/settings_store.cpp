#include "settings_store.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QSaveFile>
#include <QSet>

static bool isStringArray(const QJsonValue &value) {
    if (!value.isArray()) return false;
    for (const auto &entry : value.toArray()) if (!entry.isString()) return false;
    return true;
}

static bool validSettingsShape(const QJsonObject &settings) {
    if (settings.contains("version") && !settings.value("version").isDouble()) return false;
    if (settings.contains("trackersEverywhere") && !settings.value("trackersEverywhere").isBool()) return false;
    if (settings.contains("disabledSites") && !isStringArray(settings.value("disabledSites"))) return false;
    if (settings.contains("neverClean")) {
        if (!settings.value("neverClean").isArray()) return false;
        for (const auto &entry : settings.value("neverClean").toArray()) {
            const auto object = entry.toObject();
            if (!entry.isObject() || !object.value("host").isString() || !object.value("subdomains").isBool()) return false;
        }
    }
    if (settings.contains("previews")) {
        if (!settings.value("previews").isObject()) return false;
        const auto previews = settings.value("previews").toObject();
        for (auto it = previews.begin(); it != previews.end(); ++it) {
            if (!it.value().isObject()) return false;
            const auto setting = it.value().toObject();
            if (!setting.value("enabled").isBool() || !isStringArray(setting.value("apps"))) return false;
        }
    }
    if (settings.contains("addedApps")) {
        if (!settings.value("addedApps").isArray()) return false;
        for (const auto &entry : settings.value("addedApps").toArray()) {
            if (!entry.isObject()) return false;
            const auto app = entry.toObject();
            if (!app.value("id").isString() || !app.value("name").isString() ||
                !isStringArray(app.value("bundleIDs")) ||
                (app.contains("linux") && !isStringArray(app.value("linux"))) ||
                (app.contains("windows") && !isStringArray(app.value("windows")))) return false;
        }
    }
    return true;
}

bool SettingsStore::load(const QString &rulesPath, const QString &settingsPath) {
    valid_ = editable_ = false;
    error_.clear();
    rulesPath_ = rulesPath;
    settingsPath_ = settingsPath;

    QFile rulesFile(rulesPath);
    if (!rulesFile.open(QIODevice::ReadOnly)) {
        error_ = QStringLiteral("Cannot read rules file %1: %2").arg(rulesPath, rulesFile.errorString());
        return false;
    }
    QJsonParseError parseError;
    const auto rulesDocument = QJsonDocument::fromJson(rulesFile.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !rulesDocument.isObject()) {
        error_ = QStringLiteral("Rules file is invalid: %1").arg(parseError.errorString());
        return false;
    }
    rules_ = rulesDocument.object();

    const QFileInfo settingsInfo(settingsPath_);
    fileWasPresent_ = settingsInfo.exists();
    if (settingsInfo.exists()) {
        QFile settingsFile(settingsPath_);
        if (!settingsFile.open(QIODevice::ReadOnly)) {
            error_ = QStringLiteral("Cannot read settings %1: %2. The file was left untouched.")
                         .arg(settingsPath_, settingsFile.errorString());
            valid_ = true;
            return true;
        }
        const auto raw = settingsFile.readAll();
        loadedDigest_ = QCryptographicHash::hash(raw, QCryptographicHash::Sha256);
        const auto document = QJsonDocument::fromJson(raw, &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            error_ = QStringLiteral("Settings JSON is invalid: %1. The file was left untouched.")
                         .arg(parseError.errorString());
            valid_ = true;
            return true;
        }
        settings_ = document.object();
        if (!validSettingsShape(settings_)) {
            error_ = QStringLiteral("Settings contain an invalid value for a known option. The file was left untouched.");
            valid_ = true;
            return true;
        }
    } else {
        settings_ = QJsonObject();
        loadedDigest_.clear();
    }

    valid_ = editable_ = true;
    return true;
}

QJsonArray SettingsStore::previews() const { return rules_.value("previews").toArray(); }
QJsonArray SettingsStore::trackerSites() const {
    return rules_.value("trackers").toObject().value("sites").toArray();
}

QJsonArray SettingsStore::apps() const {
    QJsonArray result = rules_.value("apps").toArray();
    QSet<QString> ids;
    for (const auto &value : result) ids.insert(value.toObject().value("id").toString());
    for (const auto &value : settings_.value("addedApps").toArray()) {
        const auto app = value.toObject();
        const auto id = app.value("id").toString();
        if (!id.isEmpty() && !ids.contains(id)) {
            result.append(app);
            ids.insert(id);
        }
    }
    return result;
}

bool SettingsStore::trackersEverywhere() const {
    return settings_.value("trackersEverywhere").toBool(true);
}

bool SettingsStore::siteEnabled(const QString &id) const {
    const auto disabled = settings_.value("disabledSites").toArray();
    for (const auto &value : disabled) if (value.toString() == id) return false;
    return true;
}

bool SettingsStore::previewEnabled(const QString &id) const {
    const auto entry = settings_.value("previews").toObject().value(id);
    return entry.isObject() ? entry.toObject().value("enabled").toBool(true) : true;
}

QStringList SettingsStore::previewApps(const QString &id) const {
    const auto builtins = previews();
    for (const auto &value : builtins) {
        const auto preview = value.toObject();
        if (preview.value("id").toString() != id) continue;
        const auto override = settings_.value("previews").toObject().value(id);
        QStringList result;
        const auto source = override.isObject() && override.toObject().contains("apps")
                                ? override.toObject().value("apps").toArray()
                                : preview.value("apps").toArray();
        for (const auto &app : source) result.append(app.toString());
        return result;
    }
    return {};
}

QJsonArray SettingsStore::neverClean() const { return settings_.value("neverClean").toArray(); }

bool SettingsStore::save(QJsonObject candidate) {
    if (!editable_) return false;
    const QFileInfo currentInfo(settingsPath_);
    if (fileWasPresent_) {
        QFile current(settingsPath_);
        if (!currentInfo.exists() || !current.open(QIODevice::ReadOnly) ||
            QCryptographicHash::hash(current.readAll(), QCryptographicHash::Sha256) != loadedDigest_) {
            error_ = QStringLiteral("Settings changed on disk while fxclip was open. Reload the file before making more changes; it was not overwritten.");
            editable_ = false;
            return false;
        }
    } else if (currentInfo.exists()) {
        error_ = QStringLiteral("A settings file appeared while fxclip was open. Reload the file before making more changes; it was not overwritten.");
        editable_ = false;
        return false;
    }
    const auto parent = QFileInfo(settingsPath_).absolutePath();
    if (!QDir().mkpath(parent)) {
        error_ = QStringLiteral("Cannot create settings directory %1.").arg(parent);
        return false;
    }
    QSaveFile file(settingsPath_);
    file.setDirectWriteFallback(false);
    if (!file.open(QIODevice::WriteOnly)) {
        error_ = QStringLiteral("Cannot safely write settings %1: %2. Existing settings were preserved.")
                     .arg(settingsPath_, file.errorString());
        return false;
    }
    const auto bytes = QJsonDocument(candidate).toJson(QJsonDocument::Indented);
    if (file.write(bytes) != bytes.size() || !file.commit()) {
        error_ = QStringLiteral("Cannot commit settings %1: %2. Existing settings were preserved.")
                     .arg(settingsPath_, file.errorString());
        return false;
    }
    settings_ = candidate;
    loadedDigest_ = QCryptographicHash::hash(bytes, QCryptographicHash::Sha256);
    fileWasPresent_ = true;
    error_.clear();
    return true;
}

bool SettingsStore::setTrackersEverywhere(bool enabled) {
    auto candidate = settings_;
    candidate.insert("trackersEverywhere", enabled);
    return save(candidate);
}

bool SettingsStore::setSiteEnabled(const QString &id, bool enabled) {
    auto candidate = settings_;
    QJsonArray disabled;
    for (const auto &entry : candidate.value("disabledSites").toArray()) {
        if (entry.toString() != id) disabled.append(entry);
    }
    if (!enabled) disabled.append(id);
    candidate.insert("disabledSites", disabled);
    return save(candidate);
}

bool SettingsStore::setPreview(const QString &id, bool enabled, const QStringList &appIds) {
    auto candidate = settings_;
    auto previewsObject = candidate.value("previews").toObject();
    auto setting = previewsObject.value(id).toObject();
    QJsonArray appsArray;
    for (const auto &app : appIds) appsArray.append(app);
    setting.insert("enabled", enabled);
    setting.insert("apps", appsArray);
    previewsObject.insert(id, setting);
    candidate.insert("previews", previewsObject);
    return save(candidate);
}

bool SettingsStore::addNeverClean(const QString &host, bool subdomains) {
    auto candidate = settings_;
    auto entries = candidate.value("neverClean").toArray();
    for (const auto &entry : entries) {
        if (entry.toObject().value("host").toString() == host) return true;
    }
    entries.append(QJsonObject{{"host", host}, {"subdomains", subdomains}});
    candidate.insert("neverClean", entries);
    return save(candidate);
}

bool SettingsStore::removeNeverClean(int index) {
    auto candidate = settings_;
    auto entries = candidate.value("neverClean").toArray();
    if (index < 0 || index >= entries.size()) return false;
    entries.removeAt(index);
    candidate.insert("neverClean", entries);
    return save(candidate);
}

bool SettingsStore::addLinuxApp(const QString &name, const QString &identifier) {
    auto candidate = settings_;
    auto entries = candidate.value("addedApps").toArray();
    for (const auto &entry : apps()) {
        for (const auto &id : entry.toObject().value("linux").toArray()) {
            if (id.toString().compare(identifier, Qt::CaseInsensitive) == 0) {
                error_ = QStringLiteral("That Linux app identifier is already listed.");
                return false;
            }
        }
    }
    const auto digest = QCryptographicHash::hash(identifier.toUtf8(), QCryptographicHash::Sha256).toHex().left(12);
    entries.append(QJsonObject{{"id", QStringLiteral("linux-%1").arg(QString::fromLatin1(digest))},
                               {"name", name}, {"bundleIDs", QJsonArray()},
                               {"linux", QJsonArray{identifier}}});
    candidate.insert("addedApps", entries);
    return save(candidate);
}
