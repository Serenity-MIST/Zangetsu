import 'dart:io';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/repository/source_inventory_events.dart';
import '../../support/picker_deps.dart';

void main() {
  test('LNReader metadata events remain scoped without loading runtime', () => _fixture(() async {
    final service=LnReaderExtensionService(httpGet:(_) async=>'fixture JS');
    final manager=LnReaderManager(service:service,
      fetch:(_,_) async=>throw StateError('Runtime must stay lazy'));
    await manager.init();
    var count=0;
    final subscription=sourceInventoryEvents('lnr:fixture').listen((_)=>count++);
    try {
      final box=Hive.box<Map>(LnReaderExtensionService.boxName);
      await box.put('other',{'id':'other'}); await Future<void>.delayed(Duration.zero);
      expect(count,0);
      const meta=LnReaderPluginMeta(id:'fixture',name:'Fixture',site:'https://example.invalid',
        lang:'en',version:'1',url:'https://example.invalid/plugin.js',iconUrl:'');
      await service.install(meta); await Future<void>.delayed(Duration.zero);
      expect(count,1);
      await manager.uninstall('fixture'); await Future<void>.delayed(Duration.zero);
      expect(count,2); expect(manager.runtimeBuilt,isFalse);
    } finally { await subscription.cancel(); }
  }));

  test('Aniyomi provider changes ignore unrelated installs', () => _fixture(() async {
    final manager=sl<AniyomiManager>(); var count=0;
    manager.register(aniSource(id:1,name:'Target'));
    final subscription=sourceInventoryEvents('ani:1').listen((_)=>count++);
    try {
      manager.register(aniSource(id:2,name:'Other')); expect(count,0);
      manager.removeWhere((p)=>p.sourceId=='ani:1'); expect(count,1);
      manager.register(aniSource(id:1,name:'Replacement')); expect(count,2);
      await subscription.cancel();
      manager.removeWhere((p)=>p.sourceId=='ani:1'); expect(count,2);
    } finally { await subscription.cancel(); }
  }));

  test('Mihon provider replacement is scoped to selected source', () => _fixture(() async {
    final manager=MihonManager(); sl.registerSingleton<MihonManager>(manager);
    manager.register(mihonSource(id:1,name:'Target')); var count=0;
    final subscription=sourceInventoryEvents('mihon:1').listen((_)=>count++);
    try {
      manager.register(mihonSource(id:2,name:'Other')); expect(count,0);
      manager.register(mihonSource(id:1,name:'Replacement')); expect(count,1);
      manager.removeWhere((p)=>p.sourceId=='mihon:1'); expect(count,2);
    } finally { await subscription.cancel(); }
  }));

  test('CloudStream rebuild and removal notify catalogue observer', () => _fixture(() async {
    final manager=sl<CloudStreamManager>();
    // The raw test seam only rebuilds. Production load/reload notifies after
    // rebuilding; reproduce that boundary without invoking native engines.
    void rebuild(List<dynamic> rows) {
      manager.rebuildFromForTest(rows);
      // ignore: invalid_use_of_protected_member
      manager.notifyListeners();
    }
    rebuild([{'name':'Fixture','lang':'en','types':['Movie']}]);
    final id=manager.all.single.sourceId; var count=0;
    final subscription=sourceInventoryEvents(id).listen((_)=>count++);
    try {
      rebuild([]); expect(count,1);
      rebuild([{'name':'Fixture','lang':'en','types':['Movie']}]);
      expect(count,2);
    } finally { await subscription.cancel(); }
  }));

  test('registry inventory events are source-scoped and cancel safely', () async {
    final directory=await Directory.systemTemp.createTemp('source-events-');
    Hive.init(directory.path); await registerPickerDeps();
    final box=Hive.box<Map>(ProviderRegistry.boxName);
    var events=0;
    final subscription=sourceInventoryEvents('fixture').listen((_)=>events++);
    try {
      await box.put('other',{'name':'other'}); await Future<void>.delayed(Duration.zero);
      expect(events,0);
      final key=ProviderRegistry.providerKey('repo','fixture');
      await box.put(key,{'name':'fixture'}); await Future<void>.delayed(Duration.zero);
      expect(events,1);
      await box.delete(key); await Future<void>.delayed(Duration.zero);
      expect(events,2);
      await subscription.cancel();
      await box.put(key,{'name':'fixture'}); await Future<void>.delayed(Duration.zero);
      expect(events,2);
    } finally {
      await subscription.cancel(); await disposePickerDeps(); await sl.reset();
      await Hive.close(); await directory.delete(recursive:true);
    }
  });
}

/// Real isolated metadata stores; provider calls and native runtimes stay idle.
Future<void> _fixture(Future<void> Function() body) async {
  final directory=await Directory.systemTemp.createTemp('inventory-engine-');
  Hive.init(directory.path); await registerPickerDeps();
  try { await body(); }
  finally {
    await disposePickerDeps(); await sl.reset(); await Hive.close();
    await directory.delete(recursive:true);
  }
}
