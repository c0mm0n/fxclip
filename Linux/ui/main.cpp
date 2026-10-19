#include "settings_store.h"
#include "focus_detector.h"

#include <QApplication>
#include <QCheckBox>
#include <QCloseEvent>
#include <QCursor>
#include <QDir>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFileInfo>
#include <QFont>
#include <QFrame>
#include <QHBoxLayout>
#include <QIcon>
#include <QJsonArray>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QPainter>
#include <QPainterPath>
#include <QPaintEvent>
#include <QMap>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QRegularExpression>
#include <QSet>
#include <QScrollArea>
#include <QStandardPaths>
#include <QSignalBlocker>
#include <QSystemTrayIcon>
#include <QTextEdit>
#include <QToolButton>
#include <QToolTip>
#include <QStyleOptionFocusRect>
#include <QTimer>
#include <QStyle>
#include <QUrl>
#include <QVector>
#include <QVBoxLayout>

#include <cmath>
#include <functional>
#include <memory>

static QString configPath() {
    QString root = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (root.isEmpty() || !QDir::isAbsolutePath(root)) root = QDir::homePath() + QStringLiteral("/.config");
    return QDir(root).filePath(QStringLiteral("fxclip/settings.json"));
}

static QString appLabel(const QJsonObject &app) {
    return app.value("name").toString(app.value("id").toString());
}

static bool appHasLinuxIdentifier(const QJsonObject &app) {
    return !app.value("linux").toArray().isEmpty();
}

class SwitchCheckBox final : public QCheckBox {
public:
    explicit SwitchCheckBox(QWidget *parent = nullptr) : QCheckBox(parent) {
        setText(QString());
        setFocusPolicy(Qt::StrongFocus);
        setCursor(Qt::PointingHandCursor);
        setFixedSize(48, 28);
    }

    QSize sizeHint() const override { return QSize(48, 28); }
    bool hitButton(const QPoint &position) const override { return rect().contains(position); }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        const QRectF track(1, 3, width() - 2, height() - 6);
        QColor trackColor;
        if (!isEnabled()) trackColor = palette().color(QPalette::Mid);
        else if (isChecked()) trackColor = QColor(QStringLiteral("#1683f5"));
        else trackColor = palette().color(QPalette::Mid);
        painter.setPen(Qt::NoPen);
        painter.setBrush(trackColor);
        painter.drawRoundedRect(track, track.height() / 2, track.height() / 2);
        const qreal diameter = 20;
        const qreal left = isChecked() ? width() - diameter - 4 : 4;
        painter.setBrush(isEnabled() ? palette().color(QPalette::Base) : palette().color(QPalette::Button));
        painter.drawEllipse(QRectF(left, (height() - diameter) / 2, diameter, diameter));
        if (hasFocus()) {
            QStyleOptionFocusRect focus;
            focus.initFrom(this);
            focus.rect = rect().adjusted(0, 0, -1, -1);
            style()->drawPrimitive(QStyle::PE_FrameFocusRect, &focus, &painter, this);
        }
    }
};

static void styleSwitch(QCheckBox *check, const QString &accessibleName) {
    check->setText(QString());
    check->setAccessibleName(accessibleName);
    check->setFocusPolicy(Qt::StrongFocus);
}

static QToolButton *infoButton(const QString &description, QWidget *parent) {
    auto *button = new QToolButton(parent);
    button->setText(QStringLiteral("i"));
    button->setFixedSize(17, 17);
    button->setStyleSheet(QStringLiteral("QToolButton { color: palette(mid); font-size: 11px; font-weight: 700; border: 1px solid palette(mid); border-radius: 8px; padding: 0; }"));
    button->setToolTip(description);
    button->setAccessibleName(QStringLiteral("More information"));
    button->setAccessibleDescription(description);
    button->setAutoRaise(true);
    button->setFocusPolicy(Qt::StrongFocus);
    QObject::connect(button, &QToolButton::clicked, button, [button] {
        QToolTip::showText(QCursor::pos(), button->toolTip(), button);
    });
    return button;
}

static QFrame *card(QWidget *parent = nullptr) {
    auto *frame = new QFrame(parent);
    frame->setObjectName(QStringLiteral("fxclipCard"));
    frame->setFrameShape(QFrame::StyledPanel);
    frame->setFrameShadow(QFrame::Plain);
    frame->setStyleSheet(QStringLiteral("QFrame#fxclipCard { border: 1px solid palette(mid); border-radius: 10px; background: palette(window); }"));
    return frame;
}

