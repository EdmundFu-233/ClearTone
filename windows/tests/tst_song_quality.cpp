#include <QtTest>

#include "Core/Models/MusicModels.h"
#include "Core/Persistence/AppSettings.h"
#include "Playback/PlayerController.h"
#include "Playback/SongQuality.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

#include <cmath>

using namespace ct;

namespace {

QualityLevel effective(const std::optional<QualityLevel>& overridden, QualityLevel global)
{
    return songQualityPolicy::effectiveLevel(overridden, global);
}

int overrideCountFor(PlayerController& player, const QString& songID)
{
    int count = 0;
    for (const SongQualityOverride& entry : player.songQualityOverrides()) {
        if (entry.songID == songID) count += 1;
    }
    return count;
}

bool hasOverride(PlayerController& player, const QString& songID)
{
    return overrideCountFor(player, songID) > 0;
}

AppSettings decodeSettings(const QString& json)
{
    const QJsonDocument document = QJsonDocument::fromJson(json.toUtf8());
    return AppSettings::fromJson(document.object());
}

} // namespace

class SongQualityTests : public QObject {
    Q_OBJECT

private slots:
    void testOverrideWinsOverGlobal();
    void testCacheIsUsedOnlyWithoutOverride();
    void testNoCacheWriteWhenOverridden();
    void testSelectableLevelsExcludeUnknownPlaceholder();
    void testDefaultLevelDependsOnVIP();
    void testAutoResolvesByVIPButExplicitChoiceIsUntouched();
    void testAutoSentinelIsTheUnknownPlaceholder();
    void testGlobalLevelFollowsVIPChangeBackAndForth();
    void testDerivedBitrateFromSizeAndDuration();
    void testDerivedBitrateReturnsNilWhenDataInsufficient();
    void testOverrideLifecycleOnController();
    void testGlobalChangeDoesNotOverrideSongOverride();
    void testOverrideTableIsTrimmed();

    void testRateClampsToSaneRange();
    void testNormalRateHasNoBadge();
    void testRateLabelFormatting();
    void testQuarterRatesAreNotRoundedAway();
    void testAvailableRatesAreOrderedAndCentred();
    void testRestoredPlaybackRateSnapsToAvailableRate();
    void testSleepTimerSetsAndCancels();
    void testNonPositiveSleepTimerCancels();
    void testSleepTimerReplacesPrevious();
    void testSpectrumModeDoesNotOfferRealSpectrum();
    void testSpectrumDefaultIsAmbient();
    void testLegacySpectrumValueDoesNotBreakSettingsDecoding();
    void testUnrecognizedFieldDoesNotResetTheRest();
    void testEmptyObjectDecodesToDefaults();
    void testStoredQualityValueIsNotOverwrittenByNewDefault();
    void testSettingsRoundTripKeepsMenuBarFlag();
    void testCloseBehaviorDefaultKeepsPlaying();
    void testEveryCloseBehaviorHasHelp();
    void testSleepRemainingLabel();
    void testMenuBarAlwaysVisibleWinsOverEveryCloseBehavior();
    void testMinimizeToMenuBarShowsIconOnlyWithoutWindow();
    void testNoIconForKeepPlayingOrQuit();
};

void SongQualityTests::testOverrideWinsOverGlobal()
{
    QCOMPARE(effective(QualityLevel::Lossless, QualityLevel::ExHigh), QualityLevel::Lossless);
    QCOMPARE(effective(std::nullopt, QualityLevel::ExHigh), QualityLevel::ExHigh);
}

void SongQualityTests::testCacheIsUsedOnlyWithoutOverride()
{
    QVERIFY(songQualityPolicy::useLocalCache(false));
    QVERIFY(!songQualityPolicy::useLocalCache(true));
}

void SongQualityTests::testNoCacheWriteWhenOverridden()
{
    QVERIFY(!songQualityPolicy::shouldWriteCache(true, false));
    QVERIFY(!songQualityPolicy::shouldWriteCache(false, true));
    QVERIFY(songQualityPolicy::shouldWriteCache(false, false));
}

