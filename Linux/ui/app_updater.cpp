#include "app_updater.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QSet>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QVersionNumber>
#include <functional>
#include <memory>

AppUpdater::AppUpdater(const QString &settingsPath, QObject *parent)
    : QObject(parent), preferences_(QFileInfo(settingsPath).dir().filePath("updates.ini"), QSettings::IniFormat),
      endpoint_(QStringLiteral("https://api.github.com/repos/c0mm0n/fxclip/releases/latest")),
      resultPath_(QFileInfo(settingsPath).dir().filePath("update-result.txt")) {
#ifdef FXCLIP_UPDATE_TESTING
    if (!qEnvironmentVariable("FXCLIP_UPDATE_TEST_API").isEmpty()) endpoint_ = QUrl(qEnvironmentVariable("FXCLIP_UPDATE_TEST_API"));
#endif
    QFile result(resultPath_);
    if (result.open(QIODevice::ReadOnly)) {
        status_ = QString::fromUtf8(result.read(4096)).trimmed(); result.close(); result.remove();
    }
    timer_.setInterval(60 * 60 * 1000);
    connect(&timer_, &QTimer::timeout, this, &AppUpdater::automaticCheck);
}
AppUpdater::~AppUpdater() {
    timer_.stop();
    for (auto *reply : network_.findChildren<QNetworkReply *>()) {
        disconnect(reply, nullptr, this, nullptr); reply->abort();
    }
    for (auto *process : findChildren<QProcess *>(QString(), Qt::FindDirectChildrenOnly)) {
        disconnect(process, nullptr, this, nullptr);
        process->kill(); process->waitForFinished(1000); delete process;
    }
}
QString AppUpdater::installedDirectory() { return QDir::homePath() + QStringLiteral("/.local/bin"); }
bool AppUpdater::automatic() const { return preferences_.value("automaticChecks", false).toBool(); }
void AppUpdater::start() { timer_.start(); automaticCheck(); }
void AppUpdater::setAutomatic(bool enabled) {
    preferences_.setValue("automaticChecks", enabled); preferences_.sync();
    emit changed();
    if (enabled) automaticCheck();
}
void AppUpdater::automaticCheck() {
    if (automatic() && QDateTime::currentSecsSinceEpoch() - preferences_.value("lastCheck", 0).toLongLong() >= 86400) check();
}
QNetworkRequest AppUpdater::request(const QUrl &url) const {
    QNetworkRequest r(url);
    r.setHeader(QNetworkRequest::UserAgentHeader, "fxclip/" + QCoreApplication::applicationVersion());
    r.setRawHeader("Accept", "application/vnd.github+json");
    r.setTransferTimeout(15000);
    r.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    r.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    r.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    return r;
}
void AppUpdater::finish(const QString &message) {
    busy_ = downloading_ = false; status_ = message; emit changed();
}
void AppUpdater::check() {
    if (busy_) return;
    ready_ = false; staging_.reset(); version_.clear(); notes_.clear();
    busy_ = true; status_ = QStringLiteral("Checking GitHub…"); emit changed();
    preferences_.setValue("lastCheck", QDateTime::currentSecsSinceEpoch()); preferences_.sync();
    auto *reply = network_.get(request(endpoint_)); reply_ = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        const auto bytes = reply->readAll(); const bool ok = reply->error() == QNetworkReply::NoError;
        reply_ = nullptr; reply->deleteLater();
        if (!ok) { finish(QStringLiteral("Couldn’t check for updates. Check your connection and try again.")); return; }
        QJsonParseError error;
        const auto doc = QJsonDocument::fromJson(bytes, &error);
        if (error.error != QJsonParseError::NoError || !doc.isObject()) { finish(QStringLiteral("GitHub returned invalid update information. Try again later.")); return; }
        const auto release = doc.object();
        static const QRegularExpression tagPattern(QStringLiteral("^v([0-9]+\\.[0-9]+\\.[0-9]+)$"));
        const auto match = tagPattern.match(release.value("tag_name").toString());
        if (release.value("draft").toBool() || release.value("prerelease").toBool() || !match.hasMatch()) {
            finish(QStringLiteral("No newer stable version is available.")); return;
        }
        const auto version = match.captured(1);
        const auto current = QVersionNumber::fromString(QCoreApplication::applicationVersion());
        if (current.isNull()) { finish(QStringLiteral("This development build cannot install stable updates.")); return; }
        if (QVersionNumber::compare(QVersionNumber::fromString(version), current) <= 0) { finish(QStringLiteral("You’re up to date.")); return; }
        const auto expected = QStringLiteral("https://github.com/c0mm0n/fxclip/releases/download/v%1/fxclip-linux-x86_64.tar.gz").arg(version);
        for (const auto &value : release.value("assets").toArray()) {
            const auto asset = value.toObject();
            if (asset.value("name").toString() != "fxclip-linux-x86_64.tar.gz") continue;
            const auto url = asset.value("browser_download_url").toString();
            bool validUrl = url == expected;
#ifdef FXCLIP_UPDATE_TESTING
            const QUrl fixture(url);
            validUrl = validUrl || (fixture.scheme() == "http" && fixture.host() == "127.0.0.1");
#endif
            const auto digest = asset.value("digest").toString();
            static const QRegularExpression sha(QStringLiteral("^sha256:([0-9a-fA-F]{64})$"));
            const auto hash = sha.match(digest);
            const auto size = asset.value("size").toDouble();
            if (!validUrl || !hash.hasMatch() || size <= 0 || size > 1024.0 * 1024 * 1024) break;
            version_ = version; downloadUrl_ = QUrl(url); digest_ = hash.captured(1).toLower(); size_ = static_cast<qint64>(size);
            notes_ = release.value("body").toString();
            finish(QStringLiteral("Version %1 is available.").arg(version_)); return;
        }
        finish(QStringLiteral("This release has no verified Linux x86_64 download. Try again later."));
    });
}
void AppUpdater::download() {
    if (busy_ || !available()) return;
    staging_ = std::make_unique<QTemporaryDir>(QDir::tempPath() + "/fxclip-update-XXXXXX");
    if (!staging_->isValid()) { finish(QStringLiteral("Couldn’t create a private update folder.")); return; }
    auto file = std::make_shared<QSaveFile>(staging_->filePath("update.tar.gz"));
    file->setDirectWriteFallback(false);
    if (!file->open(QIODevice::WriteOnly)) { staging_.reset(); finish(QStringLiteral("Couldn’t save the download. Check free disk space and try again.")); return; }
    auto hash = std::make_shared<QCryptographicHash>(QCryptographicHash::Sha256);
    auto written = std::make_shared<qint64>(0);
    auto failed = std::make_shared<bool>(false);
    canceled_ = ready_ = false; busy_ = downloading_ = true; progress_ = 0;
    status_ = QStringLiteral("Downloading…"); emit changed();
    auto *reply = network_.get(request(downloadUrl_)); reply_ = reply;
    auto read = [this, reply, file, hash, written, failed] {
        const auto bytes = reply->readAll();
        *written += bytes.size();
        if (*written > size_ || file->write(bytes) != bytes.size()) { *failed = true; reply->abort(); return; }
        hash->addData(bytes);
        progress_ = static_cast<int>(*written * 100 / size_);
        status_ = QStringLiteral("Downloading… %1%").arg(progress_); emit changed();
    };
    connect(reply, &QNetworkReply::readyRead, this, read);
    connect(reply, &QNetworkReply::finished, this, [this, reply, file, hash, written, failed, read] {
        if (reply->bytesAvailable()) read();
        const auto error = reply->error(); reply_ = nullptr; reply->deleteLater(); downloading_ = false;
        if (canceled_ || error != QNetworkReply::NoError || *failed || *written != size_ || hash->result().toHex() != digest_.toUtf8() || !file->commit()) {
            file->cancelWriting(); staging_.reset();
            finish(canceled_ ? QStringLiteral("Download cancelled. Your installed version is unchanged.") : QStringLiteral("Couldn’t download or verify this update. Your installed version is unchanged; try again."));
            return;
        }
        stageArchive();
    });
}
void AppUpdater::cancel() { if (downloading_ && reply_) { canceled_ = true; reply_->abort(); } }
void AppUpdater::run(const QString &program, const QStringList &args, std::function<void(bool, const QByteArray &)> done) {
    auto *process = new QProcess(this);
    auto completed = std::make_shared<bool>(false);
    connect(process, &QProcess::finished, this, [process, done, completed](int code, QProcess::ExitStatus exit) {
        if (*completed) return; *completed = true;
        done(code == 0 && exit == QProcess::NormalExit, process->readAllStandardOutput()); process->deleteLater();
    });
    connect(process, &QProcess::errorOccurred, this, [process, done, completed](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart || *completed) return; *completed = true; done(false, {}); process->deleteLater();
    });
    QTimer::singleShot(30000, process, [process, done, completed] {
        if (*completed) return; *completed = true; process->kill(); done(false, {}); process->deleteLater();
    });
    process->start(program, args);
}
void AppUpdater::stageArchive() {
    status_ = QStringLiteral("Verifying the archive…"); emit changed();
    const auto archive = staging_->filePath("update.tar.gz");
    run("tar", {"-tzf", archive}, [this, archive](bool ok, const QByteArray &output) {
        const QSet<QString> files{"fxclip", "fxclip-ui", "fxclip.rules.json", "fxclip.service", "install.sh", "README.md", "fxclip-icon.png", "fxclip-tray.png", "libexec/wl-copy", "libexec/wl-paste", "libexec/LICENSE.wl-clipboard", "libexec/wl-clipboard-source.tar.gz"};
        QSet<QString> seen;
        for (const auto &line : QString::fromUtf8(output).split('\n', Qt::SkipEmptyParts)) {
            if (line == "fxclip-linux-x86_64/" || line == "fxclip-linux-x86_64/libexec/") continue;
            if (!line.startsWith("fxclip-linux-x86_64/")) { ok = false; break; }
            const auto name = line.mid(QStringLiteral("fxclip-linux-x86_64/").size());
            if (!files.contains(name) || seen.contains(name)) { ok = false; break; }
            seen.insert(name);
        }
        if (!ok || seen != files) { staging_.reset(); finish(QStringLiteral("The update archive is incomplete or unsafe. Your installed version is unchanged.")); return; }
        run("tar", {"-tvzf", archive}, [this, archive](bool typesOk, const QByteArray &listing) {
            for (const auto &line : listing.split('\n')) if (!line.isEmpty() && line[0] != '-' && line[0] != 'd') typesOk = false;
            if (!typesOk) { staging_.reset(); finish(QStringLiteral("The update archive contains unsupported file types. Your installed version is unchanged.")); return; }
            const auto destination = staging_->filePath("payload"); QDir().mkpath(destination);
            run("tar", {"-xzf", archive, "--no-same-owner", "--no-same-permissions", "-C", destination}, [this, destination](bool extracted, const QByteArray &) {
                if (!extracted) { staging_.reset(); finish(QStringLiteral("Couldn’t prepare the update. Your installed version is unchanged.")); return; }
                payload_ = QDir(destination).filePath("fxclip-linux-x86_64");
                ready_ = true; progress_ = 100;
                finish(QStringLiteral("Update verified. Install and restart when you are ready."));
            });
        });
    });
}
void AppUpdater::install() {
    if (busy_ || !ready_ || !staging_) return;
    const auto expectedApp = installedDirectory() + "/fxclip-ui";
    if (QFileInfo(QCoreApplication::applicationFilePath()).canonicalFilePath() != QFileInfo(expectedApp).canonicalFilePath()) {
        finish(QStringLiteral("Run install.sh from the Linux download once to enable updates for this user installation.")); return;
    }
    busy_ = true; status_ = QStringLiteral("Preparing to restart…"); emit changed();
    run(payload_ + "/fxclip-ui", {"--version"}, [this](bool ok, const QByteArray &version) {
        if (!ok || version.trimmed() != ("fxclip-ui " + version_).toUtf8()) { finish(QStringLiteral("The new interface cannot run on this system. Your installed version is unchanged.")); return; }
        run(payload_ + "/fxclip", {"--version"}, [this](bool ok, const QByteArray &version) {
            if (!ok || version.trimmed() != ("fxclip " + version_).toUtf8()) { finish(QStringLiteral("The new service cannot run on this system. Your installed version is unchanged.")); return; }
            QDir().mkpath(QFileInfo(resultPath_).absolutePath());
            qint64 pid = 0;
            if (!QProcess::startDetached("/bin/sh", {payload_ + "/install.sh", "--update", QString::number(QCoreApplication::applicationPid()), version_, staging_->path()}, staging_->path(), &pid)) {
                finish(QStringLiteral("Couldn’t start the installer. Your installed version is unchanged.")); return;
            }
            staging_->setAutoRemove(false);
            emit quitForUpdate();
        });
    });
}