class SidebarIcon final : public QWidget {
public:
    explicit SidebarIcon(int page, QWidget *parent = nullptr) : QWidget(parent), page_(page) {
        setFixedSize(24, 24);
        setAttribute(Qt::WA_TransparentForMouseEvents);
    }

protected:
    void paintEvent(QPaintEvent *) override {
        static const QList<QColor> colors{QColor("#ff9f0a"), QColor("#ff3b30"), QColor("#007aff"),
                                          QColor("#5856d6"), QColor("#8e8e93")};
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        const QRectF tile = QRectF(rect()).adjusted(0.25, 0.25, -0.25, -0.25);
        painter.setPen(QPen(QColor(255, 255, 255, 62), 0.5));
        painter.setBrush(colors.value(page_, colors.last()));
        painter.drawRoundedRect(tile, 6, 6);

        QPen line(Qt::white, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
        painter.setPen(line);
        painter.setBrush(Qt::NoBrush);
        switch (page_) {
        case 0: { // gauge.with.dots.needle.33percent
            QPainterPath gauge;
            gauge.moveTo(5.5, 16.5);
            gauge.cubicTo(6.3, 7.5, 17.7, 5.0, 18.5, 16.5);
            painter.drawPath(gauge);
            painter.drawLine(QPointF(12, 13.5), QPointF(16.2, 9.2));
            painter.drawPoint(QPointF(8.2, 11.4));
            painter.drawPoint(QPointF(15.8, 11.4));
            painter.setBrush(Qt::white);
            painter.drawEllipse(QPointF(12, 13.5), 1.1, 1.1);
            break;
        }
        case 1: { // eye.slash.fill
            QPainterPath eye;
            eye.moveTo(3.8, 12);
            eye.cubicTo(6.1, 8.2, 9, 6.3, 12, 6.3);
            eye.cubicTo(16, 6.3, 19, 9.3, 20.2, 12);
            eye.cubicTo(18.2, 15.5, 15.2, 17.7, 12, 17.7);
            eye.cubicTo(8.9, 17.7, 6.1, 15.6, 3.8, 12);
            painter.drawPath(eye);
            painter.drawEllipse(QRectF(10, 10, 4, 4));
            painter.drawLine(QPointF(5, 19), QPointF(19, 5));
            break;
        }
        case 2: { // link
            painter.save();
            painter.translate(12, 12);
            painter.rotate(-45);
            painter.drawRoundedRect(QRectF(-8, -3, 10, 6), 3, 3);
            painter.drawRoundedRect(QRectF(-2, -3, 10, 6), 3, 3);
            painter.restore();
            break;
        }
        case 3: { // hand.raised.fill
            QPainterPath hand;
            hand.moveTo(7.1, 21);
            hand.lineTo(5.4, 15.6);
            hand.lineTo(5.4, 13.2);
            hand.quadTo(5.4, 11.2, 7.2, 11.2);
            hand.quadTo(8.3, 11.2, 9.2, 13.7);
            hand.lineTo(9.2, 5.6);
            hand.quadTo(9.2, 3.4, 11.1, 3.4);
            hand.quadTo(13, 3.4, 13, 5.6);
            hand.lineTo(13, 12.7);
            hand.lineTo(13, 4.8);
            hand.quadTo(13, 2.8, 14.9, 2.8);
            hand.quadTo(16.8, 2.8, 16.8, 4.8);
            hand.lineTo(16.8, 12.7);
            hand.lineTo(16.8, 6.6);
            hand.quadTo(16.8, 4.7, 18.5, 4.7);
            hand.quadTo(20.2, 4.7, 20.2, 6.6);
            hand.lineTo(20.2, 14.4);
            hand.quadTo(20.2, 19.4, 16.1, 21);
            hand.closeSubpath();
            painter.setBrush(Qt::white);
            painter.drawPath(hand);
            break;
        }
        default: { // gearshape.fill
            const QPointF center(12, 12);
            constexpr qreal pi = 3.14159265358979323846;
            for (int i = 0; i < 8; ++i) {
                const qreal angle = i * pi / 4;
                const QPointF inner(center.x() + 5.5 * std::cos(angle), center.y() + 5.5 * std::sin(angle));
                const QPointF outer(center.x() + 8.2 * std::cos(angle), center.y() + 8.2 * std::sin(angle));
                painter.drawLine(inner, outer);
            }
            painter.drawEllipse(QRectF(6.2, 6.2, 11.6, 11.6));
            painter.setBrush(colors.value(page_, colors.last()));
            painter.drawEllipse(QRectF(10, 10, 4, 4));
            break;
        }
        }
    }

private:
    int page_;
};

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(bool screenshotMode)
        : screenshotMode_(screenshotMode) {
        setWindowTitle(QStringLiteral("fxclip"));
        setMinimumSize(850, 600);
        resize(980, 690);
        const QDir applicationDirectory(QCoreApplication::applicationDirPath());
        const QIcon applicationIcon(applicationDirectory.filePath(QStringLiteral("fxclip-icon.png")));
        if (!applicationIcon.isNull()) setWindowIcon(applicationIcon);

        const auto rulesPath = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fxclip.rules.json"));
        if (!store_.load(rulesPath, configPath())) {
            startupError_ = store_.error();
        }

        auto *root = new QWidget(this);
        auto *rootLayout = new QHBoxLayout(root);
        rootLayout->setContentsMargins(0, 0, 0, 0);
        rootLayout->setSpacing(0);

        navigation_ = new QWidget(root);
        navigation_->setObjectName(QStringLiteral("navigation"));
        navigation_->setFixedWidth(218);
        auto *navigationLayout = new QVBoxLayout(navigation_);
        navigationLayout->setContentsMargins(10, 20, 10, 14);
        navigationLayout->setSpacing(3);
        navigation_->setStyleSheet(QStringLiteral(
            "QWidget#navigation { background: palette(alternate-base); }"
            "QPushButton { border: none; border-radius: 10px; background: transparent; color: palette(text); text-align: left; }"
            "QPushButton:hover { background: palette(midlight); }"
            "QPushButton:checked { background: palette(highlight); color: palette(highlighted-text); font-weight: 600; }"
            "QPushButton:focus { outline: 2px solid palette(highlight); outline-offset: -2px; }"));
        const QStringList navTitles{QStringLiteral("Overview"), QStringLiteral("Link cleaning"),
                                    QStringLiteral("App previews"), QStringLiteral("Never clean"),
                                    QStringLiteral("Settings")};
        navigationButtons_.reserve(navTitles.size());
        for (int i = 0; i < navTitles.size(); ++i) {
            auto *button = new QPushButton(navigation_);
            button->setAccessibleName(navTitles[i]);
            button->setCheckable(true);
            button->setFocusPolicy(Qt::StrongFocus);
            button->setMinimumHeight(38);
            auto *buttonLayout = new QHBoxLayout(button);
            buttonLayout->setContentsMargins(8, 0, 10, 0);
            buttonLayout->setSpacing(9);
            buttonLayout->addWidget(new SidebarIcon(i, button));
            auto *label = new QLabel(navTitles[i], button);
            label->setAttribute(Qt::WA_TransparentForMouseEvents);
            QFont labelFont = label->font();
            labelFont.setPointSizeF(10.0);
            label->setFont(labelFont);
            buttonLayout->addWidget(label);
            buttonLayout->addStretch(1);
            connect(button, &QPushButton::clicked, this, [this, i] { setPage(i); });
            navigationButtons_.append(button);
            navigationLabels_.append(label);
            if (i < 4) navigationLayout->addWidget(button);
            else settingsNavigationButton_ = button;
        }
        navigationLayout->addStretch(1);
        navigationLayout->addWidget(settingsNavigationButton_);

        auto *separator = new QFrame(root);
        separator->setFrameShape(QFrame::VLine);
        separator->setFrameShadow(QFrame::Sunken);

        auto *right = new QWidget(root);
        right->setAutoFillBackground(true);
        auto rightPalette = right->palette();
        rightPalette.setColor(QPalette::Window, rightPalette.color(QPalette::Base));
        right->setPalette(rightPalette);
        auto *rightLayout = new QVBoxLayout(right);
        rightLayout->setContentsMargins(0, 0, 0, 0);
        stack_ = new QWidget(right);
        auto *stackLayout = new QVBoxLayout(stack_);
        stackLayout->setContentsMargins(28, 24, 28, 22);
        stackLayout->setSpacing(12);
        title_ = new QLabel(stack_);
        title_->setObjectName(QStringLiteral("pageTitle"));
        QFont titleFont = title_->font();
        titleFont.setPointSize(titleFont.pointSize() + 8);
        titleFont.setWeight(QFont::DemiBold);
        title_->setFont(titleFont);
        subtitle_ = new QLabel(stack_);
        subtitle_->setWordWrap(true);
        subtitle_->setStyleSheet(QStringLiteral("color: palette(text);"));
        body_ = new QWidget(stack_);
        bodyLayout_ = new QVBoxLayout(body_);
        bodyLayout_->setContentsMargins(0, 8, 0, 0);
        bodyLayout_->setSpacing(12);
        auto *titleRow = new QWidget(stack_);
        auto *titleLayout = new QHBoxLayout(titleRow);
        titleLayout->setContentsMargins(0, 0, 0, 0);
        titleLayout->setSpacing(7);
        titleLayout->addWidget(title_, 0, Qt::AlignLeft | Qt::AlignVCenter);
        pageInfoButton_ = infoButton(QString(), titleRow);
        titleLayout->addWidget(pageInfoButton_, 0, Qt::AlignLeft | Qt::AlignVCenter);
        titleLayout->addStretch(1);
        stackLayout->addWidget(titleRow);
        stackLayout->addWidget(subtitle_);
        auto *scroll = new QScrollArea(stack_);
        scroll->setWidgetResizable(true);
        scroll->setFrameShape(QFrame::NoFrame);
        scroll->setWidget(body_);
        stackLayout->addWidget(scroll, 1);
        rightLayout->addWidget(stack_);

        rootLayout->addWidget(navigation_);
        rootLayout->addWidget(separator);
        rootLayout->addWidget(right, 1);
        setCentralWidget(root);

        setPage(0);

        trayAvailable_ = QSystemTrayIcon::isSystemTrayAvailable();
        if (trayAvailable_) {
            QIcon trayIcon(applicationDirectory.filePath(QStringLiteral("fxclip-tray.png")));
            if (trayIcon.isNull()) trayIcon = style()->standardIcon(QStyle::SP_ComputerIcon);
            tray_ = new QSystemTrayIcon(trayIcon, this);
            tray_->setToolTip(QStringLiteral("fxclip link cleaner"));
            auto *menu = new QMenu(this);
            menu->addAction(QStringLiteral("Open fxclip"), this, [this] { showNormal(); raise(); activateWindow(); });
            startTrayAction_ = menu->addAction(QStringLiteral("Start service"), this, [this] { runServiceAction("start"); });
            stopTrayAction_ = menu->addAction(QStringLiteral("Stop service"), this, [this] { runServiceAction("stop"); });
            menu->addSeparator();
            menu->addAction(QStringLiteral("Quit"), qApp, &QApplication::quit);
            tray_->setContextMenu(menu);
            connect(tray_, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
                if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
                    showNormal(); raise(); activateWindow();
                }
            });
            tray_->show();
            qApp->setQuitOnLastWindowClosed(false);
        }

        statusTimer_ = new QTimer(this);
        statusTimer_->setInterval(5000);
        connect(statusTimer_, &QTimer::timeout, this, [this] { refreshService(); });
        statusTimer_->start();
        refreshService();
        refreshLoginState();
        if (screenshotMode_) {
            if (qApp->arguments().contains(QStringLiteral("--helper-shot"))) {
                QTimer::singleShot(350, this, [this] {
                    setPage(2);
                    auto capture = [this](const QString &stage) {
                        auto *modal = qApp->activeModalWidget();
                        const auto directory = qEnvironmentVariable("FXCLIP_UI_HELPER_CAPTURE_DIR");
                        if (!modal || directory.isEmpty()) return;
                        modal->grab().save(QDir(directory).filePath(stage + QStringLiteral(".png")));
                    };
                    QTimer::singleShot(150, this, [this, capture] {
                        QTimer::singleShot(350, this, [capture] { capture(QStringLiteral("initial")); });
                        QTimer::singleShot(600, this, [] {
                            auto *modal = qApp->activeModalWidget();
                            auto *detect = modal ? modal->findChild<QPushButton *>(QStringLiteral("detectLinuxApp")) : nullptr;
                            if (detect) detect->click();
                        });
                        QTimer::singleShot(1200, this, [capture] { capture(QStringLiteral("countdown")); });
                        QTimer::singleShot(7000, this, [capture] { capture(QStringLiteral("detected")); });
                        QTimer::singleShot(7500, this, [] {
                            if (auto *modal = qobject_cast<QDialog *>(qApp->activeModalWidget())) modal->reject();
                            QTimer::singleShot(100, qApp, &QApplication::quit);
                        });
                        addLinuxApp();
                    });
                });
            } else if (qApp->arguments().contains(QStringLiteral("--smoke-pages"))) {
                auto step = std::make_shared<int>(0);
                auto advance = std::make_shared<std::function<void()>>();
                *advance = [this, step, advance] {
                    if (*step < 5) setPage((*step)++);
                    if (*step < 5) QTimer::singleShot(75, this, *advance);
                    else QTimer::singleShot(200, this, [this] { captureAndQuit(); });
                };
                QTimer::singleShot(75, this, *advance);
            } else if (qApp->arguments().contains(QStringLiteral("--page-shot"))) {
                const int row = qBound(0, qEnvironmentVariableIntValue("FXCLIP_UI_PAGE"), 4);
                setPage(row);
                QTimer::singleShot(450, this, [this] { captureAndQuit(); });
            } else {
                QTimer::singleShot(350, this, [this] { captureAndQuit(); });
            }
        }
    }

