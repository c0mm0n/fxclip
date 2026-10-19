#pragma once

#include <QRegularExpression>
#include <QString>

inline QString focusedAppFromCheckOutput(const QString &output) {
    constexpr auto prefix = "Focused app: ";
    QString result;
    bool found = false;
    for (const auto &line : output.split(QLatin1Char('\n'))) {
        if (!line.startsWith(QLatin1String(prefix))) continue;
        if (found) return {};
        found = true;
        result = line.mid(static_cast<int>(sizeof("Focused app: ") - 1)).trimmed();
    }
    if (!found || result.isEmpty() || result.startsWith(QStringLiteral("unavailable"), Qt::CaseInsensitive)) return {};
    static const QRegularExpression noWhitespace(QStringLiteral("^\\S+$"));
    return noWhitespace.match(result).hasMatch() ? result : QString();
}