void SongQualityTests::testSelectableLevelsExcludeUnknownPlaceholder()
{
    QVERIFY(!songQualityPolicy::selectableLevels.contains(QualityLevel::Unknown));
    QCOMPARE(songQualityPolicy::selectableLevels.size(), 5);
    QVERIFY(songQualityPolicy::selectableLevels.contains(QualityLevel::Lossless));
    QVERIFY(songQualityPolicy::selectableLevels.contains(QualityLevel::HiRes));
}

void SongQualityTests::testDefaultLevelDependsOnVIP()
{
    QCOMPARE(songQualityPolicy::defaultLevel(true), QualityLevel::Lossless);
    QCOMPARE(songQualityPolicy::defaultLevel(false), QualityLevel::ExHigh);
}

void SongQualityTests::testAutoResolvesByVIPButExplicitChoiceIsUntouched()
{
    QCOMPARE(songQualityPolicy::effectiveGlobalLevel(QualityLevel::Unknown, true), QualityLevel::Lossless);
    QCOMPARE(songQualityPolicy::effectiveGlobalLevel(QualityLevel::Unknown, false), QualityLevel::ExHigh);
    for (const QualityLevel explicitLevel : songQualityPolicy::selectableLevels) {
        QCOMPARE(songQualityPolicy::effectiveGlobalLevel(explicitLevel, true), explicitLevel);
        QCOMPARE(songQualityPolicy::effectiveGlobalLevel(explicitLevel, false), explicitLevel);
    }
}

void SongQualityTests::testAutoSentinelIsTheUnknownPlaceholder()
{
    QCOMPARE(songQualityPolicy::autoLevel, QualityLevel::Unknown);
    QVERIFY(!songQualityPolicy::selectableLevels.contains(songQualityPolicy::autoLevel));
}

void SongQualityTests::testGlobalLevelFollowsVIPChangeBackAndForth()
{
    const QualityLevel preference = songQualityPolicy::autoLevel;
    QCOMPARE(songQualityPolicy::effectiveGlobalLevel(preference, true), QualityLevel::Lossless);
    QCOMPARE(songQualityPolicy::effectiveGlobalLevel(preference, false), QualityLevel::ExHigh);
}

void SongQualityTests::testDerivedBitrateFromSizeAndDuration()
{
    const auto kbps = songQualityPolicy::derivedBitrateKbps(3900000, 30);
    QVERIFY(kbps.has_value());
    QVERIFY(*kbps >= 1035 && *kbps <= 1045);
}

void SongQualityTests::testDerivedBitrateReturnsNilWhenDataInsufficient()
{
    QVERIFY(!songQualityPolicy::derivedBitrateKbps(std::nullopt, 30).has_value());
    QVERIFY(!songQualityPolicy::derivedBitrateKbps(0, 30).has_value());
    QVERIFY(!songQualityPolicy::derivedBitrateKbps(3900000, 0).has_value());
    QVERIFY(!songQualityPolicy::derivedBitrateKbps(3900000, 0.5).has_value());
}

void SongQualityTests::testOverrideLifecycleOnController()
{
    PlayerController& player = PlayerController::shared();
    const QString songID =
        QStringLiteral("test-quality-override-%1").arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
    const QualityLevel originalGlobal = player.preferredQuality();
    player.setQualityOverride(std::nullopt, songID);
    player.setRequestedQuality(QualityLevel::ExHigh);
    QVERIFY(!player.qualityOverrideFor(songID).has_value());
    QCOMPARE(player.effectiveQualityFor(songID), QualityLevel::ExHigh);

    player.setQualityOverride(QualityLevel::Lossless, songID);
    QVERIFY(player.qualityOverrideFor(songID).has_value());
    QCOMPARE(*player.qualityOverrideFor(songID), QualityLevel::Lossless);
    QCOMPARE(player.effectiveQualityFor(songID), QualityLevel::Lossless);
    QVERIFY(hasOverride(player, songID));

    player.setQualityOverride(QualityLevel::HiRes, songID);
    QVERIFY(player.qualityOverrideFor(songID).has_value());
    QCOMPARE(*player.qualityOverrideFor(songID), QualityLevel::HiRes);
    QCOMPARE(overrideCountFor(player, songID), 1);

    player.setQualityOverride(QualityLevel::Unknown, songID);
    QVERIFY(!player.qualityOverrideFor(songID).has_value());
    QCOMPARE(player.effectiveQualityFor(songID), QualityLevel::ExHigh);

    player.setQualityOverride(QualityLevel::Higher, songID);
    QVERIFY(player.qualityOverrideFor(songID).has_value());
    player.setQualityOverride(std::nullopt, songID);
    QVERIFY(!player.qualityOverrideFor(songID).has_value());
    QVERIFY(!hasOverride(player, songID));

    player.setQualityOverride(std::nullopt, songID);
    player.setRequestedQuality(originalGlobal);
}

