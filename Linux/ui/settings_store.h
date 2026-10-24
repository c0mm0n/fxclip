#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>

class SettingsStore {
public:
    bool load(const QString &rulesPath, const QString &settingsPath);
    bool reload() { return load(rulesPath_, settingsPath_); }

    bool valid() const { return valid_; }
    bool editable() const { return editable_; }
    QString error() const { return error_; }
    QString settingsPath() const { return settingsPath_; }
    QJsonObject rules() const { return rules_; }
    QJsonObject settings() const { return settings_; }

    QJsonArray previews() const;
    QJsonArray trackerSites() const;
    QJsonArray apps() const;
    bool trackersEverywhere() const;
    bool previewDefaultsEnabled() const;
    bool siteEnabled(const QString &id) const;
    bool previewEnabled(const QString &id) const;
    QStringList previewApps(const QString &id) const;
    QJsonArray neverClean() const;

    bool setTrackersEverywhere(bool enabled);
    bool setSiteEnabled(const QString &id, bool enabled);
    bool setPreview(const QString &id, bool enabled, const QStringList &apps);
    bool setPreviewTargetHost(const QString &id, const QString &host);
    static QString canonicalPreviewHost(const QString &host);
    bool addNeverClean(const QString &host, bool subdomains);
    bool removeNeverClean(int index);
    bool addLinuxApp(const QString &name, const QString &identifier);

private:
    bool save(QJsonObject candidate);
    QJsonObject rules_;
    QJsonObject settings_;
    QString settingsPath_;
    QString rulesPath_;
    QString error_;
    QByteArray loadedDigest_;
    bool valid_ = false;
    bool editable_ = false;
    bool fileWasPresent_ = false;
};
