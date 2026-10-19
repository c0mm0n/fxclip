#pragma once
#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QSettings>
#include <QTemporaryDir>
#include <QTimer>
#include <memory>
#include <functional>

class AppUpdater final : public QObject {
    Q_OBJECT
public:
    explicit AppUpdater(const QString &settingsPath, QObject *parent = nullptr);
    ~AppUpdater() override;
    void start();
    void check();
    void download();
    void cancel();
    void install();
    void setAutomatic(bool enabled);
    bool automatic() const;
    bool busy() const { return busy_; }
    bool downloading() const { return downloading_; }
    bool available() const { return !version_.isEmpty(); }
    bool ready() const { return ready_; }
    QString status() const { return status_; }
    QString notes() const { return notes_; }
    int progress() const { return progress_; }
    static QString installedDirectory();
signals:
    void changed();
    void quitForUpdate();
private:
    void automaticCheck();
    void finish(const QString &message);
    void stageArchive();
    void run(const QString &program, const QStringList &args,
             std::function<void(bool, const QByteArray &)> done);
    QNetworkRequest request(const QUrl &url) const;
    QSettings preferences_;
    QNetworkAccessManager network_;
    QPointer<QNetworkReply> reply_;
    QTimer timer_;
    std::unique_ptr<QTemporaryDir> staging_;
    QUrl endpoint_, downloadUrl_;
    QString status_ = QStringLiteral("Check GitHub for a newer version."), notes_, version_, digest_;
    QString resultPath_, payload_;
    qint64 size_ = 0;
    bool busy_ = false, downloading_ = false, canceled_ = false, ready_ = false;
    int progress_ = 0;
};