void SongQualityTests::testGlobalChangeDoesNotOverrideSongOverride()
{
    PlayerController& player = PlayerController::shared();
    const QString songID =
        QStringLiteral("test-quality-global-%1").arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
    const QualityLevel originalGlobal = player.preferredQuality();
    player.setQualityOverride(QualityLevel::Lossless, songID);
    player.setRequestedQuality(QualityLevel::Standard);
    QCOMPARE(player.effectiveQualityFor(songID), QualityLevel::Lossless);
    QCOMPARE(player.effectiveQualityFor(QStringLiteral("some-other-song")), QualityLevel::Standard);

    player.setQualityOverride(std::nullopt, songID);
    player.setRequestedQuality(originalGlobal);
}

void SongQualityTests::testOverrideTableIsTrimmed()
{
    PlayerController& player = PlayerController::shared();
    QStringList ids;
    for (int index = 0; index < 260; ++index) {
        ids.append(QStringLiteral("trim-%1-%2")
                       .arg(index)
                       .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    }
    for (const QString& id : ids) player.setQualityOverride(QualityLevel::Lossless, id);
    QVERIFY(player.songQualityOverrides().size() <= 200);
    QVERIFY(player.qualityOverrideFor(ids[259]).has_value());
    QVERIFY(!player.qualityOverrideFor(ids[0]).has_value());

    for (const QString& id : ids) player.setQualityOverride(std::nullopt, id);
}

void SongQualityTests::testRateClampsToSaneRange()
{
    PlayerController& player = PlayerController::shared();
    const float original = player.playbackRate();
    player.setPlaybackRate(1.5f);
    QVERIFY(std::abs(player.playbackRate() - 1.5f) < 1e-3);

    player.setPlaybackRate(99.0f);
    QVERIFY(std::abs(player.playbackRate() - 3.0f) < 1e-3);
    player.setPlaybackRate(0.0f);
    QVERIFY(std::abs(player.playbackRate() - 0.25f) < 1e-3);
    player.setPlaybackRate(-5.0f);
    QVERIFY(std::abs(player.playbackRate() - 0.25f) < 1e-3);
    player.setPlaybackRate(original);
}

void SongQualityTests::testNormalRateHasNoBadge()
{
    PlayerController& player = PlayerController::shared();
    const float original = player.playbackRate();
    player.setPlaybackRate(1.0f);
    QVERIFY(!player.isRateAdjusted());
    QVERIFY(player.playbackRateLabel().isEmpty());

    player.setPlaybackRate(1.5f);
    QVERIFY(player.isRateAdjusted());
    QVERIFY(!player.playbackRateLabel().isEmpty());
    QVERIFY(player.playbackRateLabel().contains(QStringLiteral("1.5")));
    player.setPlaybackRate(original);
}

void SongQualityTests::testRateLabelFormatting()
{
    QCOMPARE(PlayerController::rateLabel(2.0f), QStringLiteral("2×"));
    QCOMPARE(PlayerController::rateLabel(0.5f), QStringLiteral("0.5×"));
}

void SongQualityTests::testQuarterRatesAreNotRoundedAway()
{
    const QHash<float, QString> expected = {
        {0.5f, QStringLiteral("0.5×")},
        {0.75f, QStringLiteral("0.75×")},
        {1.0f, QStringLiteral("1×")},
        {1.25f, QStringLiteral("1.25×")},
        {1.5f, QStringLiteral("1.5×")},
        {1.75f, QStringLiteral("1.75×")},
        {2.0f, QStringLiteral("2×")},
    };
    const QList<float>& rates = PlayerController::availableRates();
    QCOMPARE(rates.size(), expected.size());
    for (const float rate : rates) {
        QVERIFY(expected.contains(rate));
        QCOMPARE(PlayerController::rateLabel(rate), expected.value(rate));
    }
}

void SongQualityTests::testAvailableRatesAreOrderedAndCentred()
{
    const QList<float>& rates = PlayerController::availableRates();
    QVERIFY(std::is_sorted(rates.begin(), rates.end()));
    QVERIFY(rates.contains(1.0f));
    QVERIFY(rates.first() >= 0.25f);
    QVERIFY(rates.last() <= 3.0f);
}

void SongQualityTests::testRestoredPlaybackRateSnapsToAvailableRate()
{
    for (const float rate : PlayerController::availableRates()) {
        QCOMPARE(PlayerController::resolveRestoredPlaybackRate(rate), rate);
    }
    QCOMPARE(PlayerController::resolveRestoredPlaybackRate(99.0f), 2.0f);
    QCOMPARE(PlayerController::resolveRestoredPlaybackRate(0.0f), 0.5f);
    QCOMPARE(PlayerController::resolveRestoredPlaybackRate(-5.0f), 0.5f);
    QCOMPARE(PlayerController::resolveRestoredPlaybackRate(1.1f), 1.0f);
    QCOMPARE(PlayerController::resolveRestoredPlaybackRate(1.9f), 2.0f);
}

void SongQualityTests::testSleepTimerSetsAndCancels()
{
    PlayerController& player = PlayerController::shared();
    player.cancelSleepTimer();
    QVERIFY(!player.sleepTimerEndDate().has_value());

    player.setSleepTimer(15);
    QVERIFY(player.sleepTimerEndDate().has_value());
    QVERIFY(player.sleepTimerRemaining() >= 899.0 && player.sleepTimerRemaining() <= 901.0);
    QVERIFY(*player.sleepTimerEndDate() > QDateTime::currentDateTime());

    player.cancelSleepTimer();
    QVERIFY(!player.sleepTimerEndDate().has_value());
    QVERIFY(std::abs(player.sleepTimerRemaining()) < 1e-3);
}

void SongQualityTests::testNonPositiveSleepTimerCancels()
{
    PlayerController& player = PlayerController::shared();
    player.setSleepTimer(30);
    player.setSleepTimer(0);
    QVERIFY(!player.sleepTimerEndDate().has_value());

    player.setSleepTimer(30);
    player.setSleepTimer(-5);
    QVERIFY(!player.sleepTimerEndDate().has_value());
}

void SongQualityTests::testSleepTimerReplacesPrevious()
{
    PlayerController& player = PlayerController::shared();
    player.setSleepTimer(60);
    const auto first = player.sleepTimerEndDate();
    QVERIFY(first.has_value());
    player.setSleepTimer(10);
    const auto second = player.sleepTimerEndDate();
    QVERIFY(second.has_value());
    QVERIFY(*second < *first);
    player.cancelSleepTimer();
}

void SongQualityTests::testSpectrumModeDoesNotOfferRealSpectrum()
{
    QCOMPARE(static_cast<int>(SpectrumMode::Ambient), 0);
    QCOMPARE(static_cast<int>(SpectrumMode::Off), 1);
    const QString ambient = spectrumMode::displayName(SpectrumMode::Ambient);
    const QString off = spectrumMode::displayName(SpectrumMode::Off);
    QVERIFY(!ambient.isEmpty());
    QVERIFY(!off.isEmpty());
    QVERIFY(ambient != off);
    QVERIFY(!ambient.contains(QStringLiteral("真实")));
}

void SongQualityTests::testSpectrumDefaultIsAmbient()
{
    QCOMPARE(AppSettings().spectrumMode, SpectrumMode::Ambient);
}

void SongQualityTests::testLegacySpectrumValueDoesNotBreakSettingsDecoding()
{
    const QString legacy = QStringLiteral(
        "{\"themeMode\":\"dark\",\"spectrumMode\":\"真实频谱\",\"lyricOffset\":1.5,"
        "\"preferredQuality\":\"无损\",\"audioCacheEnabled\":false}");
    const AppSettings decoded = decodeSettings(legacy);
    QCOMPARE(decoded.spectrumMode, SpectrumMode::Ambient);
    QCOMPARE(decoded.themeMode, CTThemeMode::Dark);
    QCOMPARE(decoded.preferredQuality, QualityLevel::Lossless);
    QVERIFY(!decoded.audioCacheEnabled);
    QVERIFY(std::abs(decoded.lyricOffset - 1.5) < 1e-4);
}

void SongQualityTests::testUnrecognizedFieldDoesNotResetTheRest()
{
    const QString broken = QStringLiteral(
        "{\"themeMode\":\"chartreuse\",\"closeBehavior\":\"fly-to-the-moon\","
        "\"performanceMode\":\"turbo\",\"spectrumMode\":42,\"lyricOffset\":\"soon\","
        "\"preferredQuality\":\"无损\",\"audioCacheEnabled\":false,\"miniPlayerAlwaysOnTop\":false}");
    const AppSettings decoded = decodeSettings(broken);
    QCOMPARE(decoded.themeMode, CTThemeMode::System);
    QCOMPARE(decoded.closeBehavior, CloseBehavior::KeepPlaying);
    QCOMPARE(decoded.performanceMode, PerformanceMode::Auto);
    QCOMPARE(decoded.spectrumMode, SpectrumMode::Ambient);
    QVERIFY(std::abs(decoded.lyricOffset) < 1e-4);
    QCOMPARE(decoded.preferredQuality, QualityLevel::Lossless);
    QVERIFY(!decoded.audioCacheEnabled);
    QVERIFY(!decoded.miniPlayerAlwaysOnTop);
}

void SongQualityTests::testEmptyObjectDecodesToDefaults()
{
    const AppSettings decoded = decodeSettings(QStringLiteral("{}"));
    QCOMPARE(decoded.closeBehavior, CloseBehavior::KeepPlaying);
    QVERIFY(!decoded.menuBarAlwaysVisible);
    QVERIFY(decoded.miniPlayerAlwaysOnTop);
    QVERIFY(decoded.audioCacheEnabled);
    QCOMPARE(decoded.preferredQuality, songQualityPolicy::autoLevel);
}

void SongQualityTests::testStoredQualityValueIsNotOverwrittenByNewDefault()
{
    const AppSettings decoded = decodeSettings(QStringLiteral("{\"preferredQuality\":\"极高\"}"));
    QCOMPARE(decoded.preferredQuality, QualityLevel::ExHigh);
}

void SongQualityTests::testSettingsRoundTripKeepsMenuBarFlag()
{
    AppSettings settings;
    settings.menuBarAlwaysVisible = true;
    settings.closeBehavior = CloseBehavior::MinimizeToMenuBar;
    settings.miniPlayerAlwaysOnTop = false;
    const AppSettings decoded = AppSettings::fromJson(settings.toJson());
    QVERIFY(decoded.menuBarAlwaysVisible);
    QCOMPARE(decoded.closeBehavior, CloseBehavior::MinimizeToMenuBar);
    QVERIFY(!decoded.miniPlayerAlwaysOnTop);
}

void SongQualityTests::testCloseBehaviorDefaultKeepsPlaying()
{
    QCOMPARE(AppSettings().closeBehavior, CloseBehavior::KeepPlaying);
    QVERIFY(!AppSettings().menuBarAlwaysVisible);
}

void SongQualityTests::testEveryCloseBehaviorHasHelp()
{
    const QList<CloseBehavior> behaviors = {
        CloseBehavior::KeepPlaying, CloseBehavior::MinimizeToMenuBar, CloseBehavior::Quit};
    QCOMPARE(behaviors.size(), 3);
    for (const CloseBehavior behavior : behaviors) {
        QVERIFY(!closeBehavior::help(behavior).isEmpty());
        QVERIFY(!closeBehavior::displayName(behavior).isEmpty());
    }
}

void SongQualityTests::testSleepRemainingLabel()
{
    QSKIP("Windows source has no PlaybackUtilitiesMenu.remainingLabel equivalent");
}

void SongQualityTests::testMenuBarAlwaysVisibleWinsOverEveryCloseBehavior()
{
    QSKIP("Windows source has no MenuBarVisibilityPolicy equivalent");
}

void SongQualityTests::testMinimizeToMenuBarShowsIconOnlyWithoutWindow()
{
    QSKIP("Windows source has no MenuBarVisibilityPolicy equivalent");
}

void SongQualityTests::testNoIconForKeepPlayingOrQuit()
{
    QSKIP("Windows source has no MenuBarVisibilityPolicy equivalent");
}

QTEST_MAIN(SongQualityTests)
#include "tst_song_quality.moc"
