import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../di/injector.dart';
import '../lnreader/lnreader_extension_service.dart';
import '../mihon/mihon_manager.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';

/// Watches only this source's inventory without opening storage or runtimes.
/// Cancellation releases manager and metadata listeners.
Stream<void> sourceInventoryEvents(String sourceId) {
  final subscriptions = <StreamSubscription<BoxEvent>>[];
  final removers = <VoidCallback>[];
  late StreamController<void> controller;
  void watchManager(Listenable manager, Object? Function() provider) {
    var previous = provider();
    void changed() {
      final current = provider();
      if (identical(previous, current)) return;
      previous = current;
      controller.add(null);
    }
    manager.addListener(changed);
    removers.add(() => manager.removeListener(changed));
  }
  void watchBox(String name, bool Function(Object?) relevant) {
    if (!Hive.isBoxOpen(name)) return;
    subscriptions.add(Hive.box<Map>(name).watch().listen((event) {
      if (relevant(event.key)) controller.add(null);
    }));
  }
  controller = StreamController<void>(sync: true, onListen: () {
    if (sourceId.startsWith('cs:') && sl.isRegistered<CloudStreamManager>()) {
      final manager = sl<CloudStreamManager>();
      watchManager(manager, () => manager.resolveCompatible(sourceId));
    } else if (sourceId.startsWith('ani:') && sl.isRegistered<AniyomiManager>()) {
      final manager = sl<AniyomiManager>();
      watchManager(manager, () => manager.get(sourceId));
    } else if (sourceId.startsWith('mihon:') && sl.isRegistered<MihonManager>()) {
      final manager = sl<MihonManager>();
      watchManager(manager, () => manager.get(sourceId));
    } else if (sourceId.startsWith('lnr:')) {
      watchBox(LnReaderExtensionService.boxName, (key) => key == sourceId.substring(4));
    } else {
      watchBox(ProviderRegistry.boxName,
        (key) => ProviderRegistry.sourceIdOf(key.toString()) == sourceId);
    }
  }, onCancel: () async {
    for (final remove in removers) { remove(); }
    for (final subscription in subscriptions) { await subscription.cancel(); }
  });
  return controller.stream;
}
