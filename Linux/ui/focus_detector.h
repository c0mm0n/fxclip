#pragma once

#include <QObject>
#include <QString>
#include <QTimer>

class QProcess;

class FocusDetector final : public QObject {
    Q_OBJECT
public:
    explicit FocusDetector(QObject *parent = nullptr);
    ~FocusDetector() override;

    bool active() const { return active_; }
    bool start(const QString &fxclipPath, int countdownMilliseconds = 5000, int tickMilliseconds = 1000);
    void cancel();

signals:
    void countdownTick(int secondsRemaining);
    void checking();
    void detected(const QString &appId);
    void failed(const QString &message);
    void canceled();

private:
    void runCheck();
    void finishProcess(QProcess *process, int exitCode, bool normalExit);

    QTimer countdownTimer_;
    QTimer processTimeout_;
    QProcess *process_ = nullptr;
    QString fxclipPath_;
    int remainingMilliseconds_ = 0;
    int tickMilliseconds_ = 1000;
    bool active_ = false;
};
