#pragma once

#include "Core/Async.h"

#include <QPixmap>
#include <QPointer>
#include <QWidget>

#include <memory>
#include <optional>

namespace ct {

// 带圆角与异步加载的封面控件（对应 C# Controls/CoverImage）。
class CoverImage : public QWidget {
    Q_OBJECT

public:
    explicit CoverImage(QWidget* parent = nullptr);

    void setCoverURL(const std::optional<QString>& url, int decodeWidth = 0);
    void setCoverURL(const QString& url, int decodeWidth = 0)
    {
        setCoverURL(url.isEmpty() ? std::nullopt : std::make_optional(url), decodeWidth);
    }
    void clearCover();

    void setCornerRadius(double radius);
    double cornerRadius() const { return m_cornerRadius; }

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    void refresh();
    void applyImage(const QImage& image, int generation);

    // 协程参数会复制进协程帧，闭包捕获不会（lambda 协程的临时闭包在调用方
    // 返回后即销毁），因此这里必须用命名协程 + 显式参数，不能写成协程 lambda。
    static Task<void> loadCover(QPointer<CoverImage> self, QString url, int width, int generation,
        CancellationToken token);

    QString m_url;
    QPixmap m_pixmap;
    int m_decodeWidth = 0;
    double m_cornerRadius = 0;
    int m_generation = 0;
    std::shared_ptr<CancellationTokenSource> m_cts;
};

} // namespace ct
