#include "focus_detector.h"
#include "focus_output.h"

#include <QProcess>

#include <algorithm>

FocusDetector::FocusDetector(QObject *parent) : QObject(parent) {
    countdownTimer_.setParent(this);
    processTimeout_.setParent(this);
    processTimeout_.setSingleShot(true);
    connect(&countdownTimer_, &QTimer::timeout, this, [this] {
        remainingMilliseconds_ = std::max(0, remainingMilliseconds_ - tickMilliseconds_);
        const int seconds = (remainingMilliseconds_ + 999) / 1000;
        emit countdownTick(seconds);
        if (remainingMilliseconds_ == 0) {
            countdownTimer_.stop();
            runCheck();
        }
    });
    connect(&processTimeout_, &QTimer::timeout, this, [this] {
        if (!process_) return;
        auto *timedOut = process_;
        process_ = nullptr;
        active_ = false;
        timedOut->kill();
        timedOut->deleteLater();
        emit failed(QStringLiteral("The app check took too long. Keep the fields and enter the ID manually."));
    });
}

FocusDetector::~FocusDetector() {
    cancel();
}

bool FocusDetector::start(const QString &fxclipPath, int countdownMilliseconds, int tickMilliseconds) {
    if (active_ || fxclipPath.isEmpty()) return false;
    active_ = true;
    fxclipPath_ = fxclipPath;
    remainingMilliseconds_ = std::max(0, countdownMilliseconds);
    tickMilliseconds_ = std::max(1, tickMilliseconds);
    if (remainingMilliseconds_ == 0) {
        emit countdownTick(0);
        runCheck();
        return true;
    }
    countdownTimer_.setInterval(tickMilliseconds_);
    emit countdownTick((remainingMilliseconds_ + 999) / 1000);
    countdownTimer_.start();
    return true;
}

void FocusDetector::cancel() {
    if (!active_) return;
    active_ = false;
    countdownTimer_.stop();
    processTimeout_.stop();
    if (process_) {
        auto *process = process_;
        process_ = nullptr;
        disconnect(process, nullptr, this, nullptr);
        process->kill();
        process->deleteLater();
    }
    emit canceled();
}

void FocusDetector::runCheck() {
    if (!active_) return;
    emit checking();
    auto *process = new QProcess(this);
    process_ = process;
    connect(process, &QProcess::finished, this,
            [this, process](int exitCode, QProcess::ExitStatus status) {
        finishProcess(process, exitCode, status == QProcess::NormalExit);
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart || process_ != process) return;
        processTimeout_.stop();
        process_ = nullptr;
        active_ = false;
        process->deleteLater();
        emit failed(QStringLiteral("Could not run fxclip check. Keep the fields and enter the ID manually."));
    });
    processTimeout_.start(10000);
    process->start(fxclipPath_, {QStringLiteral("check")});
}

void FocusDetector::finishProcess(QProcess *process, int exitCode, bool normalExit) {
    if (process_ != process) return;
    processTimeout_.stop();
    process_ = nullptr;
    active_ = false;
    const auto output = QString::fromLocal8Bit(process->readAllStandardOutput());
    process->deleteLater();
    if (!normalExit || exitCode != 0) {
        emit failed(QStringLiteral("Could not inspect the focused app. Keep the fields and enter the ID manually."));
        return;
    }
    const auto appId = focusedAppFromCheckOutput(output);
    if (appId.isEmpty()) {
        emit failed(QStringLiteral("No focused Linux app ID was available. Keep the fields and enter the ID manually."));
        return;
    }
    emit detected(appId);
}