protected:
    void closeEvent(QCloseEvent *event) override {
        if (trayAvailable_ && !screenshotMode_) {
            hide();
            event->ignore();
            if (tray_) tray_->showMessage(QStringLiteral("fxclip is still running"),
                                          QStringLiteral("Choose Quit from the tray menu to exit."),
                                          QSystemTrayIcon::Information, 2500);
            return;
        }
        event->accept();
    }

private:
    void setPage(int row) {
        currentPage_ = qBound(0, row, navigationButtons_.size() - 1);
        for (int i = 0; i < navigationButtons_.size(); ++i) {
            navigationButtons_[i]->setChecked(i == currentPage_);
            auto font = navigationLabels_[i]->font();
            font.setWeight(i == currentPage_ ? QFont::DemiBold : QFont::Medium);
            navigationLabels_[i]->setFont(font);
            navigationLabels_[i]->setStyleSheet(i == currentPage_
                ? QStringLiteral("color: palette(highlighted-text);")
                : QString());
        }
        renderPage(currentPage_);
    }

    void clearBody() {
        serviceLabel_ = settingsServiceLabel_ = nullptr;
        startButton_ = stopButton_ = settingsStartButton_ = settingsStopButton_ = nullptr;
        loginCheckBox_ = nullptr;
        diagnostics_ = nullptr;
        while (auto *item = bodyLayout_->takeAt(0)) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
    }

    void captureAndQuit() {
        const auto path = qEnvironmentVariable("FXCLIP_UI_SCREENSHOT");
        if (!path.isEmpty()) grab().save(path);
        qApp->quit();
    }

    void renderPage(int row) {
        clearBody();
        const QStringList titles{QStringLiteral("Overview"), QStringLiteral("Link cleaning"),
                                 QStringLiteral("App previews"), QStringLiteral("Never clean"),
                                 QStringLiteral("Settings")};
        const QStringList descriptions{
            QStringLiteral("See whether the clipboard service is ready and open actionable diagnostics."),
            QStringLiteral("Choose which tracking parameters fxclip removes from copied links."),
            QStringLiteral("Choose where X and Instagram links become preview-friendly mirrors."),
            QStringLiteral("Keep links from selected websites unchanged."),
            QStringLiteral("Manage the user service, startup behavior and local settings file.")};
        row = qBound(0, row, titles.size() - 1);
        title_->setText(titles[row]);
        subtitle_->setText(descriptions[row]);
        subtitle_->setVisible(row != 1 && row != 2);
        pageInfoButton_->setVisible(row == 1 || row == 2);
        pageInfoButton_->setToolTip(row == 1
            ? QStringLiteral("Fxclip removes the selected parameters and tracking prefixes. Amazon links can also have their referral path removed.")
            : QStringLiteral("Choose which apps receive X and Instagram preview links. Changes apply when you select Apply."));
        if (!startupError_.isEmpty()) {
            auto *label = new QLabel(startupError_, body_);
            label->setWordWrap(true);
            label->setStyleSheet(QStringLiteral("color: #c0392b; padding: 8px;"));
            bodyLayout_->addWidget(label);
            return;
        }
        if (!store_.error().isEmpty()) {
            auto *warning = new QLabel(store_.error() + QStringLiteral(" Existing settings will not be overwritten."), body_);
            warning->setWordWrap(true);
            warning->setStyleSheet(QStringLiteral("color: #c0392b; padding: 8px;"));
            bodyLayout_->addWidget(warning);
        }
        if (row == 0) buildOverview();
        else if (row == 1) buildTrackers();
        else if (row == 2) buildPreviews();
        else if (row == 3) buildNeverClean();
        else buildSettings();
        bodyLayout_->addStretch(1);
    }

    void buildOverview() {
        auto *frame = card(body_);
        auto *layout = new QVBoxLayout(frame);
        layout->setContentsMargins(18, 16, 18, 16);
        auto *heading = new QLabel(QStringLiteral("Clipboard service"), frame);
        QFont font = heading->font(); font.setWeight(QFont::DemiBold); heading->setFont(font);
        serviceLabel_ = new QLabel(serviceSummary_, frame);
        serviceLabel_->setWordWrap(true);
        auto *buttons = new QHBoxLayout;
        startButton_ = new QPushButton(QStringLiteral("Start"), frame);
        stopButton_ = new QPushButton(QStringLiteral("Stop"), frame);
        auto *check = new QPushButton(QStringLiteral("Run diagnostics"), frame);
        buttons->addWidget(startButton_); buttons->addWidget(stopButton_); buttons->addStretch(); buttons->addWidget(check);
        connect(startButton_, &QPushButton::clicked, this, [this] { runServiceAction("start"); });
        connect(stopButton_, &QPushButton::clicked, this, [this] { runServiceAction("stop"); });
        connect(check, &QPushButton::clicked, this, [this] { runDiagnostics(); });
        layout->addWidget(heading); layout->addWidget(serviceLabel_); layout->addLayout(buttons);
        bodyLayout_->addWidget(frame);

        diagnostics_ = new QTextEdit(body_);
        diagnostics_->setObjectName(QStringLiteral("diagnostics"));
        diagnostics_->setReadOnly(true);
        diagnostics_->setPlaceholderText(QStringLiteral("Wayland and service diagnostics will appear here."));
        diagnostics_->setMinimumHeight(160);
        diagnostics_->hide();
        bodyLayout_->addWidget(diagnostics_);
        updateServiceButtons();

        auto *info = new QLabel(QStringLiteral("fxclip keeps the service headless. Closing this window leaves the service running; it does not pause or stop it."), body_);
        info->setWordWrap(true);
        bodyLayout_->addWidget(info);
    }

    void buildPreviews() {
        for (const auto &value : store_.previews()) {
            const auto preview = value.toObject();
            const auto id = preview.value("id").toString();
            auto *frame = card(body_);
            auto *layout = new QVBoxLayout(frame);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSpacing(0);
            auto *headingWidget = new QWidget(frame);
            auto *heading = new QHBoxLayout(headingWidget);
            heading->setContentsMargins(16, 13, 16, 13);
            heading->setSpacing(12);
            const auto appName = preview.value("name").toString();
            auto *badge = new QLabel(appName.left(1), headingWidget);
            badge->setAlignment(Qt::AlignCenter);
            badge->setFixedSize(42, 42);
            badge->setStyleSheet(QStringLiteral("QLabel { background: palette(mid); border-radius: 21px; font-size: 16px; font-weight: 700; }"));
            auto *nameAndRoute = new QVBoxLayout;
            nameAndRoute->setSpacing(2);
            auto *name = new QLabel(appName, headingWidget);
            QFont font = name->font(); font.setWeight(QFont::DemiBold); name->setFont(font);
            QStringList sources;
            for (const auto &source : preview.value("from").toArray()) {
                const auto host = source.toString();
                if (!host.startsWith("www.") && !host.startsWith("mobile.")) sources.append(host);
            }
            auto *route = new QLabel(QStringLiteral("%1 → %2").arg(sources.join(QStringLiteral(", ")), preview.value("to").toString()), headingWidget);
            route->setStyleSheet(QStringLiteral("color: palette(text);"));
            nameAndRoute->addWidget(name);
            nameAndRoute->addWidget(route);
            auto *enabled = new SwitchCheckBox(headingWidget);
            enabled->setChecked(store_.previewEnabled(id));
            enabled->setEnabled(store_.editable());
            styleSwitch(enabled, QStringLiteral("Enable %1 app previews").arg(appName));
            heading->addWidget(badge);
            heading->addLayout(nameAndRoute, 1);
            heading->addWidget(enabled);
            layout->addWidget(headingWidget);

            auto *footer = new QWidget(frame);
            footer->setObjectName(QStringLiteral("previewFooter"));
            const auto windowColor = palette().color(QPalette::Window);
            const auto textColor = palette().color(QPalette::WindowText);
            const QColor footerColor(
                qRound(windowColor.red() * 0.92 + textColor.red() * 0.08),
                qRound(windowColor.green() * 0.92 + textColor.green() * 0.08),
                qRound(windowColor.blue() * 0.92 + textColor.blue() * 0.08));
            footer->setStyleSheet(QStringLiteral("QWidget#previewFooter { background: %1; border-bottom-left-radius: 10px; border-bottom-right-radius: 10px; }").arg(footerColor.name()));
            auto *footerLayout = new QHBoxLayout(footer);
            footerLayout->setContentsMargins(14, 8, 14, 8);
            footerLayout->setSpacing(7);
            const auto selected = store_.previewApps(id);
            if (selected.isEmpty()) {
                auto *empty = new QLabel(QStringLiteral("No apps selected"), footer);
                empty->setStyleSheet(QStringLiteral("color: palette(text); background: transparent;"));
                footerLayout->addWidget(empty);
            } else {
                for (const auto &appId : selected) {
                    QString label = appId;
                    for (const auto &appValue : store_.apps()) {
                        const auto app = appValue.toObject();
                        if (app.value("id").toString() == appId) { label = appLabel(app); break; }
                    }
                    auto *chip = new QLabel(label, footer);
                    chip->setStyleSheet(QStringLiteral("QLabel { background: palette(mid); border-radius: 11px; padding: 3px 10px; }"));
                    footerLayout->addWidget(chip);
                }
            }
            auto *change = new QPushButton(QStringLiteral("+ Change apps"), footer);
            change->setEnabled(store_.editable());
            footerLayout->addWidget(change);
            footerLayout->addStretch(1);
            layout->addWidget(footer);
            connect(change, &QPushButton::clicked, this, [this, id] { choosePreviewApps(id); });
            connect(enabled, &QCheckBox::toggled, this, [this, id](bool checked) {
                if (!store_.setPreview(id, checked, store_.previewApps(id))) {
                    showError(store_.error());
                    renderPage(2);
                }
            });
            bodyLayout_->addWidget(frame);
        }

        auto *add = new QPushButton(QStringLiteral("Add Linux app…"), body_);
        add->setEnabled(store_.editable());
        connect(add, &QPushButton::clicked, this, [this] { addLinuxApp(); });
        bodyLayout_->addWidget(add, 0, Qt::AlignLeft);
    }

    void buildTrackers() {
        auto *frame = card(body_);
        auto *layout = new QVBoxLayout(frame);
        layout->setContentsMargins(14, 4, 14, 4);
        layout->setSpacing(0);
        auto *globalRow = new QWidget(frame);
        auto *globalLayout = new QHBoxLayout(globalRow);
        globalLayout->setContentsMargins(4, 7, 4, 7);
        auto *globalName = new QLabel(QStringLiteral("All websites"), globalRow);
        QFont globalFont = globalName->font(); globalFont.setWeight(QFont::DemiBold); globalName->setFont(globalFont);
        const auto globalRules = store_.rules().value("trackers").toObject().value("everywhere").toObject();
        const int globalCount = globalRules.value("params").toArray().size() + globalRules.value("prefixes").toArray().size();
        auto *globalCountLabel = new QLabel(QStringLiteral("%1 trackers").arg(globalCount), globalRow);
        globalCountLabel->setStyleSheet(QStringLiteral("color: palette(text);"));
        QStringList globalParams, globalPrefixes;
        for (const auto &entry : globalRules.value("params").toArray()) globalParams.append(entry.toString());
        for (const auto &entry : globalRules.value("prefixes").toArray()) globalPrefixes.append(entry.toString());
        auto *globalInfo = infoButton(QStringLiteral("Parameters: %1\nPrefixes: %2").arg(globalParams.join(QStringLiteral(", ")), globalPrefixes.join(QStringLiteral(", "))), globalRow);
        auto *global = new SwitchCheckBox(globalRow);
        global->setChecked(store_.trackersEverywhere());
        global->setEnabled(store_.editable());
        styleSwitch(global, QStringLiteral("Remove common trackers on all websites"));
        globalLayout->addWidget(globalName, 1);
        globalLayout->addWidget(globalCountLabel);
        globalLayout->addWidget(globalInfo);
        globalLayout->addWidget(global);
        layout->addWidget(globalRow);
        auto *separator = new QFrame(frame);
        separator->setFrameShape(QFrame::HLine);
        separator->setStyleSheet(QStringLiteral("QFrame { color: palette(midlight); }"));
        layout->addWidget(separator);
        connect(global, &QCheckBox::toggled, this, [this](bool checked) {
            if (!store_.setTrackersEverywhere(checked)) { showError(store_.error()); renderPage(1); }
        });
        QJsonArray sites = store_.trackerSites();
        int siteIndex = 0;
        for (const auto &value : sites) {
            const auto site = value.toObject();
            const auto id = site.value("id").toString();
            QStringList trackers;
            for (const auto &item : site.value("params").toArray()) trackers.append(item.toString());
            QStringList hosts;
            for (const auto &host : site.value("hosts").toArray()) hosts.append(host.toString());
            QString tooltip = QStringLiteral("Hosts: %1\nParameters: %2").arg(hosts.join(QStringLiteral(", ")), trackers.join(QStringLiteral(", ")));
            if (site.value("stripRefPath").toBool()) tooltip += QStringLiteral("\nAlso removes referral data from the URL path.");
            auto *line = new QWidget(frame);
            auto *row = new QHBoxLayout(line); row->setContentsMargins(4, 6, 4, 6); row->setSpacing(8);
            auto *name = new QLabel(site.value("name").toString(), line);
            auto *check = new SwitchCheckBox(line);
            check->setChecked(store_.siteEnabled(id));
            check->setEnabled(store_.editable());
            styleSwitch(check, QStringLiteral("Remove trackers from %1 links").arg(name->text()));
            auto *count = new QLabel(QStringLiteral("%1 trackers").arg(trackers.size()), line);
            count->setStyleSheet(QStringLiteral("color: palette(text);"));
            row->addWidget(name, 1);
            row->addWidget(count);
            row->addWidget(infoButton(tooltip, line));
            row->addWidget(check);
            connect(check, &QCheckBox::toggled, this, [this, id](bool checked) {
                if (!store_.setSiteEnabled(id, checked)) { showError(store_.error()); renderPage(1); }
            });
            line->setMinimumHeight(40);
            if (siteIndex > 0) {
                auto *rowSeparator = new QFrame(frame);
                rowSeparator->setFrameShape(QFrame::HLine);
                rowSeparator->setStyleSheet(QStringLiteral("QFrame { color: palette(midlight); }"));
                layout->addWidget(rowSeparator);
            }
            layout->addWidget(line);
            ++siteIndex;
        }
        bodyLayout_->addWidget(frame);
    }

    void buildNeverClean() {
        auto *frame = card(body_);
        auto *layout = new QVBoxLayout(frame);
        layout->setContentsMargins(16, 12, 16, 12);
        const auto entries = store_.neverClean();
        for (int i = 0; i < entries.size(); ++i) {
            const auto entry = entries.at(i).toObject();
            auto *rowWidget = new QWidget(frame);
            auto *row = new QHBoxLayout(rowWidget); row->setContentsMargins(0, 2, 0, 2);
            auto *host = new QLabel(entry.value("host").toString(), rowWidget);
            QFont mono = host->font(); mono.setFamily(QStringLiteral("monospace")); host->setFont(mono);
            auto *subdomains = new QLabel(entry.value("subdomains").toBool() ? QStringLiteral("and subdomains") : QString(), rowWidget);
            row->addWidget(host); row->addWidget(subdomains); row->addStretch();
            auto *remove = new QPushButton(QStringLiteral("Remove"), rowWidget);
            remove->setEnabled(store_.editable());
            connect(remove, &QPushButton::clicked, this, [this, i] {
                if (!store_.removeNeverClean(i)) showError(store_.error());
                renderPage(3);
            });
            row->addWidget(remove); layout->addWidget(rowWidget);
        }
        if (entries.isEmpty()) layout->addWidget(new QLabel(QStringLiteral("No websites are excluded."), frame));
        auto *form = new QWidget(frame);
        auto *formLayout = new QHBoxLayout(form); formLayout->setContentsMargins(0, 8, 0, 0);
        auto *host = new QLineEdit(form); host->setPlaceholderText(QStringLiteral("Website, e.g. example.com"));
        auto *subdomains = new QCheckBox(QStringLiteral("Include subdomains"), form); subdomains->setChecked(true);
        auto *add = new QPushButton(QStringLiteral("Add"), form); add->setEnabled(store_.editable());
        formLayout->addWidget(host, 1); formLayout->addWidget(subdomains); formLayout->addWidget(add);
        connect(add, &QPushButton::clicked, this, [this, host, subdomains] { addNeverClean(host->text(), subdomains->isChecked()); });
        connect(host, &QLineEdit::returnPressed, add, &QPushButton::click);
        layout->addWidget(form);
        bodyLayout_->addWidget(frame);
    }

    void buildSettings() {
        auto *service = card(body_);
        auto *serviceLayout = new QVBoxLayout(service);
        serviceLayout->setContentsMargins(16, 13, 16, 13);
        serviceLayout->addWidget(new QLabel(QStringLiteral("Background service"), service));
        settingsServiceLabel_ = new QLabel(serviceSummary_, service);
        settingsServiceLabel_->setWordWrap(true);
        serviceLayout->addWidget(settingsServiceLabel_);
        auto *actions = new QHBoxLayout;
        auto *start = new QPushButton(QStringLiteral("Start service"), service);
        auto *stop = new QPushButton(QStringLiteral("Stop service"), service);
        settingsStartButton_ = start;
        settingsStopButton_ = stop;
        connect(start, &QPushButton::clicked, this, [this] { runServiceAction("start"); });
        connect(stop, &QPushButton::clicked, this, [this] { runServiceAction("stop"); });
        actions->addWidget(start); actions->addWidget(stop); actions->addStretch();
        serviceLayout->addLayout(actions);
        auto *login = new QCheckBox(QStringLiteral("Start fxclip automatically at desktop login"), service);
        loginCheckBox_ = login;
        login->setChecked(loginEnabled_);
        login->setEnabled(unitFound_ && !loginBusy_);
        connect(login, &QCheckBox::toggled, this, [this](bool enabled) { setLoginEnabled(enabled); });
        serviceLayout->addWidget(login);
        updateServiceButtons();
        bodyLayout_->addWidget(service);

        auto *paths = card(body_);
        auto *pathsLayout = new QVBoxLayout(paths);
        pathsLayout->setContentsMargins(16, 12, 16, 12);
        auto *settingsPath = new QLabel(QStringLiteral("Settings file: %1").arg(store_.settingsPath()), paths);
        settingsPath->setWordWrap(true);
        pathsLayout->addWidget(settingsPath);
        auto *rulesPath = new QLabel(QStringLiteral("Rules file: %1/fxclip.rules.json").arg(QCoreApplication::applicationDirPath()), paths);
        rulesPath->setWordWrap(true);
        pathsLayout->addWidget(rulesPath);
        if (!store_.editable()) {
            auto *warning = new QLabel(store_.error() + QStringLiteral(" Settings are read-only until this is fixed."), paths);
            warning->setWordWrap(true); warning->setStyleSheet(QStringLiteral("color: #c0392b;"));
            pathsLayout->addWidget(warning);
        }
        if (!store_.error().isEmpty()) {
            auto *reload = new QPushButton(QStringLiteral("Reload settings from disk"), paths);
            connect(reload, &QPushButton::clicked, this, [this] {
                const bool ok = store_.reload();
                if (!ok) startupError_ = store_.error();
                else startupError_.clear();
                if (!store_.editable() && !store_.error().isEmpty()) showError(store_.error());
                renderPage(currentPage_);
            });
            pathsLayout->addWidget(reload);
        }
        bodyLayout_->addWidget(paths);

        auto *diag = new QPushButton(QStringLiteral("Run Wayland and service check"), body_);
        connect(diag, &QPushButton::clicked, this, [this] { runDiagnostics(); });
        bodyLayout_->addWidget(diag, 0, Qt::AlignLeft);
        if (!diagnosticsText_.isEmpty()) {
            auto *output = new QTextEdit(body_); output->setReadOnly(true); output->setPlainText(diagnosticsText_); output->setMinimumHeight(150);
            bodyLayout_->addWidget(output);
        }
    }

    void addLinuxApp() {
        QDialog dialog(this);
        dialog.setWindowTitle(QStringLiteral("Add Linux app"));
        dialog.setMinimumWidth(440);
        auto *layout = new QVBoxLayout(&dialog);
        auto *instruction = new QLabel(QStringLiteral("Enter a name and Linux app identifier, or click Detect, then switch to your app."), &dialog);
        instruction->setWordWrap(true);
        layout->addWidget(instruction);

        auto *nameEdit = new QLineEdit(&dialog);
        nameEdit->setObjectName(QStringLiteral("linuxAppName"));
        nameEdit->setAccessibleName(QStringLiteral("App name"));
        nameEdit->setPlaceholderText(QStringLiteral("App name"));
        layout->addWidget(new QLabel(QStringLiteral("App name"), &dialog));
        layout->addWidget(nameEdit);
        auto *identifierEdit = new QLineEdit(&dialog);
        identifierEdit->setObjectName(QStringLiteral("linuxAppIdentifier"));
        identifierEdit->setAccessibleName(QStringLiteral("Linux app identifier"));
        identifierEdit->setPlaceholderText(QStringLiteral("Wayland app_id or X11 window class"));
        layout->addWidget(new QLabel(QStringLiteral("Linux app identifier"), &dialog));
        layout->addWidget(identifierEdit);

        auto *status = new QLabel(&dialog);
        status->setObjectName(QStringLiteral("linuxAppDetectionStatus"));
        status->setWordWrap(true);
        status->setMinimumHeight(34);
        layout->addWidget(status);

        auto *actions = new QHBoxLayout;
        auto *detect = new QPushButton(QStringLiteral("Detect app"), &dialog);
        detect->setObjectName(QStringLiteral("detectLinuxApp"));
        detect->setAccessibleName(QStringLiteral("Detect the currently focused app"));
        actions->addWidget(detect);
        actions->addStretch(1);
        auto *cancel = new QPushButton(QStringLiteral("Cancel"), &dialog);
        auto *add = new QPushButton(QStringLiteral("Add"), &dialog);
        add->setDefault(true);
        actions->addWidget(cancel);
        actions->addWidget(add);
        layout->addLayout(actions);

        auto mappedName = [this](const QString &appId) {
            for (const auto &value : store_.apps()) {
                const auto app = value.toObject();
                if (!appHasLinuxIdentifier(app)) continue;
                for (const auto &candidate : app.value("linux").toArray()) {
                    if (candidate.toString().compare(appId, Qt::CaseInsensitive) == 0) return appLabel(app);
                }
            }
            return QString();
        };
        auto detectionBusy = std::make_shared<bool>(false);
        auto updateAdd = [this, nameEdit, identifierEdit, add, status, mappedName, detectionBusy] {
            const auto name = nameEdit->text().trimmed();
            const auto appId = identifierEdit->text().trimmed();
            const bool validId = !appId.isEmpty() && !appId.contains(QRegularExpression(QStringLiteral("\\s")));
            const auto existing = validId ? mappedName(appId) : QString();
            add->setEnabled(store_.editable() && !*detectionBusy && !name.isEmpty() && validId && existing.isEmpty());
            if (!existing.isEmpty()) {
                status->setProperty("duplicateWarning", true);
                status->setText(QStringLiteral("%1 is already available. Choose it with Change apps instead of adding another mapping.").arg(existing));
            } else if (status->property("duplicateWarning").toBool()) {
                status->setProperty("duplicateWarning", false);
                status->clear();
            }
        };
        auto setDetectionBusy = [nameEdit, identifierEdit, detectionBusy, updateAdd](bool busy) {
            *detectionBusy = busy;
            nameEdit->setEnabled(!busy);
            identifierEdit->setEnabled(!busy);
            updateAdd();
        };
        connect(nameEdit, &QLineEdit::textChanged, &dialog, [updateAdd] { updateAdd(); });
        connect(identifierEdit, &QLineEdit::textChanged, &dialog, [updateAdd] { updateAdd(); });
        connect(cancel, &QPushButton::clicked, &dialog, &QDialog::reject);
        FocusDetector detector;
        connect(&detector, &FocusDetector::countdownTick, &dialog, [status](int seconds) {
            if (seconds > 0) status->setText(QStringLiteral("Switch to your app now (%1)…").arg(seconds));
        });
        connect(&detector, &FocusDetector::checking, &dialog, [status] {
            status->setText(QStringLiteral("Reading the focused app ID…"));
        });
        connect(&detector, &FocusDetector::failed, &dialog, [detect, status, setDetectionBusy](const QString &message) {
            setDetectionBusy(false);
            detect->setText(QStringLiteral("Detect app"));
            status->setText(message);
        });
        connect(&detector, &FocusDetector::canceled, &dialog, [detect, status, setDetectionBusy] {
            setDetectionBusy(false);
            detect->setText(QStringLiteral("Detect app"));
            status->setText(QStringLiteral("Detection canceled."));
        });
        connect(&detector, &FocusDetector::detected, &dialog,
            [this, detect, status, nameEdit, identifierEdit, mappedName, setDetectionBusy](QString appId) {
                setDetectionBusy(false);
                detect->setText(QStringLiteral("Detect app"));
                const auto ownDesktopId = QGuiApplication::desktopFileName();
                if (appId.compare(ownDesktopId, Qt::CaseInsensitive) == 0 ||
                    appId.compare(QStringLiteral("fxclip"), Qt::CaseInsensitive) == 0 ||
                    appId.compare(QStringLiteral("fxclip-ui"), Qt::CaseInsensitive) == 0) {
                    status->setText(QStringLiteral("fxclip itself is focused. Switch to the app you want, then detect again."));
                    return;
                }

                QString detectedNote;
                static const QRegularExpression telegramWindowId(
                    QStringLiteral("^org\\.telegram\\.desktop\\._[0-9a-f]{32}$"), QRegularExpression::CaseInsensitiveOption);
                if (telegramWindowId.match(appId).hasMatch()) {
                    appId = QStringLiteral("org.telegram.desktop");
                    detectedNote = QStringLiteral("KDE returned a per-window Telegram ID. Using the stable built-in ID instead.");
                }
                identifierEdit->setText(appId);
                if (nameEdit->text().trimmed().isEmpty()) {
                    auto suggestedName = appId.section(QLatin1Char('.'), -1);
                    if (suggestedName.isEmpty()) suggestedName = appId;
                    const auto existing = mappedName(appId);
                    nameEdit->setText(existing.isEmpty() ? suggestedName : existing);
                }
                const auto existing = mappedName(appId);
                if (!existing.isEmpty()) {
                    status->setText(detectedNote.isEmpty()
                        ? QStringLiteral("%1 is already available. Choose it with Change apps instead of adding another mapping.").arg(existing)
                        : detectedNote + QStringLiteral(" %1 is already available in Change apps.").arg(existing));
                } else {
                    status->setText(detectedNote.isEmpty()
                        ? QStringLiteral("Detected %1. Review the fields, then add the app.").arg(appId)
                        : detectedNote + QStringLiteral(" Review the fields before continuing."));
                }
            });
        connect(detect, &QPushButton::clicked, &dialog, [this, detect, status, &detector, setDetectionBusy] {
            if (detector.active()) {
                detector.cancel();
                return;
            }
            const auto executable = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fxclip"));
            if (!QFileInfo(executable).isExecutable()) {
                status->setText(QStringLiteral("Cannot find fxclip beside this window. Add the app ID manually or reinstall the package."));
                return;
            }
            setDetectionBusy(true);
            detect->setText(QStringLiteral("Cancel detection"));
            if (!detector.start(executable)) {
                setDetectionBusy(false);
                detect->setText(QStringLiteral("Detect app"));
                status->setText(QStringLiteral("Could not start app detection."));
            }
        });

        connect(add, &QPushButton::clicked, &dialog, [this, &dialog, nameEdit, identifierEdit, status, updateAdd, add] {
            updateAdd();
            if (!add->isEnabled()) return;
            if (!store_.addLinuxApp(nameEdit->text().trimmed(), identifierEdit->text().trimmed())) {
                status->setText(store_.error());
                return;
            }
            dialog.accept();
        });
        updateAdd();
        if (dialog.exec() == QDialog::Accepted) renderPage(2);
    }

    void choosePreviewApps(const QString &id) {
        QDialog dialog(this);
        dialog.setWindowTitle(QStringLiteral("Choose apps"));
        auto *layout = new QVBoxLayout(&dialog);
        layout->addWidget(new QLabel(QStringLiteral("Select the apps that should receive these preview links."), &dialog));
        const auto selected = store_.previewApps(id);
        QSet<QString> represented;
        QList<QCheckBox *> choices;
        for (const auto &value : store_.apps()) {
            const auto app = value.toObject();
            if (!appHasLinuxIdentifier(app)) continue;
            const auto appId = app.value("id").toString();
            auto *choice = new QCheckBox(appLabel(app), &dialog);
            choice->setAccessibleName(QStringLiteral("Send previews to %1").arg(appLabel(app)));
            choice->setProperty("appId", appId);
            choice->setChecked(selected.contains(appId));
            choice->setEnabled(store_.editable());
            layout->addWidget(choice);
            choices.append(choice);
            represented.insert(appId);
        }
        for (const auto &appId : selected) {
            if (represented.contains(appId)) continue;
            auto *choice = new QCheckBox(QStringLiteral("Other app (%1)").arg(appId), &dialog);
            choice->setChecked(true);
            choice->setEnabled(false);
            choice->setToolTip(QStringLiteral("This selected app ID is not mapped on Linux and will be preserved."));
            choice->setProperty("appId", appId);
            layout->addWidget(choice);
            choices.append(choice);
        }
        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Cancel, &dialog);
        buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);
        connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
        connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        if (dialog.exec() != QDialog::Accepted) return;
        QStringList appIds;
        for (const auto *choice : choices) if (choice->isChecked()) appIds.append(choice->property("appId").toString());
        if (!store_.setPreview(id, store_.previewEnabled(id), appIds)) showError(store_.error());
        renderPage(2);
    }

    void addNeverClean(const QString &input, bool subdomains) {
        const auto text = input.trimmed();
        if (text.isEmpty()) return;
        QUrl url(text.contains(QStringLiteral("://")) ? text : QStringLiteral("https://") + text);
        const auto host = url.host().toLower();
        if (host.isEmpty() || !host.contains('.')) {
            showError(QStringLiteral("Enter a website hostname such as example.com."));
            return;
        }
        if (!store_.addNeverClean(host, subdomains)) showError(store_.error());
        renderPage(3);
    }

    void showError(const QString &message) {
        if (!message.isEmpty()) QMessageBox::warning(this, QStringLiteral("fxclip"), message);
    }

    using CommandDone = std::function<void(int, const QString &, const QString &)>;
    void runCommand(const QString &program, const QStringList &arguments, CommandDone done) {
        auto *process = new QProcess(this);
        auto completed = std::make_shared<bool>(false);
        connect(process, &QProcess::finished, this,
                [process, done, completed](int code, QProcess::ExitStatus) {
            if (*completed) return;
            *completed = true;
            const auto out = QString::fromLocal8Bit(process->readAllStandardOutput());
            const auto err = QString::fromLocal8Bit(process->readAllStandardError());
            done(code, out, err);
            process->deleteLater();
        });
        connect(process, &QProcess::errorOccurred, this,
                [process, done, completed](QProcess::ProcessError error) {
            if (error != QProcess::FailedToStart || *completed) return;
            *completed = true;
            const auto err = process->errorString();
            done(-1, {}, err);
            process->deleteLater();
        });
        QTimer::singleShot(10000, process, [process, done, completed] {
            if (*completed || process->state() == QProcess::NotRunning) return;
            *completed = true;
            process->kill();
            done(-1, {}, QStringLiteral("Command timed out."));
            process->deleteLater();
        });
        process->start(program, arguments);
    }

    void refreshService() {
        if (statusBusy_) return;
        statusBusy_ = true;
        runCommand(QStringLiteral("systemctl"), {"--user", "show", "fxclip.service", "--no-pager",
            "--property=LoadState", "--property=ActiveState", "--property=SubState", "--property=Result"},
            [this](int code, const QString &out, const QString &err) {
                statusBusy_ = false;
                if (code != 0) {
                    unitFound_ = false; serviceState_.clear();
                    serviceSummary_ = QStringLiteral("Cannot query the systemd user manager: %1")
                                          .arg(err.trimmed().isEmpty() ? out.trimmed() : err.trimmed());
                } else {
                    QMap<QString, QString> fields;
                    for (const auto &line : out.split('\n')) {
                        const auto separator = line.indexOf('=');
                        if (separator > 0) fields.insert(line.left(separator), line.mid(separator + 1).trimmed());
                    }
                    unitFound_ = fields.value("LoadState") != "not-found";
                    serviceState_ = fields.value("ActiveState");
                    const auto sub = fields.value("SubState");
                    const auto result = fields.value("Result");
                    if (!unitFound_) serviceSummary_ = QStringLiteral("Service unit is missing. Install the Linux package to add fxclip.service.");
                    else if (serviceState_ == "active") serviceSummary_ = QStringLiteral("Running (%1). Clipboard cleaning is active.").arg(sub);
                    else if (serviceState_ == "failed") serviceSummary_ = QStringLiteral("Service failed (%1). Run the Wayland check below, then inspect `journalctl --user -u fxclip.service`.").arg(result);
                    else if (serviceState_ == "activating") serviceSummary_ = QStringLiteral("Service is starting (%1)…").arg(sub);
                    else serviceSummary_ = QStringLiteral("Service is stopped (%1). The clipboard is not being watched.").arg(sub);
                }
                updateServiceButtons();
            });
    }

    void updateServiceButtons() {
        if (serviceLabel_) serviceLabel_->setText(serviceSummary_);
        if (settingsServiceLabel_) settingsServiceLabel_->setText(serviceSummary_);
        if (startButton_) startButton_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ != "active");
        if (stopButton_) stopButton_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ == "active");
        if (settingsStartButton_) settingsStartButton_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ != "active");
        if (settingsStopButton_) settingsStopButton_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ == "active");
        if (startTrayAction_) startTrayAction_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ != "active");
        if (stopTrayAction_) stopTrayAction_->setEnabled(unitFound_ && !serviceBusy_ && serviceState_ == "active");
        if (loginCheckBox_) loginCheckBox_->setEnabled(unitFound_ && !loginBusy_);
    }

    void runServiceAction(const QString &action) {
        if (!unitFound_ || serviceBusy_) return;
        serviceBusy_ = true;
        updateServiceButtons();
        runCommand(QStringLiteral("systemctl"), {"--user", action, "fxclip.service"},
            [this, action](int code, const QString &out, const QString &err) {
                serviceBusy_ = false;
                if (code != 0) showError(QStringLiteral("Could not %1 fxclip.service: %2")
                                           .arg(action, err.trimmed().isEmpty() ? out.trimmed() : err.trimmed()));
                refreshService();
            });
    }

    void refreshLoginState() {
        if (loginBusy_) return;
        loginBusy_ = true;
        runCommand(QStringLiteral("systemctl"), {"--user", "is-enabled", "fxclip.service"},
            [this](int code, const QString &out, const QString &err) {
                loginBusy_ = false;
                loginEnabled_ = code == 0 && out.trimmed() == "enabled";
                Q_UNUSED(err)
                if (loginCheckBox_) {
                    const QSignalBlocker blocker(loginCheckBox_);
                    loginCheckBox_->setChecked(loginEnabled_);
                }
                updateServiceButtons();
            });
    }

    void setLoginEnabled(bool enabled) {
        if (!unitFound_ || loginBusy_) return;
        loginBusy_ = true;
        runCommand(QStringLiteral("systemctl"), {"--user", enabled ? "enable" : "disable", "fxclip.service"},
            [this, enabled](int code, const QString &, const QString &err) {
                loginBusy_ = false;
                if (code != 0) showError(QStringLiteral("Could not change login startup: %1").arg(err.trimmed()));
                loginEnabled_ = code == 0 && enabled;
                if (loginCheckBox_) {
                    const QSignalBlocker blocker(loginCheckBox_);
                    loginCheckBox_->setChecked(loginEnabled_);
                }
                updateServiceButtons();
            });
    }

    void runDiagnostics() {
        const auto executable = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fxclip"));
        if (!QFileInfo(executable).isExecutable()) {
            showError(QStringLiteral("Cannot find fxclip beside this UI. Reinstall the Linux package."));
            return;
        }
        if (diagnostics_) {
            diagnostics_->setPlainText(QStringLiteral("Checking Wayland and focus…"));
            diagnostics_->show();
        }
        runCommand(executable, {QStringLiteral("check")}, [this](int, const QString &out, const QString &err) {
            diagnosticsText_ = out + (err.isEmpty() ? QString() : QStringLiteral("\n") + err);
            if (diagnostics_) { diagnostics_->setPlainText(diagnosticsText_); diagnostics_->show(); }
            if (currentPage_ == 4) renderPage(4);
        });
    }

    SettingsStore store_;
    QString startupError_, serviceSummary_ = QStringLiteral("Checking service status…"), serviceState_, diagnosticsText_;
    QWidget *navigation_ = nullptr;
    QVector<QPushButton *> navigationButtons_;
    QVector<QLabel *> navigationLabels_;
    QPushButton *settingsNavigationButton_ = nullptr;
    QWidget *stack_ = nullptr, *body_ = nullptr;
    QVBoxLayout *bodyLayout_ = nullptr;
    QLabel *title_ = nullptr, *subtitle_ = nullptr, *serviceLabel_ = nullptr, *settingsServiceLabel_ = nullptr;
    QToolButton *pageInfoButton_ = nullptr;
    QPushButton *startButton_ = nullptr, *stopButton_ = nullptr, *settingsStartButton_ = nullptr, *settingsStopButton_ = nullptr;
    QCheckBox *loginCheckBox_ = nullptr;
    QAction *startTrayAction_ = nullptr, *stopTrayAction_ = nullptr;
    QTextEdit *diagnostics_ = nullptr;
    QTimer *statusTimer_ = nullptr;
    QSystemTrayIcon *tray_ = nullptr;
    int currentPage_ = 0;
    bool trayAvailable_ = false, screenshotMode_ = false, unitFound_ = false, serviceBusy_ = false;
    bool statusBusy_ = false, loginBusy_ = false, loginEnabled_ = false;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("fxclip"));
    app.setOrganizationName(QStringLiteral("fxclip"));
    app.setDesktopFileName(QStringLiteral("io.github.fxclip.Fxclip"));
    const auto applicationIconPath = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fxclip-icon.png"));
    const QIcon applicationIcon(applicationIconPath);
    if (!applicationIcon.isNull()) app.setWindowIcon(applicationIcon);
    if (app.arguments().contains(QStringLiteral("--icon-check"))) {
        QIcon trayIcon(QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fxclip-tray.png")));
        if (trayIcon.isNull()) trayIcon = app.style()->standardIcon(QStyle::SP_ComputerIcon);
        if (applicationIcon.isNull() || applicationIcon.actualSize(QSize(512, 512)) != QSize(512, 512) ||
            trayIcon.isNull() || trayIcon.actualSize(QSize(64, 64)) != QSize(64, 64) ||
            app.desktopFileName() != QStringLiteral("io.github.fxclip.Fxclip")) return 1;
        return 0;
    }
    const bool screenshotMode = app.arguments().contains(QStringLiteral("--screenshot")) ||
                                app.arguments().contains(QStringLiteral("--smoke-pages")) ||
                                app.arguments().contains(QStringLiteral("--page-shot")) ||
                                app.arguments().contains(QStringLiteral("--helper-shot"));
    MainWindow window(screenshotMode);
    window.show();
    return app.exec();
}
