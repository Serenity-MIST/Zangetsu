// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get cancel => 'キャンセル';

  @override
  String get ok => 'わかりました';

  @override
  String get save => '保存';

  @override
  String get close => '閉じる';

  @override
  String get retry => '再試行';

  @override
  String get search => '検索';

  @override
  String get off => 'オフ';

  @override
  String get on => 'オン';

  @override
  String get done => '完了';

  @override
  String get next => '次へ';

  @override
  String get back => '戻る';

  @override
  String get edit => '編集';

  @override
  String get delete => '削除';

  @override
  String get share => '共有';

  @override
  String get copy => 'コピー';

  @override
  String get play => '再生';

  @override
  String get pause => '一時停止';

  @override
  String get yes => 'はい';

  @override
  String get no => 'いいえ';

  @override
  String get all => 'すべて';

  @override
  String get none => 'なし';

  @override
  String get auto => 'オート';

  @override
  String get add => '追加';

  @override
  String get remove => '解除';

  @override
  String get install => 'インストール';

  @override
  String get uninstall => 'アンインストール';

  @override
  String get reset => 'リセット';

  @override
  String get clear => 'クリア';

  @override
  String get resume => '再開';

  @override
  String get download => 'ダウンロード';

  @override
  String get update => '更新';

  @override
  String get apply => '適用';

  @override
  String get enable => '有効にする';

  @override
  String get create => '作成';

  @override
  String get rename => '名前を変更';

  @override
  String get move => '移動';

  @override
  String get join => '参加';

  @override
  String get leave => '退出';

  @override
  String get skip => 'スキップ';

  @override
  String get later => '後で';

  @override
  String get dismiss => '閉じる';

  @override
  String get dragDownToDismiss => 'Drag down to dismiss';

  @override
  String get releaseToDismiss => 'Release to dismiss';

  @override
  String get refresh => '更新';

  @override
  String get more => 'その他';

  @override
  String get info => '情報';

  @override
  String get filter => 'フィルター';

  @override
  String get connect => '接続';

  @override
  String get disconnect => '切断';

  @override
  String get signIn => 'サインイン';

  @override
  String get logOut => 'ログアウト';

  @override
  String get tryAgain => '再試行';

  @override
  String get showDetails => '詳細を表示';

  @override
  String get hideDetails => '詳細を隠す';

  @override
  String get notNow => '今はしない';

  @override
  String get change => '変更';

  @override
  String get go => '移動';

  @override
  String get read => '読む';

  @override
  String get web => 'ウェブ';

  @override
  String get live => 'ライブ';

  @override
  String get sub => 'サブ';

  @override
  String get dub => '吹き替え版';

  @override
  String get nsfw => 'NSFW';

  @override
  String get system => 'システム';

  @override
  String get custom => 'カスタム';

  @override
  String get customRange => 'Custom range';

  @override
  String get defaultLabel => 'デフォルト';

  @override
  String get selected => '選択中';

  @override
  String get loading => '読み込み中…';

  @override
  String get searching => '検索中';

  @override
  String get searchingEllipsis => '検索中…';

  @override
  String get downloading => 'ダウンロード中…';

  @override
  String get updating => '更新中…';

  @override
  String get testing => 'テスト中…';

  @override
  String get searchOk => 'Search OK';

  @override
  String get working => '正常';

  @override
  String get dead => '不通';

  @override
  String get error => 'エラー';

  @override
  String get appLanguage => 'アプリの言語';

  @override
  String get appLanguageSubtitle => 'インターフェース言語';

  @override
  String get appLanguageSystem => 'システム（自動）';

  @override
  String appLanguageSystemSubtitle(String name) {
    return 'システム（$name）';
  }

  @override
  String get appLanguageKeywords =>
      '言語 ロケール 翻訳 i18n インターフェース 日本語 中国語 スペイン語 ドイツ語 フランス語 イタリア語 language locale translation japanese chinese spanish german french italian';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsSearchHint => '設定を検索';

  @override
  String settingsNoMatch(String query) {
    return '「$query」に一致する設定はありません';
  }

  @override
  String get settingsSectionAccount => 'アカウントと同期';

  @override
  String get settingsSectionSources => '出典';

  @override
  String get settingsSectionPlayback => '再生';

  @override
  String get settingsSectionReading => '読書';

  @override
  String get settingsSectionHistory => '履歴';

  @override
  String get settingsSectionDownloads => 'ダウンロード';

  @override
  String get settingsSectionInterface => 'インターフェース';

  @override
  String get settingsSectionNotifications => '通知';

  @override
  String get settingsSectionAdvanced => '詳細設定';

  @override
  String get settingsSectionAbout => 'このアプリについて';

  @override
  String get settingsSectionAccountSummary => 'トラッカー、Discord、バックアップ、同期';

  @override
  String get settingsSectionSourcesSummary => 'プロバイダー、使用中のソース、更新';

  @override
  String get settingsSectionPlaybackSummary => '画質、自動再生、速度';

  @override
  String get settingsSectionReadingSummary => 'マンガ・小説リーダーの初期設定';

  @override
  String get settingsSectionHistorySummary => '視聴した作品';

  @override
  String get settingsSectionDownloadsSummary => 'ダウンロード、ストレージ、トレント';

  @override
  String get settingsSectionInterfaceSummary => '外観、言語、検索レイアウト';

  @override
  String get settingsSectionNotificationsSummary => '新エピソードの通知';

  @override
  String get settingsSectionAdvancedSummary => 'DNS、プライバシー、ログ';

  @override
  String get settingsSectionAboutSummary => '更新、サポート、バージョン';

  @override
  String get couldNotExportLogs => 'ログを書き出せませんでした';

  @override
  String get logsShareSubject => 'Zangetsu のログ';

  @override
  String get signInSubtitle => 'リスト・履歴・続きから再生を同期';

  @override
  String get signInSubtitleTv => 'リストと続きから再生を同期';

  @override
  String get connections => '連携';

  @override
  String get discord => '不和';

  @override
  String get discordSubtitle => 'Rich Presence — 視聴中の作品を表示';

  @override
  String get discordActivityStatus => 'Activity status';

  @override
  String get discordOnlineStatus => 'Discord status';

  @override
  String get presenceInvisible => 'Invisible';

  @override
  String get presenceOnline => 'Online';

  @override
  String get presenceIdle => 'Idle';

  @override
  String get presenceDnd => 'Do not disturb';

  @override
  String get presenceNameShows => 'Name shows';

  @override
  String get presenceDetailsShows => 'Details show';

  @override
  String get presenceStateShows => 'State shows';

  @override
  String get presenceSourceApp => 'App name';

  @override
  String get presenceSourceTitle => 'Title';

  @override
  String get presenceSourceEpisode => 'Episode';

  @override
  String get presenceLargeImage => 'Large image';

  @override
  String get presenceSmallImage => 'Small image';

  @override
  String get presenceImagePoster => 'Poster';

  @override
  String get presenceImageLogo => 'App logo';

  @override
  String get presenceImageOff => 'Off';

  @override
  String get presenceShowButton => 'Open button';

  @override
  String get presenceButtonLabel => 'Button label';

  @override
  String get presenceButtonLabelHint => 'Open in Zangetsu';

  @override
  String get presenceShowWhenPaused => 'Show when paused';

  @override
  String get presenceBrowsingTitle => 'Show browsing title';

  @override
  String get presencePreview => 'Preview';

  @override
  String get watchParty => '同時視聴';

  @override
  String get watchPartySubtitle => '友達と同時視聴ルームを作成・参加';

  @override
  String get signInToWatchTogether => 'サインインして一緒に視聴';

  @override
  String get syncLibraryToCloud => 'ライブラリをクラウドに同期';

  @override
  String get syncLibraryToCloudSubtitle => '履歴とリストをこのアカウントへ再アップロード';

  @override
  String get signInFirst => '先にサインインしてください';

  @override
  String get reconnectToSyncLibrary => '再接続してライブラリを同期してください。';

  @override
  String get syncingLibraryToCloud => 'ライブラリをクラウドに同期中…';

  @override
  String get backupAndRestore => 'バックアップと復元';

  @override
  String get backupAndRestoreSubtitle => 'ソース、リスト、設定を保存';

  @override
  String get providers => 'プロバイダー';

  @override
  String providersEnabledCount(int count) {
    return '$count件有効';
  }

  @override
  String get activeSource => '使用中のソース';

  @override
  String get streamingServices => 'Streaming Services';

  @override
  String get streamingServicesSubtitle =>
      'Browse what each service carries where you are';

  @override
  String get streamingServicesEmpty => 'No services listed for this country';

  @override
  String get streamingServicesMetadataNote =>
      'Browsing only — titles still play through your own sources';

  @override
  String get pinAsHomeRow => 'Pin as home row';

  @override
  String get unpinHomeRow => 'Unpin';

  @override
  String pinLimitReached(int count) {
    return 'You can pin up to $count services';
  }

  @override
  String get streamingRegion => 'Streaming region';

  @override
  String get streamingRegionSubtitle => 'Which country\'s catalogue to show';

  @override
  String get sourceHealth => 'ソースの状態';

  @override
  String get sourceHealthSubtitle => 'どのソースが使えるか確認';

  @override
  String get sourceUpdates => 'ソースの更新';

  @override
  String get sourceUpdatesSubtitle => 'インストール済みソースに更新があるとき通知';

  @override
  String get autoUpdateExtensions => '拡張機能を自動更新';

  @override
  String get autoUpdateExtensionsSubtitle => '起動時にインストール済みソースを自動更新';

  @override
  String get playback => '再生';

  @override
  String get playbackSubtitle => '画質、自動再生、速度';

  @override
  String get reader => 'リーダー';

  @override
  String get readerSubtitle => 'マンガ・小説の初期設定';

  @override
  String get history => '履歴';

  @override
  String get historySubtitle => '視聴した作品';

  @override
  String get downloads => 'ダウンロード';

  @override
  String get downloadsSubtitle => 'ダウンロードしたエピソードを管理';

  @override
  String get downloadsSubtitleTv => 'オフラインで視聴';

  @override
  String get storage => 'ストレージ';

  @override
  String get storageSubtitle => 'アプリの使用容量を管理';

  @override
  String get torrents => 'トレンド';

  @override
  String get torrentsSubtitle => 'ストリーミングとデータ設定';

  @override
  String get appearance => '外観';

  @override
  String get appearanceSubtitle => 'アクセントカラー、ポスターバッジ';

  @override
  String get searchLayout => '検索レイアウト';

  @override
  String get searchLayoutSubtitle => '複数ソースの結果の表示方法';

  @override
  String get searchLayoutBlurb =>
      '複数ソースの結果の表示方法です。縦＝ソースごとにグリッド、横＝ソースごとに横スクロール行。';

  @override
  String get searchLayoutVertical => '縦（グリッド）';

  @override
  String get searchLayoutHorizontal => '横（行）';

  @override
  String get batchDownloadStyle => '一括ダウンロードの見た目';

  @override
  String get batchDownloadStyleSubtitle => '複数エピソードシートの見た目';

  @override
  String get batchDownloadStyleBlurb =>
      'シーズン全体をダウンロードするときに出るシートです。内容は同じで、選び方だけが違います。';

  @override
  String get batchDownloadClassic => 'クラシック';

  @override
  String get batchDownloadClassicBlurb => 'エピソードごとのサムネイルグリッド付きのフルシート。';

  @override
  String get batchDownloadMinimal => 'ミニマル';

  @override
  String get batchDownloadMinimalBlurb => '数字ホイールで取得する話数を選びます。';

  @override
  String get notifications => '通知';

  @override
  String get notificationsSubtitle => '登録作品の新エピソード通知';

  @override
  String get dns => 'DNS';

  @override
  String get dnsSubtitle => 'CS ソースの ISP ブロックを回避';

  @override
  String get dnsBlurb =>
      'CloudStream ソース向けの暗号化 DNS。ISP のブロック回避に役立ちます。オフ＝通常の接続。';

  @override
  String get dnsOffTvSubtitle => 'オフ · CS ソースの ISP ブロックを回避';

  @override
  String get privacy => 'プライバシー';

  @override
  String get privacySubtitle => 'NSFW ソース';

  @override
  String get shareLogs => 'ログを共有';

  @override
  String get shareLogsSubtitle => '不具合調査用の診断ログを送信';

  @override
  String get sendingReport => 'Sending report…';

  @override
  String get reportSent => 'Report sent';

  @override
  String reportSentBody(String ref) {
    return 'Thanks. If you tell us what happened, quote this code: $ref';
  }

  @override
  String get about => 'このアプリについて';

  @override
  String versionLabel(String version) {
    return 'v$version';
  }

  @override
  String get contributors => '貢献者';

  @override
  String get website => 'ウェブサイト';

  @override
  String get communityChat => 'コミュニティチャット';

  @override
  String get joinTheServer => 'サーバーに参加';

  @override
  String get viewTheSourceCode => 'ソースコードを見る';

  @override
  String get howItWorks => '使い方';

  @override
  String get howItWorksSubtitle => '初めての方向けの短いガイド';

  @override
  String get checkForUpdates => '更新を確認';

  @override
  String get checkForUpdatesSubtitle => 'GitHub から最新版を入手';

  @override
  String get checkingForUpdates => '更新を確認中…';

  @override
  String get betaUpdates => 'ベータ更新';

  @override
  String get betaUpdatesSubtitle => '先行ビルドを早めに入手 — 不安定な場合があります';

  @override
  String get supportTheApp => 'アプリを支援';

  @override
  String get buyMeACoffee => 'コーヒーをおごる';

  @override
  String get leadDeveloper => 'リード開発者';

  @override
  String get addCloudStreamRepository => 'CloudStream リポジトリを追加';

  @override
  String get installCloudStreamSources => 'CloudStream ソースをインストール';

  @override
  String get connectionsTvSubtitle => 'AniList、MyAnimeList、Simkl';

  @override
  String get profile => 'プロフィール';

  @override
  String get profileLock => 'Profile lock';

  @override
  String get profileLockSubtitle => 'Ask for a PIN before opening this profile';

  @override
  String get unlockProfile => 'Unlock profile';

  @override
  String enterProfilePin(Object name) {
    return 'Enter the PIN for $name';
  }

  @override
  String get wrongPin => 'Wrong PIN, try again';

  @override
  String get setProfilePin => 'Set profile PIN';

  @override
  String get confirmProfilePin => 'Confirm PIN';

  @override
  String get pinMismatch => 'PINs do not match';

  @override
  String get pinTooShort => 'Use at least 4 characters';

  @override
  String get changeProfilePin => 'Change PIN';

  @override
  String get removeProfileLock => 'Remove lock';

  @override
  String get useFingerprint => 'Use fingerprint';

  @override
  String get changeProfile => 'プロフィールを切り替えますか？';

  @override
  String get chooseWhoIsWatching => '視聴者を選択してください。';

  @override
  String get home => 'ホーム';

  @override
  String get myList => 'マイリスト';

  @override
  String get schedule => 'スケジュール';

  @override
  String get pressBackAgainToExit => 'もう一度 BACK で終了';

  @override
  String get pressBackAgainToExitTv => 'もう一度戻るで終了';

  @override
  String get selectSource => 'ソースを選択';

  @override
  String get accentWallpaper => '壁紙';

  @override
  String get accentCoral => 'コーラル';

  @override
  String get accentBlue => 'ブルー';

  @override
  String get accentViolet => 'バイオレット';

  @override
  String get accentEmerald => 'エメラルド';

  @override
  String get accentAmber => 'アンバー';

  @override
  String get accentRose => '薔薇';

  @override
  String get accentCyan => 'シアン';

  @override
  String get accentCrimson => 'クリムゾン';

  @override
  String get shaderOff => 'オフ';

  @override
  String get shaderOffDesc => '補正なし';

  @override
  String get shaderSharpen => 'シャープ';

  @override
  String get shaderSharpenDesc => '細部を復元 — きれいなソース向き';

  @override
  String get shaderDeblur => 'デブラー';

  @override
  String get shaderDeblurDesc => 'やさしく復元 — ぼやけたソース向き';

  @override
  String get shaderDenoise => 'ノイズ除去';

  @override
  String get shaderDenoiseDesc => '粒子を軽減 — 圧縮ソース向き';

  @override
  String get shaderTierHigh => 'ハイエンド GPU';

  @override
  String get shaderTierHighDesc => '重い VL アップスケーラー＋HQ 拡大 — 高性能 GPU 向け';

  @override
  String get shaderTierMid => 'ミッドレンジ GPU';

  @override
  String get shaderTierMidDesc => '軽いアップスケーラー＋デバンド — 多くの端末で滑らか';

  @override
  String get playerInfoResolution => '解像度';

  @override
  String get playerInfoSource => 'ソース';

  @override
  String get playerInfoQuality => '画質';

  @override
  String get playerInfoVideoCodec => '映像コーデック';

  @override
  String get playerInfoAudioCodec => '音声コーデック';

  @override
  String get playerInfoFrameRate => 'フレームレート';

  @override
  String get playerInfoVideoBitrate => '映像ビットレート';

  @override
  String get playerInfoBuffer => 'バッファ';

  @override
  String get playerInfoDroppedFrames => 'ドロップフレーム';

  @override
  String get playerInfoDecoder => 'デコーダ';

  @override
  String get playerInfoSpeed => '速度';

  @override
  String get playerInfoAudioTrack => '音声トラック';

  @override
  String get playerInfoSubtitleTrack => '字幕トラック';

  @override
  String get playerInfoAudioBoost => '音声ブースト';

  @override
  String get statusPlanToWatch => '視聴予定';

  @override
  String get statusWatching => '視聴中';

  @override
  String get statusCompleted => '完了';

  @override
  String get statusPaused => '一時中断';

  @override
  String get statusDropped => '視聴中止';

  @override
  String get statusPlanning => '予定';

  @override
  String get statusReading => '読書中';

  @override
  String get statusPlanToRead => '読書予定';

  @override
  String providerHavingAMoment(String name) {
    return '$name は少し休憩中です';
  }

  @override
  String get providerHavingAMomentBody =>
      '今は応答していません。少し待つか、設定でメタデータ提供元を切り替えてください。';

  @override
  String sourceNotAnswering(String name) {
    return '$name が応答しません';
  }

  @override
  String get sourceNotAnsweringBody =>
      'ダウンしているか、リクエストを拒否している可能性があります。再試行するか、上部でソースを切り替えてください。';

  @override
  String providerNeedsBreather(String name) {
    return '$name は一息つきたいようです';
  }

  @override
  String providerNeedsBreatherBody(int seconds) {
    return '少し送りすぎました。$seconds秒後に再試行してください。';
  }

  @override
  String get showingWhatWeHave =>
      'ダウンしているか、ネットワークが遮断しているかもしれません。取得済みの情報はこちらです。';

  @override
  String get titleLanguage => 'タイトルの言語';

  @override
  String get titleLanguageSubtitle => 'AniList のタイトルの表示方法';

  @override
  String get titleLanguageNative => '原語';

  @override
  String get homeRowsLayout => '編集中';

  @override
  String get homeRows => 'ホームをカスタマイズ';

  @override
  String get homeRowsSubtitle => 'ホームに表示する行を選択';

  @override
  String get homeRowsFromYourLists => 'リストから';

  @override
  String get homeRowsDiscover => '見つける';

  @override
  String get homeRowsHelp => 'ドラッグで並べ替え。オフにすると行が非表示になります。';

  @override
  String homeRowTrackerContinue(String tracker) {
    return '$trackerで続きを見る';
  }

  @override
  String get trackerCaughtUp => '最新話まで視聴済み';

  @override
  String get homeRowNewEpisodes => '新着エピソード';

  @override
  String get modeStreaming => 'ストリーミング';

  @override
  String get modeManga => 'マンガ';

  @override
  String get modeNovel => '小説';

  @override
  String get relativeToday => '今日';

  @override
  String get relativeYesterday => '昨日';

  @override
  String relativeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count日前',
      one: '$count日前',
    );
    return '$_temp0';
  }

  @override
  String relativeWeeksAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count週間前',
      one: '$count週間前',
    );
    return '$_temp0';
  }

  @override
  String relativeMonthsAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countか月前',
      one: '$countか月前',
    );
    return '$_temp0';
  }

  @override
  String relativeYearsAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count年前',
      one: '$count年前',
    );
    return '$_temp0';
  }

  @override
  String get bootErrorTitle => 'Zangetsu の起動が完了しませんでした';

  @override
  String get bootErrorBody =>
      'この端末に保存されたデータが原因で開けません。データは失われていません。アカウントとクラウド同期分はそのままです。';

  @override
  String get resetAppData => 'アプリデータをリセット';

  @override
  String get resetAppDataTitle => 'アプリデータをリセットしますか？';

  @override
  String get resetAppDataBody =>
      'Zangetsu がこの端末に保存したデータを消して、まっさらな状態で起動できるようにします。\n\nアカウントとクラウド同期分はそのままです。再サインインすればライブラリが戻ります。';

  @override
  String get resetAppDataDone => 'Zangetsu を完全に終了して、もう一度開いてください。';

  @override
  String get detailsCopied => '詳細をコピーしました — こちらへ送ってください';

  @override
  String get copyDetails => '詳細をコピー';

  @override
  String get goodToHaveYouHere => 'ようこそ。';

  @override
  String get onboardingIntro => 'アニメ、マンガ、小説をひとつのアプリで。好きなように設定できます。';

  @override
  String get youChooseWhatsInside => '中身は自分で選べます';

  @override
  String get addTheSourcesYouWant => '使いたいソースを追加 — 手順はこちら。';

  @override
  String get openProviders => 'プロバイダーを開く';

  @override
  String get pickStreamingMangaOrNovels => '配信、マンガ、小説から選ぶ';

  @override
  String get pasteInARepositoryLink => 'リポジトリのリンクを貼り付ける';

  @override
  String get browseAndGrab => '見て、良さそうなものを入れる';

  @override
  String get readyWhenYouAre => '準備ができたらどうぞ。';

  @override
  String get addSourcesNow => '今すぐソースを追加';

  @override
  String get illDoItLater => '後でする';

  @override
  String get howToUseTheApp => 'アプリの使い方';

  @override
  String get aFewTapsToAnything => '数タップで目的の操作へ。';

  @override
  String get findSomething => '作品を探す';

  @override
  String get watchIt => '視聴する';

  @override
  String get ifItWontLoad => '読み込めないとき';

  @override
  String get saveForOffline => 'オフライン用に保存';

  @override
  String get commonQuestions => 'よくある質問';

  @override
  String get noCommunityContributorsYet => 'コミュニティ貢献者はまだいません。';

  @override
  String get paged => 'ページ送り';

  @override
  String get vertical => '垂直';

  @override
  String get tapZonesReset => 'タップ領域をリセットしました';

  @override
  String get noUPIAppFoundUPIIDCopiedPasteItInYourUPIApp =>
      'UPI アプリが見つかりません — UPI ID をコピーしました。UPI アプリに貼り付けてください';

  @override
  String get donateWithPayPal => 'PayPal で寄付';

  @override
  String get payViaUPI => 'UPI で支払う';

  @override
  String get copyUPIID => 'UPI ID をコピー';

  @override
  String get readingMode => '読書モード';

  @override
  String get fit => 'フィット';

  @override
  String get background => '背景';

  @override
  String get colourFilter => 'カラーフィルター';

  @override
  String get orientationLock => '画面の向きを固定';

  @override
  String get openEpisodesIn => 'Open episodes in';

  @override
  String get openingLayoutWatchPage => 'Watch page';

  @override
  String get openingLayoutFullscreen => 'Fullscreen';

  @override
  String get watchServer => 'Server';

  @override
  String get watchUpNext => 'Up next';

  @override
  String watchAllEpisodes(int count) {
    return 'All episodes ($count)';
  }

  @override
  String get watchComments => 'Comments';

  @override
  String get watchEpisodes => 'Episodes';

  @override
  String get watchComingSoon => 'Coming soon';

  @override
  String get watchAutoplay => 'Auto-play';

  @override
  String get watchSeeMore => 'See more';

  @override
  String get watchSeeLess => 'See less';

  @override
  String get watchReverseOrder => 'Reverse order';

  @override
  String get doublePageLandscape => '見開き（横向き）';

  @override
  String get pairFacingPagesInALandscapeSpread => '横向きで左右のページを見開き表示';

  @override
  String get cropBorders => '余白をカット';

  @override
  String get trimNearUniformEdgeMarginsFromAPage => 'ページ端のほぼ均一な余白を切り落とす';

  @override
  String get preloadPages => 'ページを先読み';

  @override
  String get showPageNumber => 'Show page number';

  @override
  String get keepScreenOn => '画面を消灯しない';

  @override
  String get readerFullscreen => 'Fullscreen';

  @override
  String get tapZones => 'タップ領域';

  @override
  String get whatTappingEachPartOfThePageDoes => 'ページの各部分をタップしたときの動作';

  @override
  String get font => 'フォント';

  @override
  String get addFont => 'フォントを追加';

  @override
  String get couldntAddFont => 'そのフォントを追加できませんでした';

  @override
  String get theme => 'テーマ';

  @override
  String get fontSize => '文字サイズ';

  @override
  String get lineHeight => '行間';

  @override
  String get margin => '余白';

  @override
  String get justifyText => '両端揃え';

  @override
  String get textDirection => '文字の方向';

  @override
  String get paragraphSpacing => '段落の間隔';

  @override
  String get paginated => 'ページ形式';

  @override
  String get bookStylePagesInsteadOfAContinuousScroll =>
      '連続スクロールではなく本のようなページ送り';

  @override
  String get enableNSFWSources => 'NSFW ソースを有効にしますか？';

  @override
  String get showNSFWAniyomiSources => 'NSFW の Aniyomi ソースを表示しますか？';

  @override
  String get incognitoMode => 'シークレットモード';

  @override
  String get pauseHistoryTrackingDiscordPresence => '履歴、トラッキング、Discord の表示を停止';

  @override
  String get enableNSFWSources2 => 'NSFW ソースを有効にする';

  @override
  String get showSourcesMarked18 => '18+ のソースを表示';

  @override
  String get showNSFWSources => 'NSFW ソースを表示';

  @override
  String get adultAniyomiExtensions => '成人向け Aniyomi 拡張機能';

  @override
  String get opensubtitlesAPIKey => 'OpenSubtitles API キー';

  @override
  String get pasteYourKey => 'キーを貼り付け';

  @override
  String get createAFreeKeyAtOpensubtitlesComConsumers =>
      'opensubtitles.com → Consumers で無料キーを作成。';

  @override
  String get shaderDownloadFailedCheckNetwork => 'シェーダーのダウンロードに失敗 — ネットワークを確認';

  @override
  String get anime4kEnhancement => 'Anime4K 補正';

  @override
  String get anime4kGPUTier => 'Anime4K の GPU ティア';

  @override
  String get cacheCleared => 'キャッシュを削除しました';

  @override
  String get videoBufferSize => '映像バッファサイズ';

  @override
  String get videoBufferLength => '映像バッファ時間';

  @override
  String get playerInfoOverlay => 'プレーヤー情報オーバーレイ';

  @override
  String get defaultQuality => 'デフォルト画質';

  @override
  String get videoDecoder => '映像デコーダー';

  @override
  String get videoRenderer => '映像レンダラー';

  @override
  String get defaultAudio => 'デフォルト音声';

  @override
  String get defaultSpeed => 'デフォルト速度';

  @override
  String get doubleTapSkip => 'ダブルタップでスキップ';

  @override
  String get closeConfirmation => '終了の確認';

  @override
  String get megaskipDuration => 'MegaSkip の時間';

  @override
  String get defaultPlayer => 'デフォルトプレーヤー';

  @override
  String get defaultAudioAnimeSubDub => 'デフォルト音声（アニメ字幕／吹替）';

  @override
  String get builtIn => '内蔵';

  @override
  String get playerControls => 'プレーヤー操作';

  @override
  String get reorderOrHideTheButtonsOnThePlayerBar => 'プレーヤーバーのボタンを並び替え・非表示';

  @override
  String get resumePlayback => '続きから再生';

  @override
  String get continueFromWhereYouLeftOff => '中断した位置から再開';

  @override
  String get askBeforeJumping => 'ジャンプ前に確認';

  @override
  String get autoAddToMyList => 'マイリストへ自動追加';

  @override
  String get addATitleToMyListWhenYouStartWatchingIt => '視聴を始めるとマイリストに追加';

  @override
  String get autoTrack => '自動トラッキング';

  @override
  String get confirm => '確認';

  @override
  String get autoplayNextEpisode => '次の話を自動再生';

  @override
  String get autoSkipFillerEpisodes => 'フィラー話を自動スキップ';

  @override
  String get autoplayTrailer => '予告編を自動再生';

  @override
  String get playATitleSTrailerOnItsDetailPage => '詳細ページで作品の予告編を再生';

  @override
  String get playTrailersInHD => '予告編を HD で再生';

  @override
  String get skipIntroButton => 'イントロスキップボタン';

  @override
  String get showSkipOpeningEndingOnAnimeWhenDetected =>
      '検出時にオープニング／エンディングのスキップを表示';

  @override
  String get autoSkipOpening => 'OP を自動スキップ';

  @override
  String get jumpPastTheOPOnItsOwnNoTap => 'タップなしで OP を飛ばす';

  @override
  String get autoSkipRecap => '前回までのあらすじを自動スキップ';

  @override
  String get jumpPastThePreviouslyOnRecapNoTap => '「前回まで」のあらすじをタップなしで飛ばす';

  @override
  String get autoSkipEnding => 'ED を自動スキップ';

  @override
  String get jumpPastTheEDOnItsOwnNoTap => 'タップなしで ED を飛ばす';

  @override
  String get megaskipButton => 'MegaSkip ボタン';

  @override
  String get aJumpForwardButtonInThePlayerAnyVideo => 'プレーヤーの先送りボタン（どの動画でも）';

  @override
  String get seekButton => 'シークボタンを表示';

  @override
  String get seekButtonDescription => 'プレーヤーに早送り・早戻しボタンを表示します';

  @override
  String get seekButtonDuration => 'シーク時間';

  @override
  String get selectSeekButtonDurationDescription => 'シークボタンの移動時間を選択します';

  @override
  String get nativeTVPlayer => 'TV 標準プレーヤー';

  @override
  String get tvDecoderMode => 'TV decoder priority';

  @override
  String get tvDecoderHardwareOnly => 'Hardware only';

  @override
  String get tvDecoderHardwareFirst => 'Hardware first (software fallback)';

  @override
  String get tvDecoderSoftwareFirst => 'Software first (hardware fallback)';

  @override
  String get softwareAudioDolbyDTS => 'ソフトウェア音声（Dolby/DTS）';

  @override
  String get seekPreviewOnline => 'シークプレビュー（オンライン）';

  @override
  String get thumbnailsWhileScrubbingStreamsCostsExtraData =>
      'ストリーム操作中にサムネイル — 追加通信が発生';

  @override
  String get inAppMiniPlayer => 'In-app mini-player';

  @override
  String get inAppMiniPlayerSubtitle =>
      'Keep watching while browsing Zangetsu. Pinch to resize.';

  @override
  String get autoPictureInPicture => '自動ピクチャーインピクチャー';

  @override
  String get shrinkToAFloatingWindowWhenYouLeaveTheApp => 'アプリを離れると小窓に縮小';

  @override
  String get showQualityLabel => '画質ラベルを表示';

  @override
  String get plainQualityTextEG1080pOnTheTopBarRight =>
      '上部バー右に画質テキスト（例: 1080p）';

  @override
  String get gestureControls => 'ジェスチャー操作';

  @override
  String get swipeLeftForBrightnessRightForVolume => '左スワイプで明るさ、右で音量';

  @override
  String get swipeToSeek => 'スワイプでシーク';

  @override
  String get dragLeftOrRightAcrossTheVideoToScrub => '映像上を左右にドラッグしてシーク';

  @override
  String get holdFor2Speed => '長押しで 2× 速';

  @override
  String get longPressTheVideoToPlayAt2WhileHeld => '映像を長押ししている間 2× で再生';

  @override
  String get clearImageVideoCache => '画像・映像キャッシュを削除';

  @override
  String get styledSubtitlesLibass => '装飾字幕（libass）';

  @override
  String get subtitleStyle => '字幕スタイル';

  @override
  String get requiredForOnlineSubtitleSearch => 'オンライン字幕検索に必要';

  @override
  String get subtitleLanguage => '字幕の言語';

  @override
  String get autoDownloadSubtitles => '字幕を自動ダウンロード';

  @override
  String get whenTheSourceHasNoSubtitleInYourLanguage => 'ソースに希望言語の字幕がないとき';

  @override
  String get autoTranslateSubtitles => '字幕を自動翻訳';

  @override
  String get translateToYourLanguageOnPlayWhenTheSourceHasNone =>
      'ソースに字幕がないとき、再生時に翻訳';

  @override
  String get translateSubtitlesTo => '字幕の翻訳先';

  @override
  String get pickALanguage => '言語を選ぶ';

  @override
  String get customColour => 'カスタムカラー';

  @override
  String get materialYou => '素材';

  @override
  String get coloursFromYourWallpaper => '壁紙から色を取得';

  @override
  String get pureBlackBackground => '純黒の背景';

  @override
  String get trueBlackForOLED => 'OLED 向けの真の黒';

  @override
  String get posterBadges => 'ポスターバッジ';

  @override
  String get qualityAndSubDubBadges => '画質と字幕／吹替のバッジ';

  @override
  String get animateLists => 'リストをアニメーション';

  @override
  String get cardsFadeInAsYouScroll => 'スクロールに合わせてカードがフェードイン';

  @override
  String get animationStyle => 'アニメーションのスタイル';

  @override
  String get turnOffMaterialYouToPickAColourYourself =>
      '自分で色を選ぶには Material You をオフ';

  @override
  String get downloadsZangetsu => 'ダウンロード › 斬月';

  @override
  String get removableDrive => 'リムーバブルドライブ';

  @override
  String get chooseFolder => 'フォルダーを選択…';

  @override
  String get resetToDefault => 'デフォルトに戻す';

  @override
  String get connected => '接続済み';

  @override
  String get imageCacheCleared => '画像キャッシュを削除しました';

  @override
  String get providerCacheCleared => 'プロバイダーキャッシュを削除しました';

  @override
  String get clearImageCache => '画像キャッシュを削除';

  @override
  String get clearProviderCache => 'プロバイダーキャッシュを削除';

  @override
  String get showTitleE2 => 'タイトルを表示 · E2';

  @override
  String get pinned => 'ピン留め';

  @override
  String get exoplayerSpikeDev => 'ExoPlayer スパイク（開発）';

  @override
  String get sp0TestSurfaceViewPlaybackSmoothness =>
      'SP0 — SurfaceView 再生の滑らかさをテスト';

  @override
  String get pasteDiscordToken => 'Discord トークンを貼り付け';

  @override
  String get yourDiscordUserToken => 'Discord のユーザートークン';

  @override
  String get pasteToken => 'トークンを貼り付け';

  @override
  String get useMobileDataForTorrents => 'トレントにモバイルデータ通信を使う';

  @override
  String get discordConnected => 'Discord に接続しました';

  @override
  String get disconnectDiscord => 'Discord を切断しますか？';

  @override
  String get notConfigured => '未設定';

  @override
  String get aDiscordApplicationIDMustBeSetInTheBuildFirst =>
      '先にビルドで Discord Application ID を設定する必要があります。';

  @override
  String get richPresence => '豊かな存在感';

  @override
  String get showWhatYouReWatchingOnYourProfile => 'プロフィールに視聴中の作品を表示';

  @override
  String get signInToLinkYourAccount => 'サインインしてアカウントを連携';

  @override
  String get autoSync => '自動同期';

  @override
  String
  get disconnectingHereOnlySignsThisTrackerOutOnTheTVYourPhoneStaysConnected =>
      'ここでの切断は TV 側のトラッカーのみ。スマホは接続したままです。';

  @override
  String get continueWatching => '続きから見る';

  @override
  String get continueReading => '続きから読む';

  @override
  String get seeAll => 'すべて見る';

  @override
  String get libraryLabel => 'ライブラリ';

  @override
  String get sortBy => '並び替え';

  @override
  String get newEpisodeBadges => 'New episode badges';

  @override
  String get comingSoonShort => 'Soon';

  @override
  String get newCategory => '新しいカテゴリ';

  @override
  String get personaGym => 'Persona、ジム、…';

  @override
  String get deleteCategory => 'カテゴリを削除';

  @override
  String get yourTitlesStayOnlyTheLabelGoes => '作品はそのまま — ラベルだけ削除されます';

  @override
  String get renameCategory => 'カテゴリ名を変更';

  @override
  String get manageTrackers => 'トラッカーを管理';

  @override
  String get trackers => 'トラッカー';

  @override
  String get showLabel => '作品';

  @override
  String get couldnTLoadPullToRefresh => '読み込めません — 引っ張って更新';

  @override
  String get noTitlesInThisList => 'このリストに作品はありません';

  @override
  String get signInToBuildYourList => 'サインインしてリストを作る';

  @override
  String get titlesYouAddAppearHere => '追加した作品がここに表示されます';

  @override
  String get couldnTLoadTryAgainFromSettings => '読み込めません — 設定から再試行';

  @override
  String get search2 => '検索…';

  @override
  String get voiceSearch => '音声検索';

  @override
  String get voiceSearchListening => 'Listening…';

  @override
  String get voiceSearchPreparing => 'Getting ready…';

  @override
  String get voiceSearchProcessing => 'Finding the words…';

  @override
  String get voiceSearchPermission =>
      'Allow microphone access to use voice search.';

  @override
  String get voiceSearchSpeechPermission =>
      'Allow speech recognition in Settings to use voice search.';

  @override
  String get voiceSearchTypingAvailable => 'You can still type your search.';

  @override
  String get voiceSearchServiceNotice =>
      'Voice recognition uses your device’s speech service.';

  @override
  String get voiceSearchFailed => 'Voice search failed. Please try again.';

  @override
  String get voiceSearchNoMatch =>
      'Couldn’t hear a title. Please try speaking again.';

  @override
  String get allSources => 'すべてのソース';

  @override
  String get currentSource => '現在のソース';

  @override
  String get searchFailedTryAgain => '検索に失敗 — 再試行してください';

  @override
  String get searchForSomethingToWatch => '視聴する作品を検索';

  @override
  String get recentSearches => '最近の検索';

  @override
  String get clearSearchHistory => '検索履歴を消去';

  @override
  String get checkTheSpellingOrTryADifferentTitle =>
      'スペルを確認するか、別のタイトルを試してください。';

  @override
  String get browseSources => 'ソースを見る';

  @override
  String get thisSourceHasNoFilters => 'このソースにフィルターはありません';

  @override
  String get searchIn => '検索対象';

  @override
  String get filters => 'フィルター';

  @override
  String get sourceFilters => 'ソースのフィルター';

  @override
  String get clearFilters => 'フィルターをクリア';

  @override
  String get topPicks => 'おすすめ';

  @override
  String get anime => 'アニメ';

  @override
  String get moviesSeries => '映画・シリーズ';

  @override
  String get noSourcesInstalled => 'ソースがインストールされていません';

  @override
  String get fromYourResults => '· 検索結果から';

  @override
  String get any => '指定なし';

  @override
  String get someSourcesDonTProvideGenres => 'ジャンルを提供しないソースがあります';

  @override
  String get searchInSources => 'ソース内を検索';

  @override
  String get turnAllOff => 'すべてオフ';

  @override
  String get extensionsUpdated => '拡張機能を更新しました';

  @override
  String get incognito => 'シークレットモード';

  @override
  String get reconnectToSync => '再接続して同期';

  @override
  String get yourSessionExpiredTapToSignInAndSyncYourLibrary =>
      'セッションの期限切れ — タップしてサインインし、ライブラリを同期';

  @override
  String get solveCloudflare => 'Cloudflare を解決';

  @override
  String get switchSource => 'ソースを変更';

  @override
  String get moviesTV => '映画・テレビ';

  @override
  String get couldnTLoadComingSoonPullToRefresh => '近日公開を読み込めません — 引っ張って更新。';

  @override
  String get streamURL => '配信 URL';

  @override
  String get exoplayerSurfaceViewSpikeSP0 => 'ExoPlayer SurfaceView スパイク（SP0）';

  @override
  String get episodes => 'エピソード';

  @override
  String get season => 'シーズン';

  @override
  String get jumpToEpisode => '話へジャンプ…';

  @override
  String get preferredLanguage => '優先する言語…';

  @override
  String get searchOnline => 'オンラインで検索…';

  @override
  String get onlineSubtitles => 'オンライン字幕';

  @override
  String get audioSubs => '音声と字幕';

  @override
  String get nextEpisode => '次の話';

  @override
  String get colour => 'カラー';

  @override
  String get snapshot => 'スナップショット';

  @override
  String get sleepTimer => 'スリープタイマー';

  @override
  String get pictureInPicture => 'ピクチャーインピクチャー';

  @override
  String get switchPlayer => 'Switch Player';

  @override
  String get cast => 'キャスト';

  @override
  String get playbackStats => '再生統計';

  @override
  String get sleepTimerOn => 'スリープタイマーオン';

  @override
  String get lockControls => '操作をロック';

  @override
  String get chat => 'チャット';

  @override
  String get previousEpisode => '前の話';

  @override
  String get nextEpisode2 => '次の話';

  @override
  String get translated => '翻訳済み';

  @override
  String get thisSourceCanTBeCastTryAnotherSource =>
      'このソースはキャストできません — 別のソースを試してください。';

  @override
  String get rewind10Seconds => '10 秒戻す';

  @override
  String get forward10Seconds => '10 秒進める';

  @override
  String get stopCasting => 'キャストを停止';

  @override
  String get usingTheBuiltInPlayerForThisSource => 'このソースは内蔵プレーヤーを使います。';

  @override
  String get closeVideo => '映像を閉じますか？';

  @override
  String get areYouSureYouWantToCloseTheVideo => '映像を閉じてもよろしいですか？';

  @override
  String get downloadInSettings => '設定でダウンロード';

  @override
  String get getTheAnime4KShaders06MBThenTurnItOn =>
      'Anime4K シェーダー（約 0.6 MB）を入手してからオンにする';

  @override
  String get gpuTIER => 'GPUティア';

  @override
  String get endOfEpisode => '話の終わり';

  @override
  String get closeAppWhenTimerEnds => 'タイマー終了時にアプリを閉じる';

  @override
  String get exitTheAppToSaveBattery => 'アプリを終了してバッテリーを節約';

  @override
  String get playNow => '今すぐ再生';

  @override
  String get skipRecap => 'あらすじをスキップ';

  @override
  String get unlockControls => '操作ロックを解除';

  @override
  String get tapToUnlock => 'タップして解除';

  @override
  String get subtitleDelay => '字幕の遅延';

  @override
  String get audioDelay => '音声の遅延';

  @override
  String get androidPlayer => 'Android Player';

  @override
  String get androidPlayerUnavailable => 'Android Player could not start';

  @override
  String get audioNormalization => '音量の正規化';

  @override
  String get searchSubtitlesOnline => '字幕をオンライン検索';

  @override
  String get loadFromFile => 'ファイルから読み込む…';

  @override
  String get translateSubtitles => '字幕を翻訳…';

  @override
  String get language => '言語:';

  @override
  String get movieOrShowTitle => '映画・番組のタイトル';

  @override
  String get theQuickBrownFox => 'すばやい茶色のキツネ';

  @override
  String get seekBar => 'シークバー';

  @override
  String get autoScrollSettings => '自動スクロール設定';

  @override
  String get autoScroll => '自動スクロール';

  @override
  String get touchThePageToPauseItPicksUpAgainWhenYouLetGo =>
      'ページに触れると一時停止 — 離すと再開します。';

  @override
  String get floatingButton => 'フローティングボタン';

  @override
  String get nextChapter => '次の章';

  @override
  String get orKeepPulling => 'またはそのまま引く';

  @override
  String get thatSTheLastChapter => 'これが最後の章です。';

  @override
  String get readerSettings => 'リーダー設定';

  @override
  String get noOtherChaptersLoadedYet => '他の章はまだ読み込まれていません';

  @override
  String get chapters => '章';

  @override
  String get direction => '方向';

  @override
  String get autoWebtoonMode => '自動ウェブトゥーンモード';

  @override
  String get pullToChangeChapter => '引いて章を切り替え';

  @override
  String get volumeKeysTurnPages => '音量ボタンでページ送り';

  @override
  String get invertVolumeKeys => '音量ボタンを反転';

  @override
  String get brightness => '明るさ';

  @override
  String get previousChapter => '前の章';

  @override
  String get thisTitle => 'この作品';

  @override
  String get nextChapter2 => '次の章 →';

  @override
  String get textSize => '文字サイズ';

  @override
  String get appliesStraightAway => 'すぐに反映されます';

  @override
  String get left => '左揃え';

  @override
  String get justify => '両端揃え';

  @override
  String get ltr => '長期';

  @override
  String get rtl => 'RTL';

  @override
  String get letterSpacing => '文字間隔';

  @override
  String get wordSpacing => '単語間隔';

  @override
  String get alignment => '配置';

  @override
  String get a => 'あ';

  @override
  String get searchEpisodes => 'エピソードを検索';

  @override
  String get titleOrEpisodeNumber => 'タイトルまたは話数';

  @override
  String get failedToLoadThisTitle => 'この作品を読み込めませんでした';

  @override
  String get offlineTitle => 'You\'re offline';

  @override
  String get offlineBody => 'Check your connection and try again.';

  @override
  String get changeStatus => 'ステータスを変更';

  @override
  String get tracking => '追跡';

  @override
  String get noEpisodesAvailableFromThisSource => 'このソースにエピソードがありません';

  @override
  String get episodesNotYetAired => 'Episodes not yet aired — check back later';

  @override
  String get noEpisodesMatchYourSearch => '検索に一致するエピソードがありません';

  @override
  String get everyChapterIsAlreadyDownloaded => 'すべての章はすでにダウンロード済みです';

  @override
  String get downloadChapters => '章をダウンロード';

  @override
  String get thisWillTakeAWhileAndUseALotOfStorage => '時間がかかり、容量を多く使います';

  @override
  String get findEpisode => '話を探す';

  @override
  String get findChapter => 'Find chapter';

  @override
  String get refreshChapters => '章を更新';

  @override
  String get refreshEpisodes => 'エピソードを更新する';

  @override
  String get reverseList => 'リストを逆順にする';

  @override
  String get seasons => 'シーズン';

  @override
  String get goToEpisode => '話へ移動';

  @override
  String get episodeNumber => '話数';

  @override
  String get cancelDownload => 'ダウンロードをキャンセル';

  @override
  String get downloaded => 'ダウンロード済み';

  @override
  String get downloadChapter => '章をダウンロード';

  @override
  String get deleteDownload => 'ダウンロードを削除';

  @override
  String get resumeDownload => 'ダウンロードを再開';

  @override
  String get status => '状態';

  @override
  String get year => '年';

  @override
  String get studio => 'スタジオ';

  @override
  String get genres => 'ジャンル';

  @override
  String get synopsis => 'あらすじ';

  @override
  String get readMore => '続きを読む';

  @override
  String get downloadChooseServer => 'ダウンロード · サーバーを選択';

  @override
  String get noDownloadSourcesFound => 'ダウンロード用ソースが見つかりません';

  @override
  String get audio => 'オーディオ';

  @override
  String get noEpisodesMatch => '一致するエピソードがありません';

  @override
  String get selectEpisodes => 'エピソードを選択';

  @override
  String get startFrom => '開始位置';

  @override
  String get jumpToEpisode2 => '話へジャンプ';

  @override
  String get downloadEpisodes => 'エピソードをダウンロード';

  @override
  String get noEpisodes => 'エピソードがありません';

  @override
  String get dub2 => '吹替';

  @override
  String get autoBestAvailable => '自動 · 利用可能な最高';

  @override
  String get linksReloaded => 'リンクを再読み込みしました';

  @override
  String get noSourcesFoundForThisEpisode => 'この話のソースが見つかりません';

  @override
  String get starring => '出演';

  @override
  String get creators => '制作';

  @override
  String get notify => '通知する';

  @override
  String get stopAlerts => '通知を停止';

  @override
  String get trackedEditStatusScoreProgress => '記録中 — ステータス、スコア、進捗を編集';

  @override
  String get openSourceSite => 'ソースサイトを開く';

  @override
  String get signInToSource => 'Sign in';

  @override
  String get welcomeBack => 'おかえりなさい';

  @override
  String get signInToSyncYourListAcrossDevices => 'サインインして、リストを端末間で同期。';

  @override
  String get logIn => 'ログイン';

  @override
  String get passwordMustBeAtLeast8Characters => 'パスワードは 8 文字以上にしてください';

  @override
  String get createAccount => 'アカウントを作成';

  @override
  String get saveYourListAndContinueWatchingAnywhere => 'リストを保存して、どこでも続きから視聴。';

  @override
  String get notSignedIn => '未サインイン';

  @override
  String get haveTheApp => 'アプリをお持ちですか？';

  @override
  String get openZangetsuOnYourNphoneAndScan =>
      'スマホで Zangetsu を開き、\\nスキャンしてください';

  @override
  String get noApp => 'アプリがありませんか？';

  @override
  String get resetPassword => 'パスワードをリセット';

  @override
  String get youExampleCom => 'あなた@example.com';

  @override
  String get sendLink => 'リンクを送信';

  @override
  String get email => 'Eメール';

  @override
  String get password => 'パスワード';

  @override
  String get forgotPassword => 'パスワードをお忘れですか？';

  @override
  String get name => '名前';

  @override
  String get password8Characters => 'パスワード（8 文字以上）';

  @override
  String get editName => '名前を編集';

  @override
  String get yourName => 'あなたの名前';

  @override
  String get couldnTUpdateYourName => '名前を更新できませんでした';

  @override
  String get pairATV => 'テレビをペアリング';

  @override
  String get addPhoto => '写真を追加';

  @override
  String get backUpBeforeLoggingOut => 'ログアウト前にバックアップしますか？';

  @override
  String get logOutAnyway => 'このままログアウト';

  @override
  String get reconnect => '再接続';

  @override
  String get signInWithYourPhone => 'スマホでサインイン';

  @override
  String
  get onTheZangetsuAppOnYourPhoneOpenNPairATVAndEnterThisCodeOrScanTheQR =>
      'スマホの Zangetsu で「テレビをペアリング」を開き、\\nこのコードを入力するか、QR をスキャンしてください。';

  @override
  String get signingIn => 'サインイン中…';

  @override
  String get getANewCode => '新しいコードを取得';

  @override
  String get sendTrackers => 'トラッカーを送信';

  @override
  String get chooseTrackersToSend => '送信するトラッカーを選択';

  @override
  String get sendToTV => 'テレビに送信';

  @override
  String get signInToYourAccountFirstNthenPairYourTV =>
      '先にアカウントにサインインし、\\nテレビをペアリングしてください。';

  @override
  String get enterTheCodeFromYourTV => 'テレビに表示されたコードを入力';

  @override
  String get openZangetsuOnYourTVAndSignInWithYourPhoneToSeeIt =>
      'テレビで Zangetsu を開き、スマホでサインインすると表示されます。';

  @override
  String get abcd2345 => 'ABCD 2345';

  @override
  String get thisTVWillSignIntoYourAccountYouCanSignItOutLater =>
      'このテレビがアカウントにサインインします。後から切断できます。';

  @override
  String get alsoSendYourTrackersAniListMyAnimeListSimkl =>
      'トラッカーも送信（AniList、MyAnimeList、Simkl）';

  @override
  String get yourTVIsSignedIn => 'テレビはサインイン済みです';

  @override
  String get itShouldSwitchToYourAccountInAMoment => 'まもなくアカウントに切り替わります。';

  @override
  String get backedUpToCloud => 'クラウドにバックアップしました';

  @override
  String get couldnTSaveTheBackupFileStoragePermissionMayBeNeeded =>
      'バックアップを保存できません — ストレージの許可が必要な場合があります。';

  @override
  String get noCloudBackupFound => 'クラウドのバックアップがありません';

  @override
  String get thatFileIsnTAValidBackup => 'そのファイルは有効なバックアップではありません。';

  @override
  String get pickABackup => 'バックアップを選択';

  @override
  String get couldnTReadThatBackupFile => 'そのバックアップファイルを読めませんでした。';

  @override
  String get restoreComplete => '復元が完了しました';

  @override
  String get reopenZangetsuToSeeRestoredLibrarySources =>
      'Zangetsu を開き直すと、復元したライブラリとソースが表示されます。';

  @override
  String get saveToAFile => 'ファイルに保存';

  @override
  String get saveABackupFileToYourDownloadsFolder => 'ダウンロードフォルダーにバックアップを保存';

  @override
  String get backUpToCloud => 'クラウドにバックアップ';

  @override
  String get saveACopyToYourAccountNeedsSignIn => 'アカウントにコピーを保存 · サインインが必要';

  @override
  String get restoreFromAFile => 'ファイルから復元';

  @override
  String get pickABackupFileYouSavedEarlier => '以前保存したバックアップを選択';

  @override
  String get restoreFromCloud => 'クラウドから復元';

  @override
  String get bringBackYourLatestCloudBackup => '最新のクラウドバックアップを戻す';

  @override
  String get episodesYouDownloadAppearHere => 'ダウンロードしたエピソードがここに表示されます';

  @override
  String get deleteAllEpisodes => 'すべてのエピソードを削除';

  @override
  String get deleteAllDownloads => 'すべてのダウンロードを削除しますか？';

  @override
  String get deleteAll => 'すべて削除';

  @override
  String get changeDownloadFolder => 'ダウンロードフォルダーを変更';

  @override
  String get savingTo => '保存先';

  @override
  String get needsAFileManagerAppOnTheTV => 'テレビにファイル管理アプリが必要です';

  @override
  String get downloadLocation => 'ダウンロード先';

  @override
  String get novelChaptersYouDownloadAppearHere => 'ダウンロードした小説の章がここに表示されます';

  @override
  String get stopDownloading => 'ダウンロードを止めますか？';

  @override
  String get keepGoing => '続ける';

  @override
  String get stopAll => 'すべて停止';

  @override
  String get searchDownloads => 'ダウンロードを検索';

  @override
  String get deleteAllChapters => 'すべての章を削除';

  @override
  String get deleteAllChapters2 => 'すべての章を削除しますか？';

  @override
  String get chapter => '章';

  @override
  String get downloadSettings => 'ダウンロード設定';

  @override
  String get parallelDownloads => '同時ダウンロード数';

  @override
  String get connectionsPerDownload => 'ダウンロードあたりの接続数';

  @override
  String get novels => '小説';

  @override
  String get noDownloadsMatchYourSearch => '検索に一致するダウンロードがありません';

  @override
  String get collapseAll => 'すべて折りたたむ';

  @override
  String get requestedControl => '操作をリクエストしました';

  @override
  String get noParticipantsYet => 'まだ参加者がいません';

  @override
  String get guest => 'ゲスト';

  @override
  String get wantsControl => '操作を希望';

  @override
  String get giveControl => '操作を渡す';

  @override
  String get hostControlsPlayback => 'ホストが再生を操作';

  @override
  String get requestControl => '操作をリクエスト';

  @override
  String get inviteCopied => '招待をコピーしました';

  @override
  String get roomChat => 'ルームチャット';

  @override
  String get noMessagesYet => 'まだメッセージはありません';

  @override
  String get message => 'メッセージ…';

  @override
  String get invite => '招待';

  @override
  String get watchTogether => '一緒に視聴';

  @override
  String get createARoom => 'ルームを作成';

  @override
  String get joinWithACode => 'コードで参加';

  @override
  String get roomNotFound => 'ルームが見つかりません';

  @override
  String get enterRoomCode => 'ルームコードを入力';

  @override
  String get eGABC234 => '例: ABC234';

  @override
  String get hostIsChoosing => 'ホストが選択中…';

  @override
  String get youLlStartWatchingAutomaticallyWhenTheHostPlaysSomething =>
      'ホストが再生を始めると、自動で視聴が始まります。';

  @override
  String get participants => '参加者';

  @override
  String get signInToUseWatchParty => 'サインインして同時視聴を使う';

  @override
  String get youReAlreadyInAParty => 'すでにパーティに参加しています';

  @override
  String get watchTogether2 => '一緒に視聴';

  @override
  String get createAPartyAndInviteFriendsOrJoinAnExistingOneWithACode =>
      'パーティを作って友達を招待するか、コードで既存のパーティに参加。';

  @override
  String get aniyomiIsnTAvailableOnThisDevice => 'この端末では Aniyomi を利用できません。';

  @override
  String get installed => 'インストール済み';

  @override
  String get repositories => 'リポジトリ';

  @override
  String get languages => '言語';

  @override
  String get addAniyomiRepo => 'Aniyomi リポジトリを追加';

  @override
  String get noAniyomiSourcesInstalled => 'Aniyomi ソースはインストールされていません。';

  @override
  String get removeRepo => 'リポジトリを削除しますか？';

  @override
  String get noAniyomiReposAddedYetNPressAddAniyomiRepoToAddOne =>
      'Aniyomi リポジトリはまだありません。\\n「Aniyomi リポジトリを追加」で追加してください。';

  @override
  String get addRepository => 'リポジトリを追加';

  @override
  String get searchNovelSources => '小説ソースを検索';

  @override
  String get noSourcesInstalledYet => 'ソースはまだインストールされていません。';

  @override
  String get addNovelRepo => '小説リポジトリを追加';

  @override
  String get removeRepository => 'リポジトリを削除';

  @override
  String get noSourcesInThisRepo => 'このリポジトリにソースはありません。';

  @override
  String get zangetsuProviders => 'Zangetsu プロバイダー';

  @override
  String get addRepo => 'リポジトリを追加';

  @override
  String get noProvidersInstalled => 'プロバイダーはインストールされていません。';

  @override
  String get noSourcesInThisRepoYet => 'このリポジトリにソースはまだありません。';

  @override
  String get leaveBlankToUseTheRepoSOwnName => '空欄のままにするとリポジトリ名を使います';

  @override
  String get addCloudStreamRepo => 'CloudStream リポジトリを追加';

  @override
  String get noCloudStreamSourcesInstalled => 'CloudStream ソースはインストールされていません。';

  @override
  String get cloudstream => 'クラウドストリーム';

  @override
  String get sourceSettings => 'ソース設定';

  @override
  String get otherSettings => 'その他の設定';

  @override
  String get otherSettingsSubtitle => 'このソースには、ここではまだ表示できない設定があります';

  @override
  String get sourceDomain => 'ソースのドメイン';

  @override
  String get sourceDomainHint => '空欄にすると、ソース本来のドメインを使用します。';

  @override
  String resetSourceDataConfirm(String name) {
    return '$nameの保存データをリセットしますか?保存された設定、ログイン情報、Cookieが削除されます。リスト、履歴、ダウンロードには影響しません。';
  }

  @override
  String get removeRepository2 => 'リポジトリを削除しますか？';

  @override
  String get removeThisRepositoryAndItsSources => 'このリポジトリとそのソースを削除しますか？';

  @override
  String get removed => '削除しました';

  @override
  String get alreadyUpToDate => 'すでに最新です';

  @override
  String get removeRepo2 => 'リポジトリを削除';

  @override
  String get noInstallableSourcesFoundInThisRepo =>
      'このリポジトリにインストールできるソースがありません。';

  @override
  String get thisRemovesTheSourceFromYourInstalledList =>
      'インストール済みリストからこのソースを外します。';

  @override
  String get addCSRepo => 'CS リポジトリを追加';

  @override
  String get cloudstreamIsnTAvailableOnThisDevice =>
      'この端末では CloudStream を利用できません。';

  @override
  String get checkUpdates => '更新を確認';

  @override
  String get pasteACloudStreamRepositoryURL =>
      'CloudStream リポジトリの URL を貼り付けてください。';

  @override
  String get reTest => '再テスト';

  @override
  String get noEnabledSourcesToTest => 'テストする有効なソースがありません。';

  @override
  String get notSearched => '未検索';

  @override
  String get thisSourceHasNoSettings => 'このソースに設定はありません';

  @override
  String get resetToDefaults => '初期値に戻す';

  @override
  String get providerSettings => 'プロバイダー設定';

  @override
  String get openThisSourceSOwnSettingsEGServerLanguage =>
      'このソース独自の設定を開く（サーバー、言語など）';

  @override
  String get addZangetsuRepo => 'Zangetsu リポジトリを追加';

  @override
  String get theProviderWillBeRemovedFromYourInstalledSources =>
      'インストール済みソースからこのプロバイダーを外します。';

  @override
  String get addMihonRepo => 'Mihon リポジトリを追加';

  @override
  String get noMihonReposAddedYetNTapAddMihonRepoToAddOne =>
      'Mihon リポジトリはまだありません。\\n「Mihon リポジトリを追加」をタップしてください。';

  @override
  String get n1Update => '1件の更新';

  @override
  String get noExtensionsFoundInThisRepo => 'このリポジトリに拡張機能がありません。';

  @override
  String get thisRemovesTheExtensionFromYourInstalledSources =>
      'インストール済みソースからこの拡張機能を外します。';

  @override
  String get noMihonSourcesInstalled => 'Mihon ソースはインストールされていません。';

  @override
  String get noAniyomiReposAddedYetNTapAddAniyomiRepoToAddOne =>
      'Aniyomi リポジトリはまだありません。\\n「Aniyomi リポジトリを追加」をタップしてください。';

  @override
  String get clearAll => 'すべてクリア';

  @override
  String get nothingWatchedYet => 'まだ視聴した作品はありません';

  @override
  String get nothingReadYet => 'まだ読んだ作品はありません';

  @override
  String get checkingForNewEpisodes => '新しいエピソードを確認中…';

  @override
  String get checkNow => '今すぐ確認';

  @override
  String get turnOff => 'オフにする';

  @override
  String get joinBetaUpdates => 'ベータ更新に参加しますか？';

  @override
  String get joinBeta => 'ベータに参加';

  @override
  String get whatSNew => '更新内容';

  @override
  String get categories => 'カテゴリ';

  @override
  String get moviesSeries2 => '映画／シリーズ';

  @override
  String get longPressASourceToPinItToTheTop => 'ソースを長押しすると上部にピン留め';

  @override
  String get searchSources => 'ソースを検索';

  @override
  String get justLook => '見るだけ';

  @override
  String get moveProgressHere => '進捗をここに移す';

  @override
  String get newAniListList => '新しい AniList リスト';

  @override
  String get rewatchingFavourites => '再視聴、お気に入り、…';

  @override
  String get anilistCustomLists => 'AniList カスタムリスト';

  @override
  String get savedToYourAniListAccount => 'AniList アカウントに保存しました';

  @override
  String get newList => '新しいリスト';

  @override
  String get createsItOnAniList => 'AniList 上に作成します';

  @override
  String get yourTrackersDisagree => 'トラッカーの値が一致しません';

  @override
  String get applyingSetsThemAllToTheNumberBelow => '適用すると、すべて下の数字に揃えます。';

  @override
  String get wrongTitleChangeMatch => '違う作品ですか？  一致を変更';

  @override
  String get searchTheCorrectTitle => '正しいタイトルを検索…';

  @override
  String get noMatchesFound => '一致するものがありません';

  @override
  String get removeFromMyList => 'マイリストから外す';

  @override
  String get details => '詳細';

  @override
  String get noDescriptionAvailable => '説明はありません。';

  @override
  String get playWith => '再生アプリ…';

  @override
  String get playMirror => 'ミラーで再生';

  @override
  String get chooseTheSourceBeforeItStarts => '開始前にソースを選ぶ';

  @override
  String get reloadLinks => 'リンクを再読み込み';

  @override
  String get fetchFreshStreamsIfPlaybackKeepsFailing => '再生に失敗し続ける場合は新しい配信を取得';

  @override
  String get alsoUpdatesYourConnectedTrackers => '連携中のトラッカーも更新します';

  @override
  String get markThisAndAllAboveAsWatched => 'これより上をすべて視聴済みにする';

  @override
  String get playThisEpisodeWith => 'この話の再生方法';

  @override
  String get builtInPlayer => '内蔵プレーヤー';

  @override
  String get mpvPlayer => 'mpv';

  @override
  String get otherApps => 'ほかのアプリ';

  @override
  String get seeAll2 => 'すべて見る';

  @override
  String get webView => 'WebView';

  @override
  String get openInBrowser => 'ブラウザで開く';

  @override
  String get markAsRead => 'Mark as read';

  @override
  String get copyLink => 'リンクをコピー';

  @override
  String get removeTracking => 'トラッキングを解除';

  @override
  String get noTrackersConnectedNConnectOneInSettingsConnections =>
      'トラッカーが未接続です。\\n設定 → 連携 で接続してください。';

  @override
  String get syncAllAtOnce => 'まとめて同期';

  @override
  String get addTracking => 'トラッキングを追加';

  @override
  String get addToYourList => 'リストに追加';

  @override
  String get removeFromList => 'リストから外す';

  @override
  String get customLists => 'カスタムリスト';

  @override
  String get addToSeries => 'Add to series';

  @override
  String get noSeries => 'No series';

  @override
  String get newSeries => 'New series';

  @override
  String get deleteSeries => 'Delete series';

  @override
  String get deleteSeriesConfirm =>
      'Delete this series? Your titles stay on My List.';

  @override
  String get notInAny => '未分類';

  @override
  String get status2 => '状態';

  @override
  String get applyChanges => '変更を適用';

  @override
  String get navigationBar => 'ナビゲーションバー';

  @override
  String get navigationBarSubtitle => '表示するタブと順序';

  @override
  String get navDockBehavior => 'Dock behavior';

  @override
  String get keepDockExpanded => 'Keep dock expanded';

  @override
  String get keepDockExpandedSubtitle =>
      'Keep the labels visible while scrolling';

  @override
  String connectedCount(int count) {
    return '$count件接続済み';
  }

  @override
  String get syncLibraryAlreadySynced => 'ライブラリはこのアカウントと同期済みです。';

  @override
  String syncLibraryPushed(int history, int list) {
    return '履歴$history件・リスト$list件をアカウントに同期しました。';
  }

  @override
  String navTabsOnBar(int count, int max) {
    return 'バー上 · $count/$max';
  }

  @override
  String episodeAirsIn(int episode, String when) {
    return 'Ep $episode · in $when';
  }

  @override
  String get duration => 'Duration';

  @override
  String get score => 'Score';

  @override
  String get popularity => 'Popularity';

  @override
  String get favourites => 'Favourites';

  @override
  String get sourceMaterial => 'Source';

  @override
  String get country => 'Country';

  @override
  String get aired => 'Aired';

  @override
  String get nativeTitle => 'Native title';

  @override
  String get alsoKnownAs => 'Also known as';

  @override
  String get tags => 'Tags';

  @override
  String showSpoilerTags(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show # spoiler tags',
      one: 'Show # spoiler tag',
    );
    return '$_temp0';
  }

  @override
  String get navTabsSwitcher => 'Mode switcher';

  @override
  String get navTabsSwitcherWhy => 'Takes the middle slot';

  @override
  String get navTabsOpensOn => 'Opens on launch';

  @override
  String get navTabsNotShown => '表示されていません';

  @override
  String get navTabsEveryTabOnBar => 'すべての勘定はバーカウンターに記されている。';

  @override
  String get searchMovesToHomeInZMode =>
      'Search moves to the top of Home in Z Mode.';

  @override
  String navTabsHelp(int minTabs, int maxTabs) {
    return 'ドラッグして並べ替えてください。 $minTabs～$maxTabs 個のタブがバーに表示されます。\n\nプロフィールは設定画面への唯一のアクセス方法であるため、ピン留めされています。非表示にすると、この画面に戻る方法がなくなります。スケジュールはストリーミングモードでのみ表示されます。閲覧中は放送スケジュールは表示されません。';
  }

  @override
  String get navTabsStreamingOnly => 'ストリーミング配信のみ';

  @override
  String get navTabsRemove => '取り除く';

  @override
  String navTabsKeepMinTabs(int min) {
    return '少なくとも $min 個のタブを保持する';
  }

  @override
  String get navTabsAdd => '追加';

  @override
  String get navTabsBarFull => 'バーは満員です';

  @override
  String filterShowResults(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show # results',
      one: 'Show # result',
    );
    return '$_temp0';
  }

  @override
  String addedCloudStreamSourcesCount(int count) {
    return '追加済み — 利用可能なCloudStreamソース： $count ';
  }

  @override
  String failedToAddRepository(String error) {
    return 'リポジトリの追加に失敗しました: $error';
  }

  @override
  String get repositoryUrlLabel => 'リポジトリURL';

  @override
  String noResultsFor(String query) {
    return '「$query」の検索結果はありません';
  }

  @override
  String get yourSavedTitles => '保存したタイトル';

  @override
  String myListPlusTrackers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'trackers',
      one: 'tracker',
    );
    return 'マイリスト + $count $_temp0';
  }

  @override
  String get sort => '選別';

  @override
  String get shuffle => 'ランダムに選ぶ';

  @override
  String get giveItAName => '名前を付けて';

  @override
  String get youAlreadyHaveThatOne => 'あなたは既にそれを持っています';

  @override
  String get thatNameIsTaken => 'その名前は既に使われています';

  @override
  String get notConnected => '接続されていません';

  @override
  String connectedWithViewer(String name) {
    return '接続済み · $name';
  }

  @override
  String get allTypes => 'いろんなタイプ';

  @override
  String get nothingHereInThisFilter => 'このフィルターには何も含まれていません';

  @override
  String get noMangaHereInThisFilter => 'このフィルターにはマンガはありません';

  @override
  String get noNovelsHereInThisFilter => 'このフィルターには小説はありません';

  @override
  String get mangaYouAddAppearHere => '追加したマンガはここに表示されます';

  @override
  String get novelsYouAddAppearHere => 'あなたが追加した小説はここに表示されます';

  @override
  String get relations => '関係';

  @override
  String get overview => 'Overview';

  @override
  String get director => 'Director';

  @override
  String get writer => 'Writer';

  @override
  String get characters => 'キャラクター';

  @override
  String get noCastInformation => 'キャスト情報なし';

  @override
  String get noRelatedTitles => '関連タイトルはありません';

  @override
  String get markedAsWatched => '視聴済みとしてマーク';

  @override
  String get markedUnwatched => '未視聴としてマークされました';

  @override
  String markedEpisodesAsWatched(int count) {
    return '視聴済みとして $count エピソードをマークしました';
  }

  @override
  String get openInBrowserSubtitle =>
      'Read this chapter on the source\'s own site';

  @override
  String get readingSettings => 'Reading settings';

  @override
  String get markedAsRead => 'Marked as read';

  @override
  String get markedUnread => 'Marked unread';

  @override
  String markedChaptersAsRead(int count) {
    return 'Marked $count chapters as read';
  }

  @override
  String downloadChaptersQuestion(int count) {
    return ' $count 章をダウンロードしますか？';
  }

  @override
  String get cachedSourceJsFiles => 'キャッシュされたソース.jsファイル';

  @override
  String disconnectTrackerQuestion(String name) {
    return '切断 $name?';
  }

  @override
  String trackerDisconnectBody(String name) {
    return '自動同期は停止します。お客様の $name アカウントは変更されていません。いつでも再接続できます。';
  }

  @override
  String connectedAs(String name) {
    return ' $nameとして接続済み';
  }

  @override
  String trackerConnectionCanceled(String name) {
    return '$name 接続がキャンセルされました';
  }

  @override
  String connectTracker(String name) {
    return '接続 $name';
  }

  @override
  String get connectingEllipsis => '接続中...';

  @override
  String updateTrackerAsYouWatch(String name) {
    return '視聴しながら $name を更新してください';
  }

  @override
  String findingTitle(String title) {
    return '「$title」を検索中…';
  }

  @override
  String titleIsntOnThisSource(String title) {
    return '\"$title\" はこのソースには含まれていません';
  }

  @override
  String couldntOpenTitle(String title) {
    return '\"$title\" を開けませんでした';
  }

  @override
  String get noWebPageForThisSource => 'この情報源のウェブページはありません';

  @override
  String get couldNotOpenSourceSite => 'ソースサイトを開けませんでした';

  @override
  String notificationsOffFor(String title) {
    return '「$title」の通知はオフになっています';
  }

  @override
  String youllBeNotifiedOfNewEpisodesFor(String title) {
    return '「$title」の新しいエピソードが公開されたら通知されます';
  }

  @override
  String youllBeNotifiedOfNewChaptersFor(String title) {
    return '「$title」の新しい章が公開されると通知されます';
  }

  @override
  String get external => '外部の';

  @override
  String episodeLabel(int number) {
    return 'エピソード $number';
  }

  @override
  String downloadSeasonEpisode(int season, int episode) {
    return 'ダウンロード S$season:E$episode';
  }

  @override
  String downloadEpisodeLabel(int episode) {
    return 'E$episodeをダウンロード';
  }

  @override
  String get continueLabel => '続く';

  @override
  String continueEpisode(int episode) {
    return '続行 E$episode';
  }

  @override
  String get noEpisodesToDownload => 'ダウンロードできるエピソードはありません';

  @override
  String get addedToDownloads => 'ダウンロードに追加されました';

  @override
  String downloadingNEpisodes(int count) {
    return ' $count エピソードをダウンロード中';
  }

  @override
  String get addToMyList => 'マイリストに追加';

  @override
  String get notifyOnNewChapters => '新しい章が配信されたら通知を受け取る';

  @override
  String get notifyOnNewEpisodes => '新しいエピソードの通知を受け取る';

  @override
  String get allowNotificationsForAlerts =>
      'Allow notifications in Android settings to receive alerts.';

  @override
  String get syncStatusScoreProgress => '同期状況、スコア、進捗状況';

  @override
  String seasonCount(int count) {
    return '$count Seasons';
  }

  @override
  String episodeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Episodes',
      one: '1 Episode',
    );
    return '$_temp0';
  }

  @override
  String chapterCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Chapters',
      one: '1 Chapter',
    );
    return '$_temp0';
  }

  @override
  String get thisSourceNeedsSpecialHeadersUsingBuiltIn =>
      'このソースには、外部プレーヤーでは送信できない特別なヘッダーが必要です。そのため、内蔵プレーヤーを使用してください。';

  @override
  String timerMinutes(int count) {
    return '$count 分';
  }

  @override
  String couldNotLoadSubtitle(String error) {
    return '字幕を読み込めませんでした: $error';
  }

  @override
  String get speed => 'スピード';

  @override
  String get styledSubtitlesLibassSubtitle =>
      'リアルな.assスタイリング ― 看板、カラオケ。適用するにはエピソードを再度開いてください。';

  @override
  String couldntDownloadFile(String file) {
    return ' $fileをダウンロードできませんでした';
  }

  @override
  String get audioNormalizationSubtitle => '音量を均一化し、静かな会話を強調し、騒々しいシーンを抑えます。';

  @override
  String get playbackSpeed => '再生速度';

  @override
  String get quality => '品質';

  @override
  String get sources => '出典';

  @override
  String get normalSpeed => '普通';

  @override
  String get subtitles => '字幕';

  @override
  String preferredLanguageColon(String name) {
    return '優先言語: $name';
  }

  @override
  String nextCount(int count) {
    return '次へ $count';
  }

  @override
  String allCount(int count) {
    return 'すべて $count';
  }

  @override
  String notSavedCount(int count) {
    return '$count 保存されませんでした';
  }

  @override
  String get airsIn => '放送日';

  @override
  String get selectAll => 'すべて選択';

  @override
  String get best => '最高';

  @override
  String get direct => '直接';

  @override
  String get hls => 'HLS';

  @override
  String serverWithHost(int number, String host) {
    return 'サーバー $number · $host';
  }

  @override
  String serverNumber(int number) {
    return 'サーバー $number';
  }

  @override
  String downloadCountEpisodes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Download $count episodes',
      one: 'Download 1 episode',
    );
    return '$_temp0';
  }

  @override
  String downloadSizeEstimate(String perEpisode, String total) {
    return '$perEpisode / episode · $total total';
  }

  @override
  String get storageLowTitle => 'Not enough space?';

  @override
  String storageLowBody(String need, String free) {
    return 'This needs about $need but only $free is free. Download anyway?';
  }

  @override
  String get downloadAnyway => 'Download anyway';

  @override
  String get chapterOneAtATimeWarning =>
      'これは一度に1章ずつ再生されるため、時間がかかる場合があります。ダウンロード画面から停止できます。';

  @override
  String queuedChapters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return 'キューに追加済み $_temp0';
  }

  @override
  String seasonNumber(int number) {
    return 'シーズン $number';
  }

  @override
  String get listView => 'リストビュー';

  @override
  String get gridView => 'グリッドビュー';

  @override
  String get refreshingChapters => '爽快な章立て…';

  @override
  String get refreshingEpisodes => '爽快なエピソード…';

  @override
  String chapterLabel(int number) {
    return 'Chapter $number';
  }

  @override
  String get continueBadge => '続く';

  @override
  String get fillerBadge => 'フィラー';

  @override
  String get downloadUnsupported => 'ダウンロード対象外';

  @override
  String get retryDownload => 'ダウンロードを再試行';

  @override
  String get downloadEpisode => 'エピソードをダウンロード';

  @override
  String get pauseDownload => 'ダウンロードを一時停止';

  @override
  String fromEpisode(int episode) {
    return 'E$episodeから';
  }

  @override
  String episodeWithTitle(int number, String title) {
    return 'E$number · $title';
  }

  @override
  String episodeNumberShort(int number) {
    return 'E$number';
  }

  @override
  String episodeRange(int first, int last) {
    return 'E$first – E$last';
  }

  @override
  String episodeSemanticWithTitle(int number, String title) {
    return 'エピソード $number、 $title';
  }

  @override
  String searchColon(String query) {
    return '検索: $query';
  }

  @override
  String decoderColon(String label) {
    return 'デコーダー・ $label';
  }

  @override
  String get megaSkipDuration => 'MegaSkipの期間';

  @override
  String get settingsTooltip => '設定';

  @override
  String episodeCountWithRange(int count, String range) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count episodes',
      one: '1 episode',
    );
    return '$_temp0 · $range';
  }

  @override
  String get sourceTimedOut => 'タイムアウト';

  @override
  String get blockedByTheSite => 'サイトによってブロックされました';

  @override
  String get sourceCouldntBeReached => '連絡が取れませんでした';

  @override
  String get thatSourceCouldNotBeReached => 'その情報源には連絡が取れませんでした';

  @override
  String get noSourceCouldBeReached => '情報源に連絡が取れなかった';

  @override
  String andNMore(int count) {
    return 'その他 $count 件';
  }

  @override
  String get tryClearingYourFiltersOrSearchDifferentTitle =>
      'フィルターを解除するか、別のタイトルで検索してみてください。';

  @override
  String noModeSourcesYet(String mode) {
    return 'まだ $mode ソースがありません';
  }

  @override
  String get browseRepositories => 'リポジトリを閲覧する';

  @override
  String filteredSource(String source) {
    return 'フィルタリング済み · $source';
  }

  @override
  String get turnAllOn => 'すべてオンにする';

  @override
  String get sortUpper => '選別';

  @override
  String get typeUpper => 'タイプ';

  @override
  String get audioUpper => 'オーディオ';

  @override
  String get genreUpper => 'ジャンル';

  @override
  String get movieLabel => '映画';

  @override
  String get speakTheTitle => 'タイトルを言ってください';

  @override
  String get signedIn => 'ログイン済み';

  @override
  String get syncYourListNav => 'リストを同期する';

  @override
  String get sourceNavLabel => 'ソース';

  @override
  String get activeSourceHint => '現在';

  @override
  String clearKindHistoryTitle(String kind) {
    return 'Clear $kind history?';
  }

  @override
  String clearKindHistoryBody(String noun, String kind) {
    return 'これにより、 $kind の履歴から $noun がすべて削除されます。その他の履歴、リスト、ダウンロードは影響を受けません。';
  }

  @override
  String get showsYouWatchWillAppearHere =>
      '視聴した番組はここに表示されるので、中断したところから視聴を再開できます。';

  @override
  String get mangaYouReadWillAppearHere =>
      '読んだ漫画はここに表示されるので、中断したところから読み始めることができます。';

  @override
  String get novelsYouReadWillAppearHere =>
      '読んだ小説はここに表示されるので、中断したところから読み始めることができます。';

  @override
  String episodeWatchedPct(int number, int percent) {
    return 'エピソード $number · $percent%視聴済み';
  }

  @override
  String percentWatched(int percent) {
    return '$percent% watched';
  }

  @override
  String addSourceFromProvidersHint(String content) {
    return 'プロバイダーからソースを追加すると、 $content がここに表示されます。';
  }

  @override
  String continueDotEpisode(int episode) {
    return '続行 · E$episode';
  }

  @override
  String sourceNameItemCount(String name, int count) {
    return '$name · $count';
  }

  @override
  String sourceCountBadge(String sourceName, int count) {
    return '$sourceName $count';
  }

  @override
  String get logOutQuestion => 'ログアウト？';

  @override
  String get contentShows => 'ショー';

  @override
  String get contentManga => 'マンガ';

  @override
  String get contentNovels => '小説';

  @override
  String get historyKindWatch => '時計';

  @override
  String get historyKindManga => 'マンガ';

  @override
  String get historyKindNovel => '小説';

  @override
  String get historyNounShow => '見せる';

  @override
  String get historyNounMangaItem => 'マンガ';

  @override
  String get historyNounNovelItem => '小説';

  @override
  String get qualityAndAudio => '品質とオーディオ';

  @override
  String get sectionPlayer => 'プレーヤー';

  @override
  String get sectionGestures => 'ジェスチャー';

  @override
  String get sectionCache => 'キャッシュ';

  @override
  String get gestures => 'ジェスチャー';

  @override
  String get cache => 'キャッシュ';

  @override
  String get social => '社交';

  @override
  String get appSection => 'アプリ';

  @override
  String get team => 'チーム';

  @override
  String get communityContributors => 'コミュニティ貢献者';

  @override
  String get accentColour => 'アクセントカラー';

  @override
  String get display => '画面';

  @override
  String get appIcon => 'アプリのアイコン';

  @override
  String get splashStyle => 'Splash';

  @override
  String get splashStyleBlurb => 'What plays while the app starts up.';

  @override
  String get currentLocation => '現在位置';

  @override
  String get availableDrives => '利用可能なドライブ';

  @override
  String get dataSection => 'データ';

  @override
  String get modeLabel => 'モード';

  @override
  String get tapAZoneToChangeIt => '変更するにはゾーンをタップしてください';

  @override
  String get supportTitle => 'サポート';

  @override
  String enjoyingApp(String appName) {
    return ' $appNameを楽しんでいますか？';
  }

  @override
  String donateBlurb(String appName) {
    return '$appName は無料で広告も表示されません。もしあなたのホーム画面にこのアプリを置いてくださっているなら、ちょっとしたチップをいただけると、新機能の追加、バグ修正、アップデートの迅速化など、アプリの成長につながります。どんな小さなご支援でも本当に助かります。ありがとうございます！♥';
  }

  @override
  String get upiIdCopied => 'UPI IDがコピーされました';

  @override
  String get upiIndia => 'UPI · インド';

  @override
  String get askBeforeJumpingSubtitle => '中断した場所以外の場所を開くと、進行状況が移動せずに検索できます。';

  @override
  String get autoTrackSubtitle =>
      '視聴しながらAniList、MyAnimeList、Simklを更新してください。Offモードでは、手動でタイトルを追跡できます。';

  @override
  String get closeConfirmationAsk => 'プレイヤーを離れる前に尋ねてください';

  @override
  String get closeConfirmationDirect => 'すぐに退出してください。';

  @override
  String get closeConfirmationDoubleBack => '戻るボタンを2回押して終了します';

  @override
  String get autoSkipFillerSubtitle => '次のエピソードに進む際に、フィラー部分をスキップしてください（アニメのみ）';

  @override
  String get playTrailersInHDSubtitle =>
      '利用可能な場合は最大1080p、利用できない場合は標準画質にフォールバックします。データ使用量が増えます。';

  @override
  String get nativeTvPlayerSubtitle => '推奨。古いプレーヤーの方が好みの場合のみオフにしてください。';

  @override
  String get softwareAudioSubtitle =>
      'Dolby/DTS音声が無音の場合のみオンにしてください。一部のテレビでは不安定になる場合があります。';

  @override
  String get playerInfoOff => 'オフ';

  @override
  String playerInfoFieldsCount(int count) {
    return '$count 個のフィールド（ⓘボタン）';
  }

  @override
  String downloadingPercent(int percent) {
    return 'ダウンロード中… $percent%';
  }

  @override
  String get tapToDownloadShaders => 'タップしてシェーダーをダウンロード（約0.8MB）';

  @override
  String get noOtherVideoAppsFound =>
      '他の動画アプリは見つかりませんでした。MX Player、VLC、mpv、Just Player、またはNext Playerをインストールしてください。';

  @override
  String get externalApp => '外部アプリ';

  @override
  String get noSubsResumeSuffix => '・履歴書/代替案なし';

  @override
  String get pickWhatShowsOverVideo =>
      '動画の上に表示する内容を選択してください（コントロールと一緒に表示されます）。YouTubeの「オタク向け統計情報」のようなものです。';

  @override
  String get styledSubtitlesLibassSubtitlePlayback =>
      'リアルな.assスタイル ― フォント、配置、カラオケ、記号。アニメに最適。次回のエピソードから適用されます。';

  @override
  String get subtitleStyleSubtitle => 'フォント、色、アウトライン、透明度、サイズ、位置 — ライブプレビュー付き';

  @override
  String get keySavedOnlineSearchEnabled => 'キーが保存されました - オンライン検索が有効になりました';

  @override
  String get incognitoModeBlurb =>
      'オンになっている間は、検索、視聴履歴、トラッカーのスクロブリング、Discordのプレゼンスが一時停止され、オフにするまで何も記録されません。';

  @override
  String get enableNsfwSourcesBody =>
      'これは、ソースリストと切り替え画面で18歳以上向けのコンテンツを表示する機能です。成人向けコンテンツを表示したい場合のみ、この機能をオンにしてください。';

  @override
  String get showNsfwAniyomiSourcesBody =>
      'これは、ソースリストとスイッチャーで、Aniyomi拡張機能が18歳以上向けとしてフラグ付けされていることを示します。成人向けコンテンツを表示したい場合のみ、この機能を有効にしてください。';

  @override
  String get sourcesMarked18Hidden =>
      '18歳以上向けのコンテンツとしてマークされたソースは、この設定が有効になっていない限り、ソース一覧とソース切り替え機能から非表示になります。';

  @override
  String get syncProgressAsYouWatch => '視聴しながら進行状況を同期';

  @override
  String get connectionsBlurb =>
      '視聴状況とリストの状態をアカウント間で同期します。アニメは3つのアカウントすべてに同期され、映画とシリーズはSimklに同期されます。';

  @override
  String get connectDiscord => 'Discordに接続する';

  @override
  String get signInSoYourStatusCanShow => 'サインインすると、あなたのステータスがプロフィールに表示されます';

  @override
  String get disconnectDiscordBody =>
      'Rich Presenceは停止し、このデバイスからトークンが削除されます。Discordアカウントは変更されません。いつでも再接続できます。';

  @override
  String get discordPresenceBlurb =>
      'アプリを開いている間、Discordプロフィールに「視聴中： <title> • エピソードN」（および閲覧中のコンテンツ）を表示します。Discordのログイン情報を使用し、このデバイスにのみ保存されます。いつでもオフにできます。';

  @override
  String get github => 'GitHub';

  @override
  String get telegram => '電報';

  @override
  String get accentColourBlurb => 'ボタン、チップ、進行状況、選択されたアイテム全体で使用されるハイライトカラー。';

  @override
  String get appIconBlurb =>
      'ホーム画面上のアイコンです。アイコンを変更するとZangetsuが閉じます。Androidがランチャーのエントリを切り替える必要があるためです。';

  @override
  String useTheIcon(String label) {
    return ' $label アイコンを使用しますか？';
  }

  @override
  String get useTheIconBody =>
      'Androidが新しいアイコンを適用するため、Zangetsuは一時的に閉じます。その後、ホーム画面から再度起動してください。\n\nZangetsuがフォルダやドックにある場合は、再度追加する必要があるかもしれません。';

  @override
  String get animRise => '上昇';

  @override
  String get animRiseDesc => 'リフトとフェードイン';

  @override
  String get animFade => 'フェード';

  @override
  String get animFadeDesc => 'フェードイン、動きなし';

  @override
  String get animZoom => 'ズーム';

  @override
  String get animZoomDesc => '見た目通りに拡大します';

  @override
  String get usedInVerticalMode => '縦型モードで使用する場合、章は1つの連続した帯状部分として表示されます。';

  @override
  String get usedWhenPagesTurn =>
      'ページが左右にめくる際に使用します。右から左への表示モードでは、2つのページングゾーンが入れ替わります。';

  @override
  String get openPullRequestOnGitHub =>
      'GitHubでプルリクエストを作成すると、あなたの名前が自動的にここに表示されます。';

  @override
  String get onThisDevice => 'このデバイスでは';

  @override
  String get newDownloadsSaveHere =>
      '新規ダウンロードはここに保存されます。既に完了したダウンロードは元の場所に残ります。';

  @override
  String get torrentsOffWifiBlurb =>
      'オフ＝トレントはWi-Fi接続時のみ動作します（モバイルデータ通信量を節約できます）。トレントのストリーミング再生は大量のデータ通信量を消費します。';

  @override
  String get everyControlIsOnABar => 'すべての操作部はバー上に配置されています。';

  @override
  String get nothingHereMoveControl => 'ここには何もありません。Moveを使ってコントロールを移動させてください。';

  @override
  String get playerControlsHelp =>
      'バー内でドラッグして並べ替えることができます。移動ボタンを使ってコントロールを別の場所に移動できます。非表示のコントロールは、プレーヤー内の「⋮ その他」メニューから引き続き利用できます。\n\n「戻る」「ロック」「設定」は上部のバーに固定されており、番組タイトルも同じ行に表示されます。上部に要素を追加すればするほど、タイトルの表示スペースは狭くなります。';

  @override
  String topBarFull(String label) {
    return '$label （フル）';
  }

  @override
  String get apiKeyLabel => 'APIキー';

  @override
  String secondsShort(int count) {
    return '$count秒';
  }

  @override
  String get gotIt => 'わかった';

  @override
  String signInToAction(String action) {
    return ' $actionにサインインしてください';
  }

  @override
  String get cloudBackupFailed =>
      'クラウドバックアップに失敗しました。インターネット接続を確認してください。繰り返し失敗する場合は、クラウドバックアップストアがまだ設定されていない可能性があります。';

  @override
  String get savedToDownloadsZangetsu => 'ダウンロードに保存済み › 斬月';

  @override
  String restoreFailed(String error) {
    return '復元に失敗しました: $error';
  }

  @override
  String get noBackupFilesOnDevice =>
      'このデバイスにはバックアップファイルが見つかりませんでした。まずバックアップファイルを保存するか、「クラウドから復元」を使用してください。';

  @override
  String get backupScreenBlurb =>
      'ソース、リスト、設定を、デバイス上のファイルまたはZangetsuアカウントに保存してください。復元しても、既存のデータは追加されるだけで、削除されることはありません。';

  @override
  String get includeInTheBackup => 'バックアップに含める';

  @override
  String get sourcesAndRepos => 'ソースとリポジトリ';

  @override
  String get installedSourcesAndRepoLinks => 'インストール済みのソースとそのリポジトリへのリンク';

  @override
  String get libraryBundle => '図書館';

  @override
  String get myListAndContinueWatching => 'マイリストと視聴を続ける';

  @override
  String get appSettingsBundle => 'アプリ設定';

  @override
  String get playerSubtitlesQualityPreferences => 'プレーヤー、字幕、画質、設定';

  @override
  String lastCloudBackup(String when) {
    return '最後のクラウドバックアップ: $when';
  }

  @override
  String get never => '一度もない';

  @override
  String restoredColon(String names) {
    return '復元済み: $names。';
  }

  @override
  String couldnTReinstall(String failures) {
    return '再インストールできませんでした:\n$failures';
  }

  @override
  String onLatestVersion(String versionSuffix) {
    return '最新バージョン$versionSuffixを使用しています。';
  }

  @override
  String get joinBetaUpdatesBody =>
      'プレリリース版をいち早く入手できます。不安定な場合もありますので、不具合が発生した場合は、この機能をオフにしてください。次回のアップデートで安定版に戻ります。いつでも利用を停止できます。';

  @override
  String get betaUpdateAvailable => 'ベータ版アップデートが利用可能です';

  @override
  String get updateAvailable => 'アップデートが利用可能';

  @override
  String get startingInstaller => 'インストーラーを起動しています…';

  @override
  String get couldnTOpenInstaller =>
      'インストーラーを開けませんでした。システム設定で「不明なアプリのインストールを許可する」を有効にしてから、もう一度お試しください。';

  @override
  String get downloadFailedCheckConnection =>
      'ダウンロードに失敗しました。接続状況を確認して、もう一度お試しください。';

  @override
  String get libraryIsntSavedReconnect =>
      'ライブラリはまだクラウドに保存されていません。ログアウトすると、このデバイスからライブラリが削除されます。先にバックアップするために再接続しますか？';

  @override
  String sessionExpiredEnterPassword(String account) {
    return 'Your session expired. Enter your password to reconnect $account and sync your library.';
  }

  @override
  String get yourAccount => 'あなたのアカウント';

  @override
  String get reconnecting => '再接続しています...';

  @override
  String get wrongPassword => 'パスワードが間違っています';

  @override
  String trackersSynced(String list) {
    return '同期されたトラッカー数: $list';
  }

  @override
  String signInOnDevice(String device) {
    return ' $deviceにサインインしますか？';
  }

  @override
  String get thisTV => 'このテレビ';

  @override
  String get announcements => 'お知らせ';

  @override
  String get subscribedShows => '購読番組';

  @override
  String get noNotificationsYet =>
      '通知はまだありません。\n\n番組のベルアイコンをタップすると、新しいエピソードが公開された際に通知が届きます。';

  @override
  String get hostBadge => 'ホスト';

  @override
  String controlGivenTo(String name) {
    return ' $nameに制御権が与えられた';
  }

  @override
  String get youReTheHost => 'あなたがホストです';

  @override
  String couldnTCreateParty(String error) {
    return 'パーティを作成できませんでした: $error';
  }

  @override
  String get series => 'シリーズ';

  @override
  String get movie => '映画';

  @override
  String epWithTime(String episode, String time) {
    return 'Ep $episode · $time';
  }

  @override
  String chooseChapterSemantic(String title, String subtitle) {
    return '$title、 $subtitle。章を選択してください';
  }

  @override
  String chapterProgress(int current, int total) {
    return '第 $current 章 / $total章';
  }

  @override
  String chapterNumber(int number) {
    return 'Chapter $number';
  }

  @override
  String activeSourceColon(String name) {
    return 'アクティブなソース: $name';
  }

  @override
  String settingsSemantic(String name) {
    return '$name、設定';
  }

  @override
  String get enterTheCodeShownOnTV => 'テレビ画面に表示されているコードを入力してください。';

  @override
  String get codeNotFoundExpired => 'そのコードは見つかりませんでした。有効期限が切れている可能性があります。';

  @override
  String get alsoSendTrackers => '追跡ツール（AniList、MyAnimeList、Simklなど）も送ってください。';

  @override
  String get scrollRowsOrSearch => 'ホーム画面で各行をスクロールするか、画面下部の検索をタップしてください。';

  @override
  String get openTitleAndPlay =>
      'タイトルを開いて「再生」をタップしてください。シリーズ作品の場合は、まずエピソードを選択してください。';

  @override
  String get switchSourceAtTop => '画面上部のソース名をタップして、別のソースに切り替えてください。';

  @override
  String get tapDownloadForOffline => 'タイトルをタップしてダウンロードすると、「ダウンロード」から後で視聴できます。';

  @override
  String get faqSourceNotWorkingQ => 'ソースが機能していませんか？';

  @override
  String get faqSourceNotWorkingA =>
      'ソースは変更される場合があります。上部からソースを切り替えるか、「設定」→「ソースの状態」を確認してください。';

  @override
  String get faqSubOrDubQ => '字幕版か吹き替え版か？';

  @override
  String get faqSubOrDubA => 'アニメ作品のタイトルにある字幕／吹き替え切り替え機能を使用してください。';

  @override
  String get faqDownloadsQ => 'ダウンロードしたファイルはどこにありますか？';

  @override
  String get faqDownloadsA => '設定 → ダウンロード — いつでもオフラインで視聴できます。';

  @override
  String get resetPasswordBody =>
      'アカウントに登録されているメールアドレスを入力してください。新しいパスワードを設定するためのリンクをお送りします。';

  @override
  String get couldnTSignIn => 'ログインできませんでした';

  @override
  String get aniyomi => 'アニヨミ';

  @override
  String get mihon => 'ミホン';

  @override
  String get lnreader => 'LNリーダー';

  @override
  String get zangetsu => '斬月';

  @override
  String get cloudStream => 'クラウドストリーム';

  @override
  String installedCount(int count) {
    return '$count インストール済み';
  }

  @override
  String installedName(String name) {
    return 'インストール済み $name';
  }

  @override
  String uninstalledName(String name) {
    return 'アンインストール済み $name';
  }

  @override
  String removedName(String name) {
    return '削除済み $name';
  }

  @override
  String updatedName(String name) {
    return ' $nameを更新しました';
  }

  @override
  String installFailed(String error) {
    return 'インストール失敗: $error';
  }

  @override
  String uninstallFailed(String error) {
    return 'アンインストールに失敗しました: $error';
  }

  @override
  String removeFailed(String error) {
    return '削除に失敗しました: $error';
  }

  @override
  String updateFailed(String error) {
    return '更新に失敗しました: $error';
  }

  @override
  String checkFailed(String error) {
    return 'チェック失敗: $error';
  }

  @override
  String failedToAddRepo(String error) {
    return 'リポジトリの追加に失敗しました: $error';
  }

  @override
  String uninstallNameQuestion(String name) {
    return 'アンインストール $name?';
  }

  @override
  String removeNameQuestion(String name) {
    return ' $nameを削除しますか？';
  }

  @override
  String updateNameToVersion(String name, String version) {
    return '$name、v$versionに更新';
  }

  @override
  String updateArrowVersion(String version) {
    return '更新 → v$version';
  }

  @override
  String get repoBaseUrl => 'リポジトリのベースURL';

  @override
  String get repoBaseUrlHint => 'https://.../repo';

  @override
  String get pluginIndexUrl => 'プラグインインデックスURL';

  @override
  String get pluginIndexUrlHint => 'https://.../plugins.min.json';

  @override
  String get manifestUrl => 'マニフェストURL';

  @override
  String get manifestUrlHint => 'https://.../index.json';

  @override
  String get repoUrl => 'リポジトリURL';

  @override
  String get repoUrlHint => 'https://.../repo.json';

  @override
  String get customNameOptional => 'カスタム名（任意）';

  @override
  String get leaveBlankToUseRepo => 'リポジトリを使用する場合は空欄のままにしてください。';

  @override
  String get alreadyInstalledSourcesStay =>
      'このリポジトリから既にインストールされているソースは、そのままインストールされた状態のままです。';

  @override
  String get alreadyInstalledExtensionsStay =>
      'このリポジトリから既にインストールされている拡張機能は、そのままインストールされたままになります。';

  @override
  String updateAllCount(int count) {
    return 'すべて更新 ($count)';
  }

  @override
  String updatedSourcesCount(int done, String suffix) {
    return '更新されたソース $done $suffix';
  }

  @override
  String get slow => '遅い';

  @override
  String get noResults => '結果がありません';

  @override
  String get timedOut => 'タイムアウト';

  @override
  String get blocked => 'ブロックされました';

  @override
  String get notUsable => '使用できません';

  @override
  String get openThisSource => 'このソースを開く';

  @override
  String nameRemovedFromSearch(String name) {
    return '$name が検索結果から削除されました';
  }

  @override
  String connectLabel(String label) {
    return '接続 $label';
  }

  @override
  String scanToLogInWith(String label) {
    return 'ブラウザで\n$label をスキャンしてログインしてください';
  }

  @override
  String get anilist => 'アニメリスト';

  @override
  String get myAnimeList => 'MyAnimeList';

  @override
  String get simkl => 'シムクル';

  @override
  String get code => 'コード';

  @override
  String get signInToBackUpToCloud => 'クラウドへ戻る';

  @override
  String get signInToRestoreFromCloud => 'クラウドから復元';

  @override
  String get signInToUseThis => 'これを使う';

  @override
  String get enabled => '有効';

  @override
  String get disabled => '無効';

  @override
  String sourcesCount(int count) {
    return '$count ソース';
  }

  @override
  String removeRepoSemantic(String name) {
    return '$name、リポジトリを削除';
  }

  @override
  String repoDisplaySemantic(String name) {
    return '$name、';
  }

  @override
  String entryInstalledSemantic(String name, String state) {
    return '$name、 $state';
  }

  @override
  String repoSourcesCount(String name, int count) {
    return '$name、 $count ソース';
  }

  @override
  String repoRefreshSemantic(String name) {
    return '$name、更新';
  }

  @override
  String repoUpdateAllSemantic(String name, int count) {
    return '$name、すべて更新（$count）';
  }

  @override
  String repoRemoveSemantic(String name) {
    return '$name、削除';
  }

  @override
  String sourceUpdateSemantic(String name) {
    return '$name、更新';
  }

  @override
  String sourceUninstallSemantic(String name) {
    return '$name、アンインストール';
  }

  @override
  String sourceInstallSemantic(String name) {
    return '$name、インストール';
  }

  @override
  String sourceSettingsSemantic(String name) {
    return '$name、設定';
  }

  @override
  String sourceRemoveSemantic(String name) {
    return '$name、削除';
  }

  @override
  String sourceEnabledSemantic(String name, String state) {
    return '$name、 $state';
  }

  @override
  String titleInstalledCount(String title, int count) {
    return '$title、 $count 個インストール済み';
  }

  @override
  String titleCheckUpdatesSemantic(String title) {
    return '$title、アップデートを確認してください';
  }

  @override
  String titleRemoveRepoSemantic(String title) {
    return '$title、リポジトリを削除';
  }

  @override
  String titleApplyUpdatesSemantic(String title, String what) {
    return '$title、 $whatを適用';
  }

  @override
  String get oneUpdate => '1件の更新';

  @override
  String nUpdates(int count) {
    return '$count 件の更新';
  }

  @override
  String percentRead(int percent) {
    return '$percent% read';
  }

  @override
  String get couldntLoadDownloadOptions => 'ダウンロードオプションを読み込めませんでした';

  @override
  String selectedEpisodesOfTotal(int selected, int total) {
    return '$selected of $total episodes';
  }

  @override
  String episodeSemantic(int number) {
    return 'エピソード $number';
  }

  @override
  String get textColour => 'テキストの色';

  @override
  String get textOpacity => 'テキストの不透明度';

  @override
  String get outlineStyle => 'アウトラインスタイル';

  @override
  String get ownStylingKept => '独自のスタイルを持つ字幕は、スタイル付き字幕が有効な間そのまま表示されます';

  @override
  String get outlineColour => '輪郭の色';

  @override
  String get outlineWidth => 'アウトラインの幅';

  @override
  String get positionTop => '上';

  @override
  String get positionBottom => '底';

  @override
  String get subtitleSize => 'サイズ';

  @override
  String get colourWhite => '白';

  @override
  String get colourYellow => '黄色';

  @override
  String get colourGreen => '緑';

  @override
  String get colourRed => '赤';

  @override
  String get colourBlack => '黒';

  @override
  String get tapToDownloadFont => 'タップしてダウンロード';

  @override
  String get subtitleOutlineNone => 'なし';

  @override
  String get subtitleOutlineSoft => 'ソフトシャドウ';

  @override
  String get subtitleOutlineOutline => '概要';

  @override
  String get subtitleOutlineBold => '太字のアウトライン';

  @override
  String get subtitleOutlineShadow => 'ドロップシャドウ';

  @override
  String get subtitleOutlineGlow => '光る';

  @override
  String noSubtitlesFoundFor(String query) {
    return '「$query」の字幕は見つかりませんでした。';
  }

  @override
  String searchFailedWithError(String error) {
    return '検索失敗: $error';
  }

  @override
  String downloadFailedWithError(String error) {
    return 'ダウンロード失敗: $error';
  }

  @override
  String decreaseDelay(String label) {
    return '減少 $label';
  }

  @override
  String increaseDelay(String label) {
    return '増加 $label';
  }

  @override
  String alignedDelay(String offset) {
    return '整列済み $offset';
  }

  @override
  String get subtitleSyncVoiceCaptured =>
      '音声が録音されました✓ — 字幕が表示されるまで再生し、「字幕が表示されました」をタップしてください。（このシートは閉じても構いません。）';

  @override
  String get subtitleSyncTextCaptured =>
      '字幕がキャプチャされました ✓ — セリフが聞こえたら、「音声が聞こえます」をタップします。';

  @override
  String get subtitleSyncHint => '自動同期：セリフが聞こえたらタップし、字幕が表示されたらタップしてください。';

  @override
  String get voiceHeard => '声が聞こえる';

  @override
  String get subtitleSeen => '字幕が表示されました';

  @override
  String get contrast => '対比';

  @override
  String get saturation => '飽和';

  @override
  String get gamma => 'ガンマ';

  @override
  String get hue => '色相';

  @override
  String get drm => 'DRM';

  @override
  String get sourceFallback => 'ソース';

  @override
  String get expandAll => 'すべて展開';

  @override
  String downloadedSummary(int count, String size) {
    return '$count ダウンロード · $size';
  }

  @override
  String ofTotalDownloaded(int done, int total) {
    return ' $total件中$done 件';
  }

  @override
  String episodesDownloadedOfTotal(int done, int total) {
    return '$done / $total ダウンロード済み';
  }

  @override
  String removeAllEpisodesOfShow(int count, String title) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count episodes',
      one: '1 episode',
    );
    return 'このデバイスから「$title」のすべての $_temp0 を削除しますか？';
  }

  @override
  String get mangaChaptersYouDownloadAppearHere =>
      'ダウンロードしたマンガのチャプターはここに表示されます';

  @override
  String get parallelDownloadsSubtitle =>
      '同時にダウンロードできるエピソード数はいくつですか？チャプターは常に1つずつダウンロードされます。';

  @override
  String get connectionsPerDownloadSubtitle =>
      'エピソードで使用されるセグメント接続数と、チャプター内で一度に取得されるページ数。数値が大きいほど高速で、一度に取得されるデータ量が多くなります。';

  @override
  String get savingToYourFolder => 'フォルダに保存しています…';

  @override
  String get notAvailableOfflineYet => 'オフラインではまだ利用できません';

  @override
  String get downloadFileGone =>
      'That file is gone — it may have been deleted outside the app';

  @override
  String get downloadQueued => 'キューに登録';

  @override
  String get downloadPreparing => '準備中…';

  @override
  String get downloadFinalizing => 'Processing…';

  @override
  String downloadPausedProgress(int percent) {
    return '一時停止中 · $percent%';
  }

  @override
  String downloadProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String downloadProgressPercentOfSize(int percent, String size) {
    return '$percent%の $size';
  }

  @override
  String get downloadCanceled => 'キャンセル';

  @override
  String get downloadFailedStatus => '失敗した';

  @override
  String peerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count peers',
      one: '1 peer',
    );
    return '$_temp0';
  }

  @override
  String downloadSpeedMbps(String speed) {
    return '$speed MB/秒';
  }

  @override
  String downloadSpeedKbps(int speed) {
    return '$speed KB/秒';
  }

  @override
  String episodeWithTitleDot(int number, String title) {
    return 'E$number · $title';
  }

  @override
  String get mangaDownloads => 'マンガのダウンロード';

  @override
  String get novelDownloads => '小説のダウンロード';

  @override
  String get downloadingSection => 'ダウンロード中';

  @override
  String stopAllCount(int count) {
    return 'すべて停止 ($count)';
  }

  @override
  String clearFailedCount(int count) {
    return 'クリアに失敗しました（$count）';
  }

  @override
  String stopDownloadingBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count queued chapters',
      one: '1 queued chapter',
    );
    return 'キャンセル $_temp0。既にダウンロード済みのチャプターは保持されます。';
  }

  @override
  String clearedFailedCount(int count) {
    return 'クリア $count 失敗';
  }

  @override
  String chapterPagesProgress(int done, int total) {
    return '$done/$total ページ';
  }

  @override
  String showTitleQueued(String title) {
    return '$title · キューに追加済み';
  }

  @override
  String showTitleDownloading(String title) {
    return '$title · ダウンロード中…';
  }

  @override
  String showTitleWithError(String title, String error) {
    return '$title · $error';
  }

  @override
  String removeAllChaptersOfShow(int count, String title) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return 'このデバイスから「$title」のすべての $_temp0 を削除しますか？';
  }

  @override
  String chaptersWithSize(int count, String size) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return '$_temp0 · $size';
  }

  @override
  String get deleteAllEpisodesTooltip => 'すべてのエピソードを削除';

  @override
  String get deleteAllChaptersTooltip => 'すべての章を削除';

  @override
  String get cancelDownloadTooltip => 'キャンセル';

  @override
  String get removeDownloadTooltip => '取り除く';

  @override
  String get positionLabel => '位置';

  @override
  String get relativeTomorrow => '明日';

  @override
  String get scheduleSlotMorning => '朝';

  @override
  String get scheduleSlotAfternoon => '午後';

  @override
  String get scheduleSlotEvening => '夕方';

  @override
  String get scheduleSlotLateNight => '深夜';

  @override
  String get nothingAiringOnThisDay => 'この日は何も放送されません。';

  @override
  String get nothingReleasingOnThisDay => 'この日は何もリリースされません。';

  @override
  String get noneOfFollowedAirOnThisDay => 'あなたが観ているアニメは、この日はどれも放送されません。';

  @override
  String get scheduleAired => '放送済み';

  @override
  String get scheduleLive => '● ライブ';

  @override
  String get scheduleSoon => 'すぐ';

  @override
  String scheduleInHours(int hours) {
    return ' $hours時間';
  }

  @override
  String scheduleInDays(int days) {
    return ' ${days}d において';
  }

  @override
  String scheduleCountDot(int count, String noun) {
    return '・ $count $noun';
  }

  @override
  String get scheduleNounAiring => '放送中';

  @override
  String get scheduleNounReleasing => 'リリース';

  @override
  String seriesWithDate(String date) {
    return 'シリーズ · $date';
  }

  @override
  String movieWithDate(String date) {
    return '映画 · $date';
  }

  @override
  String todayWithDate(String date) {
    return '今日、 $date';
  }

  @override
  String extensionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count extensions',
      one: '1 extension',
    );
    return '$_temp0';
  }

  @override
  String get pasteRepoBaseUrlMihon =>
      'リポジトリのベースURLを貼り付けてください。アプリが自動的にインデックスファイルを見つけます。index.pbまたはindex.jsonへの直接リンクでも問題ありません。';

  @override
  String get pasteRepoBaseUrlAniyomi =>
      'リポジトリのベース URL を貼り付けてください。アプリが自動的に「/index.min.json」を追加します。';

  @override
  String get pasteRepoBaseUrlAniyomiTv =>
      'リポジトリのベース URL を貼り付けてください。アプリが自動的に「/index.min.json」を追加します。';

  @override
  String get pasteRepoIndexJsonUrl =>
      'リポジトリのindex.jsonのURLを貼り付けてください。これは、リポジトリ内のすべてのソースを一覧表示するJSONファイルであり、単一のプロバイダーの.js URLではありません。';

  @override
  String get pasteRepoIndexJsonUrlShort =>
      'リポジトリのindex.jsonファイルのURLを貼り付けてください。';

  @override
  String get pasteCloudStreamRepoUrlFull =>
      'CloudStreamリポジトリのURLを貼り付けてください。アプリはそこにリストされているすべてのソースを読み込みます。';

  @override
  String get youCanAddRepoBackLater => 'リポジトリは後で再度追加できます。';

  @override
  String get failedToLoad => '読み込みに失敗しました';

  @override
  String failedToLoadError(String error) {
    return '読み込みに失敗しました: $error';
  }

  @override
  String get noSourceLoaded =>
      'ソースが読み込まれませんでした。拡張機能に互換性がないか、ダウンロードに失敗した可能性があります。';

  @override
  String get repoAdded => 'リポジトリを追加しました。';

  @override
  String repoAddedWithSources(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sources',
      one: 'source',
    );
    return 'リポジトリが追加されました — $count $_temp0';
  }

  @override
  String repoAddedWithSourcesAvailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sources',
      one: 'source',
    );
    return 'リポジトリが追加されました — $count $_temp0 が利用可能です。必要なものをインストールしてください。';
  }

  @override
  String get upToDate => '最新の';

  @override
  String updatedNSources(int count) {
    return '更新されたソース： $count ';
  }

  @override
  String get enterManifestUrl => 'マニフェストURLを入力してください。';

  @override
  String get approve => '承認する';

  @override
  String get changePhoto => '写真を変更する';

  @override
  String get typingIsAPain => 'タイピングは面倒くさい？';

  @override
  String get dontHaveAnAccount => 'アカウントをお持ちではありませんか？';

  @override
  String get signUp => 'サインアップ';

  @override
  String get resetLinkSent => 'リセットリンクが送信されました。メール（迷惑メールフォルダも含む）をご確認ください。';

  @override
  String get codeExpired => 'コードの有効期限が切れました';

  @override
  String get somethingWentWrong => '問題が発生しました';

  @override
  String get pairingCodeTimedOut => 'ペアリングコードの有効期限が切れました。新しいコードを取得してください。';

  @override
  String get couldntStartPairing => 'ペアリングを開始できませんでした。接続を確認してください。';

  @override
  String get approvalFailed => '承認に失敗しました。もう一度お試しください。';

  @override
  String get pickAtLeastOneTracker => '接続済みのトラッカーを少なくとも1つ選択してください。';

  @override
  String get sendFailedTryAgain => '送信に失敗しました。もう一度お試しください。';

  @override
  String get signUpFailed => 'サインアップに失敗しました';

  @override
  String get invalidEmailOrPassword => 'メールアドレスまたはパスワードが無効です';

  @override
  String get authenticationFailed => '認証に失敗しました';

  @override
  String get couldNotReconnect => '再接続できませんでした';

  @override
  String get couldntUpdatePhoto => '写真を更新できませんでした';

  @override
  String welcomeToApp(String appName) {
    return ' $appNameへようこそ';
  }

  @override
  String onboardingTvSubtitle(String appName) {
    return '$appName にはソースコードは組み込まれていません。ご自身で追加してください。設定 → プロバイダーからいつでもリポジトリを追加し、インストールする項目を選択できます。';
  }

  @override
  String get onboardingPickEcosystem => 'ストリーミング、マンガ、小説の中からエコシステムを選んでください。';

  @override
  String get onboardingAddRepository => 'リポジトリのURLを貼り付けて追加します。';

  @override
  String get onboardingBrowseAndInstall => '閲覧して、必要なものをインストールしてください。';

  @override
  String get providersWaitingInSettings =>
      '今すぐソースを追加するか、まずは周辺情報を確認してみましょう。プロバイダーは設定画面でいつでも利用できます。';

  @override
  String get bufferSizeLow => '低（32MB）—低RAM / TV';

  @override
  String get bufferSizeDefault => 'デフォルト（128MB）';

  @override
  String get bufferSizeHigh => '高 (512 MB) — よりスムーズ';

  @override
  String get bufferLengthLow => '低（15秒）—低RAM / TV';

  @override
  String get bufferLengthDefault => 'デフォルト（60秒）';

  @override
  String get bufferLengthHigh => '高い（120秒）—より滑らか';

  @override
  String get bufferLengthMax => '最大（300秒）—最長';

  @override
  String nUpdatesAvailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count updates available',
      one: '1 update available',
    );
    return '$_temp0';
  }

  @override
  String languageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count languages',
      one: '1 language',
    );
    return '$_temp0';
  }

  @override
  String noExtensionsMatchQuery(String query) {
    return '「$query」に一致する拡張子はありません。';
  }

  @override
  String noCloudStreamReposAddedYetTap(String add) {
    return 'CloudStreamリポジトリはまだ追加されていません。\n $add をタップして追加してください。';
  }

  @override
  String noCloudStreamReposAddedYetPress(String add) {
    return 'CloudStreamリポジトリはまだ追加されていません。\n $add を押して追加してください。';
  }

  @override
  String noProvidersMatchQuery(String query) {
    return '「$query」に一致するプロバイダーはありません。';
  }

  @override
  String noInstalledProvidersMatchQuery(String query) {
    return 'インストールされているプロバイダーで「$query」に一致するものはありません。';
  }

  @override
  String noReposAddedYetTap(String add) {
    return 'リポジトリはまだ追加されていません。\n $add をタップして追加してください。';
  }

  @override
  String noReposAddedYetPress(String add) {
    return 'リポジトリはまだ追加されていません。\n $add を押して追加してください。';
  }

  @override
  String get showingEveryInstalledProvider => 'インストールされているすべてのプロバイダーを表示します';

  @override
  String get showingMangaNovelProviders => 'マンガと小説の提供元を表示しています';

  @override
  String get mangaNovelOnly => 'マンガと小説のみ';

  @override
  String get showAllProviders => 'すべて表示する';

  @override
  String get noMangaNovelProvidersInstalled => 'マンガ／小説配信サービスがインストールされていません。';

  @override
  String alreadyInstalledSourcesFromRepoStay(String name) {
    return '既にインストールされている「$name」のソースは、インストールされたままになります。';
  }

  @override
  String get pluginIndexPasteHelp =>
      'プラグインインデックスのURLを貼り付けてください。これは、プラグインエントリ（id、name、site、lang、version、url、iconUrl）のJSON配列です。';

  @override
  String get loadingTrailer => 'トレーラーに積み込み中…';

  @override
  String get trailerUnavailable => '予告編は利用できません';

  @override
  String get decoderHardwareRecommended => 'ハードウェア+（推奨）';

  @override
  String get decoderHardwareFaster => 'ハードウェア（より高速）';

  @override
  String get decoderSoftwareCompatible => 'ソフトウェア（最も互換性が高いもの）';

  @override
  String get decoderAuto => 'オート';

  @override
  String get rendererAutoRecommended => '自動（推奨）';

  @override
  String get rendererGpuStandard => 'GPU - 標準レンダラー';

  @override
  String get rendererGpuNextExperimental => 'GPU Next — Vulkan、実験的機能';

  @override
  String get rendererMediacodecEmbed => 'MediaCodec Embed — 黒い動画を修正';

  @override
  String get shaderStyleSharpenClean => 'シャープ化 - 1080pソースを鮮明化';

  @override
  String get shaderStyleDeblurSoft => 'ぼやけ除去 — ぼやけた/ソフトなソース';

  @override
  String get shaderStyleDenoiseGrainy => 'ノイズ除去 - 粒状/圧縮ノイズ';

  @override
  String get shaderTierMidLight => 'ミドルレンジGPU - 軽量でスムーズ';

  @override
  String get shaderTierHighHeavy => 'ハイエンドGPU - より重く、よりシャープ';

  @override
  String get closeConfirmDoubleBackLabel => '戻る — 戻るボタンを2回押して終了します';

  @override
  String get closeConfirmAskLabel => '最終確認 - 出発前に必ず確認してください';

  @override
  String get closeConfirmExitImmediatelyLabel => 'すぐに閉じて、すぐに退出してください。';

  @override
  String get zMode => 'Z Mode';

  @override
  String get zModeSubtitle =>
      'Browse from AniList and TMDB, play from your sources';

  @override
  String get metadata => 'Metadata';

  @override
  String get metadataSubtitle => 'Covers, titles and descriptions';

  @override
  String get animeMetadata => 'Anime metadata';

  @override
  String get animeMetadataSubtitle => 'Where anime and manga info comes from';

  @override
  String get videoMetadata => 'Movie & TV metadata';

  @override
  String get videoMetadataSubtitle => 'Where movie and series info comes from';

  @override
  String get malLoginForLists =>
      'Log in to MyAnimeList in Trackers to sync your lists';

  @override
  String get zModeExperimental => 'Experimental';

  @override
  String get modeAnime => 'Anime';

  @override
  String get modeMovieTv => 'Movie/TV';

  @override
  String sourceLabel(String name) {
    return 'Source: $name';
  }

  @override
  String get wrongTitle => 'Wrong title?';

  @override
  String get noSourceHasThisYet => 'No source has this yet';

  @override
  String get checkedTopSources => 'Checked your top sources — none had this';

  @override
  String get pickTheRightTitle => 'Pick the right title';

  @override
  String get searchThisSource => 'Search this source';

  @override
  String matchSaved(String name) {
    return 'Saved. Matched to $name now.';
  }

  @override
  String get chooseSource => 'Choose a source';

  @override
  String get whichOneIsIt => 'Which one is it?';

  @override
  String searchingSourceShort(String name) {
    return 'Searching $name';
  }

  @override
  String matchResultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count results',
      one: '1 result',
    );
    return '$_temp0';
  }

  @override
  String nothingOnSource(String name) {
    return 'Nothing on $name';
  }

  @override
  String get sourceMayNotCarryIt =>
      'This source may not carry it. Try another.';

  @override
  String get currentMatchBadge => 'CURRENT';

  @override
  String get scheduleAndLists => 'Schedule & lists';

  @override
  String get scheduleHubDesc => 'What is airing, day by day';

  @override
  String get trackerCoversVideo => 'Movies and series';

  @override
  String get listKindManga => 'Manga';

  @override
  String get listKindNovel => 'Novel';

  @override
  String get listKindAnimeDesc => 'Watching, completed, planning';

  @override
  String get listKindMangaDesc => 'Reading, completed, planning';

  @override
  String get listKindNovelDesc => 'Light novels on this account';

  @override
  String get sortPopularity => 'Popular';

  @override
  String get sortScore => 'Top rated';

  @override
  String get sortTrending => 'Trending';

  @override
  String get sortNewest => 'Newest';

  @override
  String get sortTitle => 'A-Z';

  @override
  String filtersNeedProvider(String provider) {
    return 'Filters need $provider. Switch it in Settings.';
  }

  @override
  String get format => 'Format';

  @override
  String get minimumScore => 'Minimum score';

  @override
  String get searchAnime => 'Search anime';

  @override
  String get searchMoviesTv => 'Search movies & TV';

  @override
  String get searchManga => 'Search manga';

  @override
  String get searchNovels => 'Search novels';

  @override
  String get adultCatalogue => 'Adult titles in catalogue';

  @override
  String get adultCatalogueSubtitle =>
      'Let AniList, MyAnimeList and TMDB return 18+ results';

  @override
  String get enableAdultCatalogue => 'Show adult titles?';

  @override
  String get enableAdultCatalogueBody =>
      'Search and browse may return 18+ titles from your metadata provider. Simkl has no such setting and is unaffected.';

  @override
  String get adultOnly => 'Adult';

  @override
  String get yourSavedAnimeList => 'Your saved anime list';

  @override
  String get yourSavedMangaList => 'Your saved manga list';

  @override
  String get yourSavedNovelList => 'Your saved novel list';

  @override
  String get epub => 'EPUB';

  @override
  String get exportAsEpub => 'Export as EPUB';

  @override
  String chaptersDownloadedCount(int done, int total) {
    return '$done of $total chapters downloaded';
  }

  @override
  String get noChaptersDownloadedToExport =>
      'No chapters downloaded yet — download some first.';

  @override
  String get allChapters => 'All chapters';

  @override
  String get startChapter => 'Start';

  @override
  String get endChapter => 'End';

  @override
  String get includeChapterNumber => 'Include chapter number';

  @override
  String get includeChapterNumberSubtitle =>
      '\"Chapter 5: Title\" instead of just \"Title\"';

  @override
  String get fileNameLabel => 'File name';

  @override
  String get folderLabel => 'Folder';

  @override
  String exportingChapterProgress(int done, int total) {
    return 'Chapter $done of $total';
  }

  @override
  String exportedToFolder(String folder) {
    return 'Exported to $folder';
  }

  @override
  String get epubExportFailed => 'Couldn\'t save the EPUB';

  @override
  String get export => 'Export';

  @override
  String get keepDownloadsPrivate => 'Keep downloads private';

  @override
  String get keepDownloadsPrivateSubtitle =>
      'New video downloads stay inside Zangetsu instead of the Downloads folder. They are deleted when you uninstall Zangetsu. Chapters and exports are unaffected.';

  @override
  String get mangaPageTranslationTitle => 'Translate page';

  @override
  String get mangaTranslationSourceLanguage => 'Source language';

  @override
  String get mangaTranslationTargetLanguage => 'Target language';

  @override
  String get mangaTranslationEngine => 'Engine';

  @override
  String get mangaTranslationSection => 'Translation';

  @override
  String get mangaTranslationSettings => 'Manga page translation';

  @override
  String get mangaTranslationProvider => 'Online provider';

  @override
  String get mangaTranslationGoogle => 'Google';

  @override
  String get mangaTranslationGemini => 'Gemini';

  @override
  String get mangaTranslationGroq => 'Groq';

  @override
  String get mangaTranslationApiKey => 'API key';

  @override
  String get mangaTranslationApiKeyTitle => 'Set API key';

  @override
  String get mangaTranslationApiKeyHint => 'Paste your provider API key';

  @override
  String get mangaTranslationAddApiKey => 'Add API key';

  @override
  String get mangaTranslationChangeApiKey => 'Change key';

  @override
  String get mangaTranslationRemoveApiKey => 'Remove API key';

  @override
  String get mangaTranslationApiKeySaved => 'API key saved securely';

  @override
  String get mangaTranslationApiKeyMissing =>
      'Add an API key for this provider to translate.';

  @override
  String get mangaTranslationProviderBillingNote =>
      'Only recognized text is sent to this provider. Usage may be subject to your provider account\'s limits and charges.';

  @override
  String get mangaTranslationInvalidApiKey =>
      'The provider rejected this API key. Check it and try again.';

  @override
  String get mangaTranslationRateLimited =>
      'The provider limit was reached. Check your provider account or try again later.';

  @override
  String get mangaTranslationProviderError =>
      'The provider could not translate this page. Check your connection and provider setup.';

  @override
  String get mangaTranslationInvalidResponse =>
      'The provider returned an unreadable translation. Try again.';

  @override
  String get mangaTranslationApiKeySaveFailed =>
      'Could not save the API key securely. Try again.';

  @override
  String get mangaTranslationOnline => 'Online';

  @override
  String get mangaTranslationOffline => 'Offline';

  @override
  String get mangaTranslationAction => 'Translate chapter';

  @override
  String get mangaTranslationTurnOff => 'Turn translation off';

  @override
  String get mangaTranslationRetryFailed => 'Retry failed pages';

  @override
  String get mangaTranslationContinue => 'Continue translation';

  @override
  String get mangaTranslationStop => 'Stop translation';

  @override
  String get mangaTranslationInProgress => 'Translating…';

  @override
  String get mangaTranslationSuccess => 'Translation ready';

  @override
  String get mangaTranslationError => 'Translation failed';

  @override
  String get mangaTranslationNoResult => 'No translation result was returned';

  @override
  String get mangaTranslationModelConsentTitle => 'Prepare translation?';

  @override
  String get mangaTranslationOnlineModelConsent =>
      'The on-device OCR component may need to download before this page can be read. The page image stays on your device. Online translation sends only recognized text to the translation service.';

  @override
  String get mangaTranslationOfflineModelConsent =>
      'On-device OCR and language models may need to download. The page image and recognized text stay on your device, and translation runs offline.';

  @override
  String get mangaTranslationDownloadingOcr => 'Downloading OCR';

  @override
  String get mangaTranslationDownloadingOfflineModels =>
      'Downloading OCR and translation models';

  @override
  String get mangaTranslationDownloadingMessage =>
      'This may take a little while. Translation will start automatically when the download finishes.';

  @override
  String get mangaTranslationRestartRequiredTitle => 'Restart required';

  @override
  String get mangaTranslationRestartRequiredMessage =>
      'Close and reopen Zangetsu to finish setting up on-device OCR, then try again.';

  @override
  String get mangaTranslationSearchLanguages => 'Search languages';

  @override
  String get mangaTranslationNoLanguages => 'No languages available';

  @override
  String get mangaTranslationNoLanguageMatch => 'No matching languages';

  @override
  String get mangaTranslationAppearance => 'Manga translation appearance';

  @override
  String get mangaTranslationAppearanceSubtitle =>
      'Text size, text colour and background';

  @override
  String get mangaTranslationBackgroundColour => 'Background colour';

  @override
  String get mangaTranslationBackgroundOpacity => 'Background opacity';

  @override
  String get mangaTranslationPreview => 'Translation preview';

  @override
  String get mangaTranslationAppearanceFitNote =>
      'Long text may scale down to stay inside its detected area and avoid overlap.';

  @override
  String get mangaTranslationShowOriginal => 'Show original page';

  @override
  String get mangaTranslationShowTranslations => 'Show translations';

  @override
  String get androidPlayerCache => 'Android player cache';

  @override
  String get androidPlayerCacheSummary => 'Optional memory and storage caching';

  @override
  String get androidPlayerCacheNote =>
      'Normal buffering is automatic; extra cache is separate. Applies to direct video streams in the experimental Android player. HLS/DASH keep their current buffering. Changes apply when you open the player again.';

  @override
  String get androidNativeCache => 'Extra memory cache';

  @override
  String get androidNativeCacheDescription =>
      'Extra read-ahead memory outside the Java heap. Limited by available device memory.';

  @override
  String get androidNativeCacheUnavailable =>
      'Native memory caching is unavailable on this device.';

  @override
  String get androidDiskCache => 'Storage cache';

  @override
  String get androidDiskCacheDescription =>
      'Reuse video data on phone storage. Old cached data is removed when the limit is reached. At least 512 MB of free storage is kept.';

  @override
  String get androidCacheClear => 'Clear playback cache';

  @override
  String get androidCacheClearBusy =>
      'Close the Android player before clearing its playback cache.';

  @override
  String get androidCacheUnavailable =>
      'Could not read the playback cache. Try opening this page again.';

  @override
  String get autoPlayerFallback => 'Auto-switch player';

  @override
  String get autoPlayerFallbackDescription =>
      'Experimental · Retry failed playback';

  @override
  String get ambientPlayer => 'Ambient player screen';

  @override
  String get ambientPlayerDescription =>
      'Tinted glow behind the portrait player, matched to the video';

  @override
  String get portraitVideoEdgeToEdge => 'Edge-to-edge portrait video';

  @override
  String get noChaptersAvailableFromThisSource =>
      'No chapters available from this source';

  @override
  String get selectShort => 'Select';

  @override
  String get cloudStreamEngine => 'CloudStream engine';

  @override
  String get trayStillRunningTitle => 'Zangetsu is still running';

  @override
  String get trayStillRunningBusy =>
      'Downloads keep going in the background. Open the app again from the tray icon.';

  @override
  String get trayStillRunningIdle => 'Open the app again from the tray icon.';

  @override
  String closeDownloadsInProgress(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloads in progress',
      one: '1 download in progress',
    );
    return '$_temp0';
  }

  @override
  String get closeQuitStopsDownloads =>
      'Quitting stops them. Keep Zangetsu running in the tray to let them finish.';

  @override
  String get quit => 'Quit';

  @override
  String get keepRunningInTray => 'Keep running in tray';

  @override
  String get verifyCheckingWebsite => 'Checking the website…';

  @override
  String get verifyLoadingWebsite => 'Loading the website…';

  @override
  String get verifyCompleteCheckBelow =>
      'Complete the check below. This window closes by itself once the site opens.';

  @override
  String get verifySignInBelow => 'Sign in below, then press Continue.';

  @override
  String verifyHost(String host) {
    return 'Verify $host';
  }

  @override
  String get checkingEllipsis => 'Checking…';

  @override
  String get reload => 'Reload';

  @override
  String shortcutAppSection(int n) {
    return 'Go to sidebar item $n';
  }

  @override
  String shortcutAppMode(int n) {
    return 'Switch to mode $n';
  }

  @override
  String shortcutShowTab(int n) {
    return 'Go to tab $n';
  }

  @override
  String get shortcutAppSettings => 'Open Settings';

  @override
  String get shortcutAppBack => 'Go back';

  @override
  String get shortcutAppFullscreen => 'Toggle full screen';

  @override
  String get shortcutAppHelp => 'Show keyboard shortcuts';

  @override
  String get shortcutAppLockProfile => 'Lock profile now';

  @override
  String get shortcutAppContextMenu => 'Open the menu for the focused item';

  @override
  String get shortcutHomeFirst => 'First item in the row';

  @override
  String get shortcutHomeLast => 'Last item in the row';

  @override
  String get shortcutHomeOpen => 'Open the focused title';

  @override
  String get shortcutShowPlay => 'Play or continue';

  @override
  String get shortcutShowDownload => 'Download the focused episode';

  @override
  String get shortcutShowFilter => 'Search episodes';

  @override
  String get shortcutShowSelectAll => 'Select all episodes';

  @override
  String get shortcutShowClearSelection => 'Clear the selection';

  @override
  String get shortcutPlayerPlayPause => 'Play / pause';

  @override
  String get shortcutPlayerSeekBack => 'Seek back';

  @override
  String get shortcutPlayerSeekForward => 'Seek forward';

  @override
  String get shortcutPlayerSeekBackLong => 'Seek back 1 minute';

  @override
  String get shortcutPlayerSeekForwardLong => 'Seek forward 1 minute';

  @override
  String get shortcutPlayerVolumeUp => 'Volume up';

  @override
  String get shortcutPlayerVolumeDown => 'Volume down';

  @override
  String get shortcutPlayerMute => 'Mute';

  @override
  String get shortcutPlayerExit => 'Leave full screen or the player';

  @override
  String get shortcutPlayerSkip => 'Skip intro or ending';

  @override
  String get shortcutPlayerSpeedDown => 'Slower';

  @override
  String get shortcutPlayerSpeedUp => 'Faster';

  @override
  String get shortcutPlayerSubtitles => 'Subtitles on / off';

  @override
  String get shortcutPlayerJumpPercent => 'Jump to 0-90%';

  @override
  String get shortcutPlayerFrameBack => 'Previous frame';

  @override
  String get shortcutPlayerFrameForward => 'Next frame';

  @override
  String get shortcutPlayerSubDelayDown => 'Subtitles earlier';

  @override
  String get shortcutPlayerSubDelayUp => 'Subtitles later';

  @override
  String get shortcutPlayerMiniPlayer => 'Mini player';

  @override
  String get shortcutPlayerAlwaysOnTop => 'Keep on top';

  @override
  String get shortcutReaderNextPage => 'Next page';

  @override
  String get shortcutReaderPreviousPage => 'Previous page';

  @override
  String get shortcutReaderFirstPage => 'First page';

  @override
  String get shortcutReaderLastPage => 'Last page';

  @override
  String get shortcutReaderChapterList => 'Chapter list';

  @override
  String get shortcutReaderToggleBars => 'Show or hide the bars';

  @override
  String get shortcutReaderBack => 'Leave the reader';

  @override
  String get shortcutReaderZoomIn => 'Zoom in';

  @override
  String get shortcutReaderZoomOut => 'Zoom out';

  @override
  String get shortcutReaderZoomReset => 'Reset zoom';

  @override
  String get shortcutReaderShiftSpread => 'Shift two-page spread';

  @override
  String get shortcutDownloadsDelete => 'Delete selected';

  @override
  String get shortcutDownloadsOpen => 'Open the focused download';

  @override
  String get shortcutListsSearch => 'Search the list';

  @override
  String get shortcutListsPreviousDay => 'Previous day';

  @override
  String get shortcutListsNextDay => 'Next day';

  @override
  String get shortcutSettingsNextSection => 'Next section';

  @override
  String get shortcutSettingsPreviousSection => 'Previous section';

  @override
  String get shortcutAppBackDescription =>
      'The mouse Back button also goes back';

  @override
  String get shortcutWhilePaused => 'While paused';

  @override
  String get shortcutListsSearchDescription => 'History and My List';

  @override
  String get noMatches => 'No matches';

  @override
  String get undo => 'Undo';

  @override
  String get catalogue => 'Catalogue';

  @override
  String get chooseCatalogue => 'Choose catalogue';

  @override
  String catalogueNamed(String name) {
    return 'Catalogue: $name';
  }

  @override
  String get open => 'Open';

  @override
  String get pauseAllDownloads => 'Pause all downloads';

  @override
  String get previous => 'Previous';

  @override
  String get shortcutNotSet => 'Not set';

  @override
  String extensionsFailedToLoad(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count extensions or plugins failed to load',
      one: '1 extension or plugin failed to load',
    );
    return '$_temp0';
  }

  @override
  String get someExtensionsDidNotLoad => 'Some extensions did not load';

  @override
  String get extensionSourcesMissingUntilLoad =>
      'Their sources are missing until they load.';

  @override
  String get everythingLoaded => 'Everything loaded.';

  @override
  String get sourceTimedOutSlow =>
      'Source timed out. It may be slow or down right now.';

  @override
  String get sourceTimedOutTitle => 'Source timed out';

  @override
  String get sourceTookTooLong =>
      'The source took too long to answer. It may be slow or down right now.';

  @override
  String get extensionEngine => 'Extension engine';

  @override
  String get installedExtensions => 'Installed extensions';

  @override
  String get startupEntry => 'Startup';

  @override
  String get aniyomiMihonEngine => 'Aniyomi / Mihon engine';

  @override
  String get extensionEngineNotFound =>
      'Extension engine not found. Re-extract the app folder.';

  @override
  String get downloadFinished => 'Download finished';

  @override
  String downloadNameIsReady(String name) {
    return '$name is ready';
  }

  @override
  String get downloadsFinished => 'Downloads finished';

  @override
  String downloadsAreReady(int count) {
    return '$count downloads are ready';
  }

  @override
  String downloadNameFailed(String name) {
    return '$name failed';
  }

  @override
  String downloadsCountFailed(int count) {
    return '$count downloads failed';
  }

  @override
  String downloadsFailedAndFinished(String failed, int count) {
    return '$failed, $count finished';
  }

  @override
  String get downloadFailed => 'Download failed';

  @override
  String get downloadsFailedTitle => 'Downloads failed';

  @override
  String episodeNumberLabel(String number) {
    return 'Episode $number';
  }

  @override
  String timeLeftSeconds(int seconds) {
    return '$seconds s left';
  }

  @override
  String timeLeftMinutes(int minutes) {
    return '$minutes min left';
  }

  @override
  String timeLeftHours(int hours) {
    return '$hours h left';
  }

  @override
  String timeLeftHoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min left';
  }

  @override
  String chapterIsOut(String number) {
    return 'Chapter $number is out';
  }

  @override
  String episodeIsOut(String number) {
    return 'Episode $number is out';
  }

  @override
  String get streamLinkAndHeadersCopied => 'Stream link and headers copied';

  @override
  String get streamLinkCopied => 'Stream link copied';

  @override
  String get couldNotCopyLink => 'Could not copy link';

  @override
  String get installFailNoSource =>
      'The extension installed but no source loaded';

  @override
  String get downloadCancelled => 'Download cancelled';

  @override
  String get installFailTimedOut =>
      'Download timed out: the connection is slow or blocked';

  @override
  String get installFailBlocked => 'Download blocked by network';

  @override
  String get installFailCertificate =>
      'Download blocked: the server certificate was rejected';

  @override
  String get installFailNotFound =>
      'Extension file not found in the repository (HTTP 404)';

  @override
  String installFailRefused(String status) {
    return 'Download refused by the server (HTTP $status)';
  }

  @override
  String installFailServerError(String status) {
    return 'Repository server error (HTTP $status)';
  }

  @override
  String get installFailEngineNotRunning => 'Extension engine not running';

  @override
  String get installFailNewerApp => 'Extension needs a newer app version';

  @override
  String get installFailEngineSlow =>
      'The extension engine took too long to load it';

  @override
  String get installFailNotLoaded => 'The extension could not be loaded';

  @override
  String get installFailDisk =>
      'Could not save the extension file (disk error)';

  @override
  String get installFailedPlain => 'Install failed';

  @override
  String trackerNeedsSignInSaved(String tracker) {
    return '$tracker needs you to sign in again. Updates are saved and will sync after you reconnect.';
  }

  @override
  String trackerSyncFailedRetry(String tracker) {
    return '$tracker sync failed. Updates are saved and will retry automatically.';
  }

  @override
  String get colourHex => 'Hex';

  @override
  String enterColourLike(String example) {
    return 'Enter a colour like $example';
  }

  @override
  String get pasteColour => 'Paste colour';

  @override
  String get whereToWatch => 'Where to watch';

  @override
  String get showInFolder => 'Show in folder';

  @override
  String get markAsUnread => 'Mark as unread';

  @override
  String get markAsUnwatched => 'Mark as unwatched';

  @override
  String get markAsWatched => 'Mark as watched';

  @override
  String get markThisAndAboveRead => 'Mark this and all above as read';

  @override
  String get markAllAboveWatched => 'Mark all above as watched';

  @override
  String get selectSourceText => 'Select source';

  @override
  String get rightClickToPinSource =>
      'Right-click a source, or hover it and click the pin, to keep it on top';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get showPassword => 'Show password';

  @override
  String get couldNotReadImageFile => 'Could not read that image file.';

  @override
  String get logOutLibraryStays =>
      'Log out? Your library stays in your account.';

  @override
  String logOutOfEmailLibraryStays(String email) {
    return 'Log out of $email? Your library stays in your account.';
  }

  @override
  String get everyDay => 'Every day';

  @override
  String get everyWeek => 'Every week';

  @override
  String get chooseAutoBackupFolder =>
      'Choose where automatic backups are saved';

  @override
  String get folderNoLongerExists => 'That folder no longer exists';

  @override
  String get howOften => 'How often';

  @override
  String get keepLabel => 'Keep';

  @override
  String get olderAutoBackupsDeleted => 'Older automatic backups are deleted.';

  @override
  String lastNBackups(int count) {
    return 'Last $count backups';
  }

  @override
  String get noAutoBackupYet => 'No automatic backup yet';

  @override
  String lastBackupAt(String when) {
    return 'Last backup: $when';
  }

  @override
  String get automaticBackups => 'Automatic backups';

  @override
  String get backUpAutomatically => 'Back up automatically';

  @override
  String get saveBackupOnSchedule => 'Save a backup to a folder on a schedule';

  @override
  String get notChosen => 'Not chosen';

  @override
  String get openFolder => 'Open folder';

  @override
  String lastN(int count) {
    return 'Last $count';
  }

  @override
  String get yourCloudBackup => 'Your cloud backup';

  @override
  String get backupFile => 'Backup file';

  @override
  String get restoreUndone =>
      'Restore undone. Your library and settings are back as they were.';

  @override
  String get restartNow => 'Restart now';

  @override
  String get savedBackups => 'Saved backups';

  @override
  String get noBackupsInFoldersYet => 'No backups in your backup folders yet.';

  @override
  String get lookingForBackups => 'Looking for backups…';

  @override
  String get automaticBackup => 'Automatic backup';

  @override
  String get safetyCopyBeforeRestore => 'Safety copy before a restore';

  @override
  String get backupKind => 'Backup';

  @override
  String get restore => 'Restore';

  @override
  String get backupIntroWindows =>
      'Save your sources, list and settings — to a file on this PC or to your Zangetsu account. Restoring adds your library back without deleting anything, replaces app settings, and saves a safety copy first so you can undo it.';

  @override
  String get sourcesAndReposText => 'Sources and repos';

  @override
  String backupCountSources(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sources',
      one: '1 source',
    );
    return '$_temp0';
  }

  @override
  String backupCountRepos(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count repos',
      one: '1 repo',
    );
    return '$_temp0';
  }

  @override
  String backupCountListItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count list items',
      one: '1 list item',
    );
    return '$_temp0';
  }

  @override
  String backupCountContinueWatching(int count) {
    return '$count in Continue Watching';
  }

  @override
  String backupCountReadingHistory(int count) {
    return '$count reading history';
  }

  @override
  String backupCountCategories(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count categories',
      one: '1 category',
    );
    return '$_temp0';
  }

  @override
  String backupCountResumePoints(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count resume points',
      one: '1 resume point',
    );
    return '$_temp0';
  }

  @override
  String backupCountSettingGroups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count setting groups',
      one: '1 setting group',
    );
    return '$_temp0';
  }

  @override
  String backupCountTitleMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hand-made title matches',
      one: '1 hand-made title match',
    );
    return '$_temp0';
  }

  @override
  String restoredParts(String parts) {
    return 'Restored: $parts';
  }

  @override
  String couldntReinstall(String items) {
    return 'Couldn\'t reinstall:\n$items';
  }

  @override
  String safetyCopyOfPreviousData(String path) {
    return 'Safety copy of your previous data: $path';
  }

  @override
  String get restartToSeeRestored =>
      'Restart Zangetsu to see the restored library and sources everywhere.';

  @override
  String get undoRestore => 'Undo restore';

  @override
  String get nothingSavedInPart => 'Nothing saved in this part';

  @override
  String get restoreThisBackup => 'Restore this backup?';

  @override
  String backupSourceDateUnknown(String source) {
    return '$source · date unknown';
  }

  @override
  String backupSourceMadeOn(String source, String date) {
    return '$source · made $date';
  }

  @override
  String get chooseWhatToRestore => 'Choose what to restore';

  @override
  String get settingsWillBeReplaced =>
      'Your current app settings will be replaced by the ones in this backup.';

  @override
  String get safetyCopySourcesNoUndo =>
      'A safety copy of your current library and settings is saved first, so you can undo those. Restored sources can\'t be undone.';

  @override
  String get safetyCopyUndoRestore =>
      'A safety copy of your current library and settings is saved first, so you can undo this restore.';

  @override
  String get notInThisBackup => 'Not in this backup';

  @override
  String markedChaptersAsUnread(int count) {
    return 'Marked $count chapters as unread';
  }

  @override
  String markedEpisodesAsUnwatched(int count) {
    return 'Marked $count episodes as unwatched';
  }

  @override
  String get filterChapters => 'Filter chapters';

  @override
  String noChaptersMatchQuery(String query) {
    return 'No chapters match \"$query\"';
  }

  @override
  String noEpisodesMatchQuery(String query) {
    return 'No episodes match \"$query\"';
  }

  @override
  String get selectChapters => 'Select chapters';

  @override
  String get clearFilter => 'Clear filter';

  @override
  String get clearSelectionEsc => 'Clear selection (Esc)';

  @override
  String countSelected(int count) {
    return '$count selected';
  }

  @override
  String get markRead => 'Mark read';

  @override
  String get markWatched => 'Mark watched';

  @override
  String get markUnread => 'Mark unread';

  @override
  String get markUnwatched => 'Mark unwatched';

  @override
  String get playTrailer => 'Play trailer';

  @override
  String get pauseTrailer => 'Pause trailer';

  @override
  String get unmute => 'Unmute';

  @override
  String tryAgainInSeconds(int seconds) {
    return 'Try again in ${seconds}s';
  }

  @override
  String get linkCopied => 'Link copied';

  @override
  String get copyTitle => 'Copy title';

  @override
  String get titleCopied => 'Title copied';

  @override
  String get openSourcePage => 'Open source page';

  @override
  String get shareViaWindows => 'Share via Windows';

  @override
  String sourceDoesntHaveTitle(String source) {
    return '$source doesn\'t have this title';
  }

  @override
  String get deleteDownloadQuestion => 'Delete download?';

  @override
  String downloadedFileWillBeDeleted(String label) {
    return 'The downloaded file for \"$label\" will be deleted.';
  }

  @override
  String get downloadDeleted => 'Download deleted';

  @override
  String get playOffline => 'Play offline';

  @override
  String get couldntFindDownloadedFile => 'Couldn\'t find the downloaded file';

  @override
  String get downloadAgain => 'Download again';

  @override
  String get dubbed => 'Dubbed';

  @override
  String get subbed => 'Subbed';

  @override
  String get existingDownloadedEpisodes => 'Existing downloaded episodes';

  @override
  String recoveredFilesQuestion(int count, String label) {
    return '$count selected episodes already have recovered local files. Their audio language is unknown. Use those files, or download the selected $label version?';
  }

  @override
  String get downloadSelectedVersion => 'Download selected version';

  @override
  String get useExistingFiles => 'Use existing files';

  @override
  String retryInSeconds(int seconds) {
    return 'Retry in ${seconds}s';
  }

  @override
  String get downloadThisLink => 'Download this link';

  @override
  String get couldNotCopyTitle => 'Could not copy title';

  @override
  String get couldNotOpenLink => 'Could not open the link';

  @override
  String get searchLinksHint => 'Search links (release, codec, addon)';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get sortLinks => 'Sort links';

  @override
  String get anyQuality => 'Any quality';

  @override
  String get noLinksMatchFilters => 'No links match these filters';

  @override
  String get otherQuality => 'Other';

  @override
  String get addonOrder => 'Addon order';

  @override
  String get largestFirst => 'Largest first';

  @override
  String get smallestFirst => 'Smallest first';

  @override
  String sourceTookTooLongNamed(String source) {
    return '$source took too long to answer. It may be slow or down right now.';
  }

  @override
  String sourceBlockedByCloudflare(String source) {
    return '$source blocked the search with a Cloudflare check. Open it from Sources to pass the check, then try again.';
  }

  @override
  String couldntReachSource(String source) {
    return 'Couldn\'t reach $source. Check your connection or try another source.';
  }

  @override
  String get couldntLoadMoreResults => 'Couldn\'t load more results.';

  @override
  String get loadMore => 'Load more';

  @override
  String retryFailedCount(int count) {
    return 'Retry failed ($count)';
  }

  @override
  String get movedToRecycleBin => 'Moved to the Recycle Bin';

  @override
  String queueCountDownloading(int count) {
    return '$count downloading';
  }

  @override
  String queueCountWaiting(int count) {
    return '$count waiting';
  }

  @override
  String queueCountPaused(int count) {
    return '$count paused';
  }

  @override
  String queueCountFailed(int count) {
    return '$count failed';
  }

  @override
  String get downloadQueue => 'Download queue';

  @override
  String get pauseAll => 'Pause all';

  @override
  String get resumeAll => 'Resume all';

  @override
  String get retryFailed => 'Retry failed';

  @override
  String episodeShort(String number) {
    return 'E$number';
  }

  @override
  String get finishingUp => 'Finishing up';

  @override
  String get findingASource => 'Finding a source';

  @override
  String get waitingToRetry => 'Waiting to retry';

  @override
  String get waitingForFreeSlot => 'Waiting for a free slot';

  @override
  String get downloadNext => 'Download next';

  @override
  String bulkDeleteShows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count shows',
      one: '1 show',
    );
    return '$_temp0';
  }

  @override
  String bulkDeleteDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloads',
      one: '1 download',
    );
    return '$_temp0';
  }

  @override
  String bulkDeleteAtLeast(String size) {
    return ' (at least $size)';
  }

  @override
  String bulkDeleteActiveCanceled(int count) {
    return ' $count still downloading will be canceled.';
  }

  @override
  String bulkDeleteRecycle(
    String shows,
    String items,
    String size,
    String active,
  ) {
    return 'Delete $shows and all $items$size from this PC? Finished files go to the Recycle Bin; unfinished downloads are removed.$active';
  }

  @override
  String bulkDeletePermanent(
    String shows,
    String items,
    String size,
    String active,
  ) {
    return 'Delete $shows and all $items$size from this PC? The saved files are removed and this cannot be undone.$active';
  }

  @override
  String get sortRecent => 'Recent';

  @override
  String get sortMostUnwatched => 'Most unwatched';

  @override
  String storageUsed(String size) {
    return '$size used';
  }

  @override
  String storageUsedFree(String used, String free) {
    return '$used - $free free';
  }

  @override
  String storageUsedFreeOnDrive(String used, String free, String drive) {
    return '$used - $free free on $drive';
  }

  @override
  String get showInExplorer => 'Show in Explorer';

  @override
  String get openShowPage => 'Open show page';

  @override
  String deleteNShows(int count) {
    return 'Delete $count shows';
  }

  @override
  String get deleteSelectedDownloadsRecycle =>
      'Delete the selected downloads? Finished files go to the Recycle Bin. Active downloads will be canceled.';

  @override
  String get deleteSelectedDownloadsPermanent =>
      'Delete the selected downloads and their saved files? Active downloads will be canceled.';

  @override
  String get notifyDownloadsFinishOrFail =>
      'Notify when downloads finish or fail';

  @override
  String get notifyDownloadsSubtitle =>
      'A Windows notification when a batch completes or something goes wrong.';

  @override
  String get taskbarProgressTitle =>
      'Show download progress on the taskbar button';

  @override
  String get taskbarProgressSubtitle =>
      'Fills the Zangetsu taskbar button and turns red if a download fails.';

  @override
  String get desktopParallelDownloadsNote =>
      'Applies right away: raising it starts waiting episodes now, and the rest of a season joins as each episode\'s source is found. Lowering it lets running downloads finish first.';

  @override
  String get desktopConnectionsPerDownloadNote =>
      'Direct-file and HLS episodes and manga pages use it. Hosts that can\'t split a file, DASH episodes and novel chapter images use one. Applies to downloads that start after the change.';

  @override
  String get dropFolderToImport => 'Drop a folder to import downloads from it.';

  @override
  String get scanningEllipsis => 'Scanning…';

  @override
  String scanningNFolders(int count) {
    return 'Scanning $count folders…';
  }

  @override
  String get folderNoLongerOnDisk => 'This folder is no longer on disk.';

  @override
  String get dropFoldersToImport => 'Drop folders to import their downloads';

  @override
  String get showFoldersAddedOrReconnected =>
      'Zangetsu show folders inside are added or reconnected.';

  @override
  String playEpisodeShort(int number) {
    return 'Play E$number';
  }

  @override
  String removedFromHistory(String title) {
    return 'Removed \"$title\" from History';
  }

  @override
  String get changeListStatusEllipsis => 'Change list status…';

  @override
  String get addToMyListEllipsis => 'Add to My List…';

  @override
  String get markAsFinished => 'Mark as finished';

  @override
  String get searchHistoryCtrlF => 'Search history (Ctrl+F)';

  @override
  String nothingInTabMatches(String query) {
    return 'Nothing in this tab matches \"$query\".';
  }

  @override
  String get previousFeature => 'Previous feature';

  @override
  String plusNMore(int count) {
    return '+$count more';
  }

  @override
  String refreshWithKeys(String keys) {
    return 'Refresh ($keys)';
  }

  @override
  String featuredTitleNofM(int index, int count) {
    return 'Featured title $index of $count';
  }

  @override
  String trackerNeedsSignInOpenSettings(String name) {
    return '$name needs you to sign in again. Open its settings to reconnect.';
  }

  @override
  String trackerLastSyncFailedRetry(String name) {
    return 'Last $name sync failed. It will retry automatically.';
  }

  @override
  String trackerUpdatesWaiting(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count updates waiting to sync to $name.',
      one: '1 update waiting to sync to $name.',
    );
    return '$_temp0';
  }

  @override
  String browseNGenres(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Browse $count genres',
      one: 'Browse 1 genre',
    );
    return '$_temp0';
  }

  @override
  String get removedFromContinueWatching => 'Removed from Continue watching';

  @override
  String get couldntRemoveFromContinueWatching =>
      'Couldn\'t remove from Continue Watching';

  @override
  String get removedFromContinueReading => 'Removed from Continue reading';

  @override
  String get couldntRemoveFromContinueReading =>
      'Couldn\'t remove from Continue Reading';

  @override
  String get cataloguesGroup => 'Catalogues';

  @override
  String get extensionsGroup => 'Extensions';

  @override
  String get readChapterFromStart => 'Read chapter from the start';

  @override
  String get markChapterRead => 'Mark chapter read';

  @override
  String get restartEpisode => 'Restart episode';

  @override
  String get markEpisodeWatched => 'Mark episode watched';

  @override
  String chapterNAvailable(String number) {
    return 'Chapter $number available';
  }

  @override
  String episodeNAvailable(String number) {
    return 'Episode $number available';
  }

  @override
  String openTrackerList(String tracker) {
    return 'Open $tracker list';
  }

  @override
  String get refreshF5 => 'Refresh (F5)';

  @override
  String get couldntLoadThisList => 'Couldn\'t load this list.';

  @override
  String get changeStatusEllipsis => 'Change status…';

  @override
  String get categoriesEllipsis => 'Categories…';

  @override
  String editOnTracker(String tracker) {
    return 'Edit on $tracker…';
  }

  @override
  String get trackerFallbackName => 'tracker';

  @override
  String get recentSearchesCleared => 'Recent searches cleared';

  @override
  String get fillInSearchBox => 'Fill in search box';

  @override
  String get noNewEpisodes => 'No new episodes';

  @override
  String get markAllRead => 'Mark all read';

  @override
  String get newEpisodesHeader => 'New episodes';

  @override
  String newChaptersCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count new chapters',
      one: '1 new chapter',
    );
    return '$_temp0';
  }

  @override
  String newEpisodesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count new episodes',
      one: '1 new episode',
    );
    return '$_temp0';
  }

  @override
  String get muted => 'Muted';

  @override
  String unmuteWithKey(String key) {
    return 'Unmute · $key';
  }

  @override
  String muteWithKey(String key) {
    return 'Mute · $key';
  }

  @override
  String get volumeTooltipKeys => 'Volume · ↑ / ↓   M to mute';

  @override
  String get keyboardShortcutsWithKey => 'Keyboard shortcuts · ?';

  @override
  String get subtitlesOn => 'Subtitles on';

  @override
  String get subtitlesOff => 'Subtitles off';

  @override
  String subtitleDelayMs(String delay) {
    return 'Subtitle delay ${delay}ms';
  }

  @override
  String openedInApp(String app) {
    return 'Opened in $app';
  }

  @override
  String couldNotStartApp(String app) {
    return 'Could not start $app';
  }

  @override
  String get aspectRatio => 'Aspect ratio';

  @override
  String get screenshot => 'Screenshot';

  @override
  String get copyStreamLink => 'Copy stream link';

  @override
  String get openInExternalPlayer => 'Open in external player';

  @override
  String get noExternalPlayerFound => 'No external player found';

  @override
  String get alwaysOnTop => 'Always on top';

  @override
  String get playerSettings => 'Player settings';

  @override
  String restoreWithKey(String key) {
    return 'Restore · $key';
  }

  @override
  String get installExternalPlayerHint =>
      'Install mpv, VLC or MPC-HC, then look again.';

  @override
  String get lookAgain => 'Look again';

  @override
  String get playerMayNotPlayHeaders =>
      'May not play: cannot send the headers this stream needs';

  @override
  String get uploadImageEllipsis => 'Upload image…';

  @override
  String get uploadGifEllipsis => 'Upload GIF…';

  @override
  String get searchGifsEllipsis => 'Search GIFs…';

  @override
  String get avatarGifTooLarge =>
      'This GIF is too large to optimize safely. Try a smaller file.';

  @override
  String get avatarImageTooLarge =>
      'This image is too large. Try a smaller file.';

  @override
  String get linkIsNotImage => 'That link is not an image.';

  @override
  String get couldNotDownloadImage => 'Could not download that image.';

  @override
  String get dropAvatarImageTypes => 'Drop a PNG, JPG, WebP or GIF image.';

  @override
  String get copyImageFirst => 'Copy an image first, then paste it here.';

  @override
  String get dropToUseAsAvatar => 'Drop to use as avatar';

  @override
  String get setPinToLock =>
      'Set a PIN for this profile to be able to lock it.';

  @override
  String get profileLockNeedsInternet =>
      'Connect to the internet to manage this profile lock. The PIN set on this PC keeps protecting it until then.';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get changePinEllipsis => 'Change PIN…';

  @override
  String get setPinEllipsis => 'Set PIN…';

  @override
  String get deleteProfile => 'Delete profile';

  @override
  String selectProfileNamed(String name) {
    return 'Select profile $name';
  }

  @override
  String get kidsProfile => 'Kids profile';

  @override
  String get pinProtected => 'PIN protected';

  @override
  String pressNToChoose(int key) {
    return 'Press $key to choose';
  }

  @override
  String get changeAvatarDropPaste =>
      'Change avatar (or drop / paste an image)';

  @override
  String get donate => 'Donate';

  @override
  String lockProfileWithKeys(String keys) {
    return 'Lock profile ($keys)';
  }

  @override
  String chapterNumberTitle(String number) {
    return 'Chapter $number';
  }

  @override
  String get markReadUpToHere => 'Mark read up to here';

  @override
  String get goToChapterOrSearch => 'Go to chapter or search titles';

  @override
  String get noChaptersMatch => 'No chapters match';

  @override
  String get spreadsShifted => 'Spreads shifted by one page';

  @override
  String get spreadsNotShifted => 'Spreads not shifted';

  @override
  String pageWidthPx(int width) {
    return 'Page width $width px';
  }

  @override
  String get noPreviousChapter => 'No previous chapter';

  @override
  String get noNextChapter => 'No next chapter';

  @override
  String pageNOfCount(int page, int count) {
    return 'Page $page / $count';
  }

  @override
  String chapterXOfY(String current, String total) {
    return '$current of $total';
  }

  @override
  String get markedReadUpToHere => 'Marked read up to here';

  @override
  String get shiftSpreadByOnePage => 'Shift spread by one page';

  @override
  String get pageWidthLongStrip => 'Page width (long strip)';

  @override
  String get copyImage => 'Copy image';

  @override
  String get saveToPictures => 'Save to Pictures';

  @override
  String get imageCopied => 'Image copied';

  @override
  String get copyFailed => 'Copy failed';

  @override
  String get filterByNumberOrTitle => 'Filter by number or title';

  @override
  String fontSerifNamed(String font) {
    return 'Serif ($font)';
  }

  @override
  String get searchFonts => 'Search fonts';

  @override
  String get searchTheWeb => 'Search the web';

  @override
  String get translate => 'Translate';

  @override
  String get finishedCaps => 'FINISHED';

  @override
  String get noNextChapterYet => 'No next chapter yet';

  @override
  String get upNextCaps => 'UP NEXT';

  @override
  String get clickToTurnPages => 'Click to turn pages';

  @override
  String scheduleSavedUpdating(String when) {
    return 'Showing saved schedule from $when · updating…';
  }

  @override
  String scheduleOfflineCopy(String when) {
    return 'Offline copy · showing saved schedule from $when';
  }

  @override
  String scheduleCouldntRefresh(String when) {
    return 'Couldn\'t refresh · showing saved schedule from $when';
  }

  @override
  String get couldntLoadSchedule => 'Couldn\'t load the schedule';

  @override
  String get scheduleServiceNoAnswer =>
      'The schedule service did not answer. Try again in a moment.';

  @override
  String get unpinSource => 'Unpin source';

  @override
  String get pinSource => 'Pin source';

  @override
  String searchAllSourcesFor(String query) {
    return 'Search all sources for \"$query\"';
  }

  @override
  String get moveToTop => 'Move to top';

  @override
  String get moveUp => 'Move up';

  @override
  String get moveDown => 'Move down';

  @override
  String get moveToBottom => 'Move to bottom';

  @override
  String get useInAutoResolve => 'Use in Auto Resolve';

  @override
  String unpinNamed(String name) {
    return 'Unpin $name';
  }

  @override
  String moveNamedUp(String name) {
    return 'Move $name up';
  }

  @override
  String moveNamedDown(String name) {
    return 'Move $name down';
  }

  @override
  String autoResolveSearchesNamed(String name) {
    return 'Auto Resolve searches $name';
  }

  @override
  String autoResolveSkipsNamed(String name) {
    return 'Auto Resolve skips $name. You can still pick it for a title.';
  }

  @override
  String dragToReorderNamed(String name) {
    return 'Drag to reorder $name';
  }

  @override
  String get skippedByAutoResolve => 'Skipped by Auto Resolve';

  @override
  String namePinned(String name) {
    return '$name, pinned';
  }

  @override
  String get pinnedStaysHereTooltip =>
      'Pinned: stays here. Unpinned sources below are sorted by what has worked.';

  @override
  String get someSpace => 'some space';

  @override
  String bucketCleared(String name) {
    return '$name cleared';
  }

  @override
  String bucketClearedFreed(String name, String size) {
    return '$name cleared ($size freed)';
  }

  @override
  String appUsesStorage(String size) {
    return 'Zangetsu uses $size on this PC, not counting downloads.';
  }

  @override
  String get measuringStorage => 'Measuring storage…';

  @override
  String get measuringEllipsis => 'Measuring…';

  @override
  String get storagePostersTitle => 'Posters and artwork';

  @override
  String get storagePostersDescription =>
      'Cover images. They download again when shown.';

  @override
  String get storageTempTitle => 'Video and reading cache';

  @override
  String get storageTempDescription =>
      'Temporary player, subtitle and manga page files. Posters are cleared too.';

  @override
  String get storageScriptsTitle => 'Source scripts';

  @override
  String get storageScriptsDescription =>
      'Downloaded provider scripts that sources run.';

  @override
  String get storageScriptsConfirmTitle => 'Clear source scripts?';

  @override
  String storageScriptsConfirmMessage(String size) {
    return 'This frees $size. Sources download their scripts again the next time you use them, so they will not work offline until then.';
  }

  @override
  String get storageExtensionsTitle => 'Extension data';

  @override
  String get storageExtensionsDescription =>
      'Installed extensions and their data. Clear removes only their cache; extensions and settings stay.';

  @override
  String get storageExtensionsConfirmTitle => 'Clear extension cache?';

  @override
  String storageExtensionsConfirmMessage(String size) {
    return 'Cached pages and images saved by extensions are removed. Installed extensions and their settings are kept. Extension data uses $size in total.';
  }

  @override
  String get storageLogsTitle => 'Logs';

  @override
  String get storageLogsDescription => 'Diagnostic logs used for bug reports.';

  @override
  String get storageLogsConfirmTitle => 'Clear logs?';

  @override
  String storageLogsConfirmMessage(String size) {
    return 'This frees $size. If something goes wrong right after, a bug report will have less to go on.';
  }

  @override
  String get storageDownloadsDescription => 'Downloaded episodes and chapters.';

  @override
  String get manage => 'Manage';

  @override
  String get discordOnlyWhileWatching => 'Only while watching';

  @override
  String get discordOnlyWhileWatchingSubtitle =>
      'Hide Browsing and Looking at. Your status also clears after 5 minutes away or while Zangetsu is minimised, but never during a video.';

  @override
  String get shortcutScopeEverywhere => 'Everywhere';

  @override
  String get shortcutScopeShowPage => 'Show page';

  @override
  String get shortcutScopeLists => 'History, My List and Schedule';

  @override
  String get resetAllShortcutsQuestion => 'Reset all shortcuts?';

  @override
  String get resetAllShortcutsMessage =>
      'Every changed shortcut goes back to its default key.';

  @override
  String get resetAll => 'Reset all';

  @override
  String get keyboardShortcuts => 'Keyboard shortcuts';

  @override
  String get noShortcutsMatch => 'No shortcuts match';

  @override
  String get searchShortcuts => 'Search shortcuts';

  @override
  String get changedFromDefault => 'Changed from default';

  @override
  String get changeShortcut => 'Change shortcut';

  @override
  String get pressNewKeyCombination => 'Press the new key combination';

  @override
  String currentShortcut(String keys) {
    return 'Current: $keys';
  }

  @override
  String shortcutAlreadyUsedBy(String action, String scope) {
    return 'Already used by \"$action\" ($scope). Saving keeps both on this key.';
  }

  @override
  String get customise => 'Customise';

  @override
  String titleBackOnAutoResolve(String title) {
    return '\"$title\" is back on Auto Resolve';
  }

  @override
  String titlesBackOnAutoResolve(int count) {
    return '$count titles are back on Auto Resolve';
  }

  @override
  String get couldntOpenSourcePage => 'Couldn\'t open this source\'s page';

  @override
  String resetNToAuto(int count) {
    return 'Reset $count to Auto';
  }

  @override
  String get resetToAuto => 'Reset to Auto';

  @override
  String get manualMatches => 'Manual matches';

  @override
  String get manualMatchesIntro =>
      'Titles you matched by hand with \"Wrong title?\". Reset one to let Auto Resolve choose its source again.';

  @override
  String get searchManualMatches => 'Search manual matches';

  @override
  String get clearSelection => 'Clear selection';

  @override
  String get noManualMatchesYet =>
      'No manual matches yet. Fix a match with \"Wrong title?\" on a title and it shows up here.';

  @override
  String get noManualMatchesForSearch => 'No manual matches match your search.';

  @override
  String get readerFullscreenWindowsSubtitle =>
      'When on, manga and novels open borderless full screen. Esc leaves it and F or F11 toggles it';

  @override
  String get clickToTurnPagesSubtitle =>
      'In paged reading, click the left or right side of the page to turn it and the middle to show the bars. The mouse Back and Forward buttons always turn pages';

  @override
  String get clickZones => 'Click zones';

  @override
  String get clickZonesSubtitle =>
      'What clicking each part of a page does when Click to turn pages is on';

  @override
  String get cacheAndStorage => 'Cache and storage';

  @override
  String get cacheAndStorageSubtitle =>
      'Sizes and clearing for every cache are in Storage';

  @override
  String get windowAndSystem => 'Window & system';

  @override
  String get windowAndSystemSubtitle =>
      'Launch at sign-in, close button, window size, start page';

  @override
  String get keyboardShortcutsSubtitle =>
      'See every shortcut and change the player keys';

  @override
  String get searchResults => 'Search results';

  @override
  String get tapZonesWindowsNote =>
      'On Windows these zones answer left clicks in paged reading while Click to turn pages is on. Right-to-left reading swaps the page-turn sides.';

  @override
  String get launchAtSignIn => 'Launch at sign-in';

  @override
  String get closeButton => 'Close button';

  @override
  String get rememberWindowSizePosition => 'Remember window size and position';

  @override
  String get startPage => 'Start page';

  @override
  String get autoLockAfterIdle => 'Auto-lock after idle';

  @override
  String get lockWhenWindowsLocks => 'Lock when Windows locks';

  @override
  String get unpinAllSourcesQuestion => 'Unpin all sources?';

  @override
  String unpinAllSourcesMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The $count pinned sources go back to the automatic ranking. Sources switched off for Auto Resolve stay off.',
      one:
          'The 1 pinned source goes back to the automatic ranking. Sources switched off for Auto Resolve stay off.',
    );
    return '$_temp0';
  }

  @override
  String get unpinAll => 'Unpin all';

  @override
  String get unpinnedAllSources => 'Unpinned all sources';

  @override
  String get sourcePriorityWindowsHelp =>
      'Drag a handle, use Move up / Move down, or press Alt+Up / Alt+Down on a selected row. Right-click a row for Move to top. Moving a source pins it: pinned sources keep their place, the rest are sorted by what has worked.';

  @override
  String get preferredSourceAnime => 'Preferred source for anime';

  @override
  String get preferredSourceManga => 'Preferred source for manga';

  @override
  String get preferredSourceNovels => 'Preferred source for novels';

  @override
  String get preferredSourceMoviesTv => 'Preferred source for movies and TV';

  @override
  String get autoResolve => 'Auto Resolve';

  @override
  String get preferredSourceDescription =>
      'Tried first for every title without its own source. If it does not have a title, Auto Resolve tries the sources below.';

  @override
  String get noPreferredSource => 'No preferred source: just the order below';

  @override
  String get preferredSourceSubtitle =>
      'Tried first. If it does not have a title, Auto Resolve tries the sources below.';

  @override
  String get manualMatchesRowSubtitle =>
      'Titles you matched by hand with Wrong title? They ignore the order on this page.';

  @override
  String trackerUpToDate(String name) {
    return '$name is up to date';
  }

  @override
  String trackerStillUnreachable(String name) {
    return 'Still could not reach $name. Will keep retrying.';
  }

  @override
  String trackerUpdatesSavedSuffix(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: ' $count updates are saved and will sync automatically.',
      one: ' 1 update is saved and will sync automatically.',
    );
    return '$_temp0';
  }

  @override
  String trackerLastTrySuffix(String when) {
    return ' Last try $when.';
  }

  @override
  String trackerNeedsSignIn(String name) {
    return '$name needs you to sign in again';
  }

  @override
  String get lastSyncFailed => 'Last sync failed';

  @override
  String get updatesWaitingToSync => 'Updates waiting to sync';

  @override
  String get loginExpiredOrRevoked => 'The login expired or was revoked.';

  @override
  String get noConnectionDot => 'No connection.';

  @override
  String get justNow => 'just now';

  @override
  String minutesAgoShort(int minutes) {
    return '$minutes min ago';
  }

  @override
  String hoursAgoShort(int hours) {
    return '$hours h ago';
  }

  @override
  String get signInExpired => 'Sign-in expired';

  @override
  String connectedToName(String name) {
    return 'Connected to $name';
  }

  @override
  String get closeAskWhenDownloading => 'Ask when downloads are running';

  @override
  String get closeTrayWhileDownloading =>
      'Keep running in the tray while downloading';

  @override
  String get closeAlwaysTray => 'Always keep running in the tray';

  @override
  String get closeAskDescription =>
      'Closing quits, but asks first if downloads would stop.';

  @override
  String get closeTrayWhileDownloadingDescription =>
      'Hides to the tray until downloads finish; otherwise quits.';

  @override
  String get closeAlwaysTrayDescription =>
      'Closing hides the window. Quit from the tray icon menu.';

  @override
  String get closeQuitDescription =>
      'Closing always quits, stopping any downloads.';

  @override
  String get startPageLastUsed => 'Where I left off';

  @override
  String afterNMinutes(int minutes) {
    return 'After $minutes minutes';
  }

  @override
  String get windowsSignInSettingRefused =>
      'Windows didn\'t allow changing the sign-in setting';

  @override
  String get couldntSaveWindowSetting => 'Couldn\'t save the window setting';

  @override
  String get closeButtonDescription =>
      'What the X button, Alt+F4 and the taskbar Close do.';

  @override
  String get startPageDescription =>
      'The page Zangetsu opens on. Applies the next time you start the app.';

  @override
  String get autoLockDescription =>
      'Lock a PIN-protected profile again when nobody has used the app for a while.';

  @override
  String get windowSection => 'Window';

  @override
  String get launchAtSignInSubtitle =>
      'Start Zangetsu when you sign in to Windows';

  @override
  String get rememberWindowSubtitle =>
      'Reopen where you left it, on the same screen. Off opens centred.';

  @override
  String get startPageSubtitle => 'The page shown when the app opens';

  @override
  String get newEpisodeAlertsWindowsSubtitle =>
      'Show a Windows notification when a show you follow gets a new episode or chapter';

  @override
  String get autoLockSubtitle =>
      'Locks a PIN-protected profile after no activity';

  @override
  String get lockWhenWindowsLocksSubtitle =>
      'Win+L or the screen lock also locks your profile';

  @override
  String get keyboardSection => 'Keyboard';

  @override
  String get collapseSidebar => 'Collapse sidebar';

  @override
  String get expandSidebar => 'Expand sidebar';

  @override
  String get syncingListProgress => 'Syncing your list and progress…';

  @override
  String get synced => 'Synced';

  @override
  String syncedAtClickToSync(String when) {
    return 'Synced at $when. Click to sync now';
  }

  @override
  String get syncOfflineTooltip =>
      'Offline: changes will sync when you are back online';

  @override
  String get signInToSyncListProgress =>
      'Sign in to sync your list and progress';

  @override
  String get syncFailedClickRetry => 'Sync failed. Click to retry';

  @override
  String syncFailedErrorClickRetry(String error) {
    return 'Sync failed: $error. Click to retry';
  }

  @override
  String get syncNow => 'Sync now';

  @override
  String lastSyncedAtClickToSync(String when) {
    return 'Last synced at $when. Click to sync now';
  }

  @override
  String get connectionSettingsUnavailable => 'Connection settings unavailable';

  @override
  String get connectToInternetTryAgain =>
      'Connect to the internet and try again.';

  @override
  String get clearSearchEsc => 'Clear search (Esc)';

  @override
  String sourceNoSiteToVerify(String name) {
    return '$name has no site to verify';
  }

  @override
  String verificationFailedError(String error) {
    return 'Verification failed: $error';
  }

  @override
  String get verificationNotCompleted => 'Verification was not completed';

  @override
  String verifiedTestingAgain(String name) {
    return 'Verified. Testing $name again…';
  }

  @override
  String get openSitePassCheckTestAgain =>
      'Open the site, pass its check, then test again';

  @override
  String get verify => 'Verify';

  @override
  String get refreshRepositoriesF5 => 'Refresh repositories (F5)';

  @override
  String get disable => 'Disable';

  @override
  String get collapse => 'Collapse';

  @override
  String get expand => 'Expand';

  @override
  String get eachCategorySavedSeparately =>
      'Each category is saved separately.';

  @override
  String get addAddon => 'Add addon';

  @override
  String get searchAddons => 'Search addons';

  @override
  String get addonUrl => 'Addon URL';

  @override
  String get openAppFolder => 'Open app folder';

  @override
  String get makeActiveSource => 'Make active source';

  @override
  String get installedUseMenu =>
      'Installed. Use the ... menu to update or uninstall';

  @override
  String get moreActions => 'More actions';

  @override
  String get installingEllipsis => 'Installing…';

  @override
  String updatedDoneOfTotal(int done, int total, int failed) {
    return 'Updated $done of $total. $failed failed';
  }

  @override
  String get updatesThatFailed => 'Updates that failed';

  @override
  String extensionsNotUpdated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count extensions not updated',
      one: '1 extension not updated',
    );
    return '$_temp0';
  }

  @override
  String get filledFromClipboard => 'Filled in from your clipboard';

  @override
  String get noRepoLinkInDrop => 'No repository link found in what you dropped';

  @override
  String get linkTakenFromDrop => 'Link taken from what you dropped';

  @override
  String get dropLinkHere => 'Drop the link here';

  @override
  String get youCanAlsoDragLink =>
      'You can also drag a link or a .json file here';

  @override
  String get appDataCouldNotOpen => 'Your app data could not be opened';

  @override
  String get appDataCouldNotOpenBody =>
      'Your previous files have been kept. Make sure the previous data folder or drive is available and there is enough free space, then try again.';

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowMaximize => 'Maximize';

  @override
  String downloadedEpisodesCount(int count) {
    return 'Downloaded episodes ($count)';
  }

  @override
  String get someDownloadsNotRemoved =>
      'Some downloads could not be removed. Please try again.';

  @override
  String get selectShowsToDelete => 'Select shows to delete';

  @override
  String selectNamed(String name) {
    return 'Select $name';
  }

  @override
  String get savedEpisodes => 'Saved episodes';

  @override
  String countActive(int count) {
    return '$count active';
  }

  @override
  String otherFilesAndAttempts(int count) {
    return 'Other files and previous attempts ($count)';
  }

  @override
  String get eachFileKeepsSource =>
      'Each file keeps its original source and audio information.';

  @override
  String get nextFeature => 'Next feature';

  @override
  String get newFromYourList => 'New from your list';

  @override
  String seeAllNamed(String title) {
    return 'See all $title';
  }

  @override
  String get openDownloads => 'Open downloads';

  @override
  String get verifyWebsite => 'Verify website';

  @override
  String get airingToday => 'Airing today';

  @override
  String get openTheShowPage => 'Open the show page';

  @override
  String get fullPlayer => 'Full player';

  @override
  String get fullPlayerDoubleClick => 'Full player · double-click';

  @override
  String get theatreMode => 'Theatre mode';

  @override
  String get exitTheatreMode => 'Exit theatre mode';

  @override
  String get fullScreenMode => 'Full screen';

  @override
  String get episodeRangeText => 'Episode range';

  @override
  String get searchTitlesEllipsis => 'Search titles...';

  @override
  String get checkingExtensionsForUpdates => 'Checking extensions for updates…';

  @override
  String get profilesAndAccount => 'Profiles & account';

  @override
  String watchingAsNameStatus(String name, String status) {
    return 'Watching as $name · $status';
  }

  @override
  String get sourcePriority => 'Source Priority';

  @override
  String get sourcePrioritySubtitle => 'Order Auto Resolve tries sources in';

  @override
  String get switchProfile => 'Switch profile';

  @override
  String get closePlayerToSwitchProfiles =>
      'Close the player to switch profiles.';

  @override
  String get clickProfileToWatchAs =>
      'Click a profile to watch as it. Locked profiles ask for their PIN.';

  @override
  String get windowsUpdates => 'Windows updates';

  @override
  String get windowsUpdatesSubtitle =>
      'Opens the latest Windows build changes on GitHub';

  @override
  String get playerOpensIn => 'Player opens in';

  @override
  String get playDownloadedCopyIfFails =>
      'Play downloaded copy if streaming fails';

  @override
  String get switchAutomatically => 'Switch automatically';

  @override
  String get askFirst => 'Ask first';

  @override
  String get adaptiveColour => 'Adaptive colour';

  @override
  String get appBackgroundColour => 'Background colour';

  @override
  String get titleLogoOnDetail => 'Title logo on Detail';

  @override
  String get appFont => 'App font';

  @override
  String get reverseEpisodeListAlwaysOn => 'Reverse episode list always on';

  @override
  String get openAppDataFolder => 'Open app data folder';

  @override
  String get openInFileExplorer => 'Open in File Explorer';

  @override
  String get appFontSubtitle => 'Everything in the app is drawn in this';

  @override
  String desktopSortChip(Object value) {
    return 'Sort: $value';
  }

  @override
  String get desktopMoreFilters => 'More filters';

  @override
  String desktopMoreFiltersCount(Object count) {
    return 'More filters ($count)';
  }

  @override
  String get desktopLibraryFiltersTooltip =>
      'Filters: season, minimum score, tags';

  @override
  String get desktopSourceFiltersTooltip => 'Filters: audio, sources to search';

  @override
  String get desktopQuickSearchResults => 'Quick search results';

  @override
  String get desktopAddRepoSubtitle => 'Works for every extension ecosystem';

  @override
  String get desktopRepoLinkLabel => 'Repository link';

  @override
  String get desktopRepoLinkHint => 'https://…';

  @override
  String get desktopMoreOptions => 'More options…';

  @override
  String get desktopEcosystemLabel => 'Ecosystem';

  @override
  String desktopOpenEcosystemManager(Object ecosystem) {
    return 'Open $ecosystem manager';
  }

  @override
  String desktopOpenEcosystemManagerMenu(Object ecosystem) {
    return 'Open $ecosystem manager…';
  }

  @override
  String get desktopManageSourcesInSettings => 'Manage in Settings';

  @override
  String get desktopSourcesManagedInSettings =>
      'Sources and their repositories are managed in Settings > Sources. Install some there and they will show up here.';

  @override
  String get desktopAllEcosystemsMenu => 'All ecosystems…';

  @override
  String get desktopSearchThisRepository => 'Search this repository';

  @override
  String get desktopSearchTitlesInSources => 'Search titles in these sources';

  @override
  String desktopSourceHasNoSettings(Object name) {
    return '$name has no settings';
  }

  @override
  String desktopPopularOn(Object source) {
    return 'Popular on $source';
  }

  @override
  String get desktopCouldntLoadRepository => 'Couldn\'t load this repository.';

  @override
  String get playerHardwareDecodeRetrying =>
      'Hardware decoding failed. Retrying in software.';

  @override
  String get floatingPlayerExpand => 'Open the full player';

  @override
  String get floatingPlayerClose => 'Close the mini player';

  @override
  String desktopSourceLacksTitleStayAuto(String source) {
    return '$source doesn\'t have this title, so it stays on Auto Resolve';
  }

  @override
  String desktopDownloadedCut(String cut) {
    return 'Downloaded · $cut';
  }

  @override
  String desktopPlayingDownloadedCut(String cut) {
    return 'Playing your downloaded $cut copy';
  }

  @override
  String desktopSliderDefaultValue(String value) {
    return 'Default: $value';
  }

  @override
  String get desktopDownloadsAtOnceUnit => 'at once';

  @override
  String desktopConnectionsUnit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'connections',
      one: 'connection',
    );
    return '$_temp0';
  }

  @override
  String desktopPagesAheadUnit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'pages ahead',
      one: 'page ahead',
    );
    return '$_temp0';
  }

  @override
  String desktopSecondsUnit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'seconds',
      one: 'second',
    );
    return '$_temp0';
  }

  @override
  String desktopSourcesUnit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sources',
      one: 'source',
    );
    return '$_temp0';
  }

  @override
  String get desktopEpisodesAlreadyDownloaded =>
      'These episodes are already downloaded.';

  @override
  String get desktopApproveInBrowserHint =>
      'Approve in your browser, then choose \"Open Zangetsu\". Click here to cancel.';
}
