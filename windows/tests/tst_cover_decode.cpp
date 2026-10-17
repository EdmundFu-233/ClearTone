#include <QtTest>

#include "Core/Async.h"
#include "DesignSystem/CoverImageLoader.h"

#include <QDir>
#include <QImage>
#include <QTemporaryDir>
#include <QUrl>

using namespace ct;

class CoverDecodeTests : public QObject {
    Q_OBJECT

private slots:
    void playlistCoverIsDecodedAtDisplaySize();
    void neteaseCoverUrlRequestsCompressedSize();
};

void CoverDecodeTests::playlistCoverIsDecodedAtDisplaySize()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString file = QDir(dir.path()).filePath(QStringLiteral("large-cover.png"));
    QImage source(1200, 800, QImage::Format_RGB32);
    source.fill(Qt::red);
    QVERIFY(source.save(file));

    CoverImageLoader loader;
    const QString url = QUrl::fromLocalFile(file).toString();
    auto small = syncWait(loader.load(url, 72));
    QVERIFY(small.has_value());
    QCOMPARE(small->width(), 72);
    QCOMPARE(small->height(), 48);
    auto large = syncWait(loader.load(url, 144));
    QVERIFY(large.has_value());
    QCOMPARE(large->width(), 144);
    QCOMPARE(large->height(), 96);
}

void CoverDecodeTests::neteaseCoverUrlRequestsCompressedSize()
{
    const QString raw = QStringLiteral("http://p3.music.126.net/abc/10995116.jpg");
    const QString sized = CoverImageLoader::sizedUrl(raw, 64);
    QVERIFY(sized.startsWith(QStringLiteral("https://p3.music.126.net/abc/10995116.jpg")));
    QVERIFY(sized.contains(QStringLiteral("param=64y64")));
}

QTEST_GUILESS_MAIN(CoverDecodeTests)
#include "tst_cover_decode.moc"
