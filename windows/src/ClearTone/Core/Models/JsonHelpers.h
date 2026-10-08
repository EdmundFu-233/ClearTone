#pragma once

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>

#include <optional>

namespace ct::json {

// 对应 C# JsonHelpers：容忍缺失 / null / 类型不符，全部返回 optional。
inline QJsonValue prop(const QJsonValue& value, const QString& name)
{
    if (!value.isObject()) return QJsonValue(QJsonValue::Undefined);
    const QJsonObject object = value.toObject();
    const auto iterator = object.constFind(name);
    if (iterator == object.constEnd()) return QJsonValue(QJsonValue::Undefined);
    const QJsonValue result = *iterator;
    if (result.isNull() || result.isUndefined()) return QJsonValue(QJsonValue::Undefined);
    return result;
}

inline bool hasValue(const QJsonValue& value)
{
    return !value.isUndefined() && !value.isNull();
}

inline std::optional<QString> optionalString(const QJsonValue& value)
{
    if (value.isString()) return value.toString();
    return std::nullopt;
}

inline QString string(const QJsonValue& value, const QString& fallback = {})
{
    return optionalString(value).value_or(fallback);
}

inline std::optional<double> optionalDouble(const QJsonValue& value)
{
    if (value.isDouble()) return value.toDouble();
    if (value.isString()) {
        bool ok = false;
        const double parsed = value.toString().toDouble(&ok);
        if (ok) return parsed;
    }
    return std::nullopt;
}

inline std::optional<int> optionalInt(const QJsonValue& value)
{
    const auto number = optionalDouble(value);
    if (!number) return std::nullopt;
    if (*number > 2147483647.0 || *number < -2147483648.0) return std::nullopt;
    return static_cast<int>(qRound(*number));
}

inline std::optional<qint64> optionalLong(const QJsonValue& value)
{
    if (value.isDouble()) {
        const double number = value.toDouble();
        if (number >= -9223372036854775808.0 && number <= 9223372036854775807.0
            && std::floor(number) == number) {
            return static_cast<qint64>(number);
        }
        return static_cast<qint64>(number);
    }
    const auto number = optionalDouble(value);
    if (!number) return std::nullopt;
    return static_cast<qint64>(*number);
}

inline std::optional<bool> optionalBool(const QJsonValue& value)
{
    if (value.isBool()) return value.toBool();
    if (value.isDouble()) return value.toDouble() != 0;
    if (value.isString()) {
        const QString text = value.toString();
        if (text == QLatin1String("true") || text == QLatin1String("1")) return true;
        if (text == QLatin1String("false") || text == QLatin1String("0")) return false;
    }
    return std::nullopt;
}

inline QJsonArray array(const QJsonValue& value)
{
    if (value.isArray()) return value.toArray();
    return {};
}

inline std::optional<QString> optionalIDString(const QJsonValue& value)
{
    if (value.isString()) return value.toString();
    if (value.isDouble()) {
        const double number = value.toDouble();
        if (std::floor(number) == number && qAbs(number) < 9007199254740992.0) {
            return QString::number(static_cast<qint64>(number));
        }
        return QString::number(number, 'g', 17);
    }
    return std::nullopt;
}

template <typename T, typename Mapper>
QList<T> compactMap(const QJsonArray& values, Mapper mapper)
{
    QList<T> result;
    result.reserve(values.size());
    for (const QJsonValue& value : values) {
        auto mapped = mapper(value);
        if (mapped) result.append(std::move(*mapped));
    }
    return result;
}

inline QJsonValue fromOptionalString(const std::optional<QString>& value)
{
    return value ? QJsonValue(*value) : QJsonValue(QJsonValue::Null);
}

inline QJsonValue fromOptionalInt(const std::optional<int>& value)
{
    return value ? QJsonValue(*value) : QJsonValue(QJsonValue::Null);
}

inline QJsonValue fromOptionalLong(const std::optional<qint64>& value)
{
    return value ? QJsonValue(static_cast<double>(*value)) : QJsonValue(QJsonValue::Null);
}

inline QJsonValue fromOptionalBool(const std::optional<bool>& value)
{
    return value ? QJsonValue(*value) : QJsonValue(QJsonValue::Null);
}

inline QJsonValue fromOptionalDouble(const std::optional<double>& value)
{
    return value ? QJsonValue(*value) : QJsonValue(QJsonValue::Null);
}

// System.Text.Json 的 ISO 8601（含最多 7 位小数）；Qt 只吸收到毫秒，多余的截断。
inline std::optional<QDateTime> parseDateTime(const QJsonValue& value)
{
    if (value.isDouble()) return QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(value.toDouble()));
    if (!value.isString()) return std::nullopt;
    QString raw = value.toString();
    const qsizetype dot = raw.indexOf(QLatin1Char('.'));
    if (dot >= 0) {
        qsizetype end = dot + 1;
        while (end < raw.size() && raw[end].isDigit()) ++end;
        const qsizetype digits = end - dot - 1;
        if (digits > 3) raw.remove(dot + 4, digits - 3);
    }
    QDateTime parsed = QDateTime::fromString(raw, Qt::ISODateWithMs);
    if (!parsed.isValid()) parsed = QDateTime::fromString(raw, Qt::ISODate);
    if (!parsed.isValid()) return std::nullopt;
    return parsed;
}

inline QString dateTimeToJson(const QDateTime& value)
{
    return value.toString(Qt::ISODateWithMs);
}

} // namespace ct::json
