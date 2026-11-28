// A stand-in for the Java CloudStream engine, used by
// windows_cloudstream_first_link_test.dart. It is started in place of
// `java` (the test passes this script as the first "JVM option"), speaks the
// same one-JSON-line-per-message protocol over stdin/stdout, and needs no
// Java. Its first argument picks the engine generation:
//   events  a new engine: hello says linkEvents, a tagged loadLinks sends
//           link / subtitle / linksDone events, cancelLinks is known.
//   old     an engine from before link events: no flag, no events.
// Its loadLinks finds one link at once, a second after [_secondLinkMs], and
// answers at [_answerMs], like a provider with one quick and one slow mirror.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _secondLinkMs = 1500;
const _answerMs = 2500;

final _running = <String, void Function()>{};

void main(List<String> args) {
  final withEvents = args.isNotEmpty && args.first == 'events';
  // An optional second argument (not a Java option) is a file where each
  // cancelLinks tag is written, one per line, so a test can see it arrived.
  final cancelLog = args.length > 1 && !args[1].startsWith('-')
      ? File(args[1])
      : null;
  void send(Map<String, Object?> message) => stdout.writeln(jsonEncode(message));
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.trim().isEmpty) return;
        final request = jsonDecode(line) as Map<String, dynamic>;
        final id = request['id'];
        final params = (request['params'] as Map?) ?? const {};
        void reply(Object? result) => send({'id': id, 'result': result});
        switch (request['method']) {
          case 'hello':
            reply({'engine': 'fake', if (withEvents) 'linkEvents': true});
          case 'loadPlugin':
            reply({'providers': [], 'hasSettings': false});
          case 'setClearances':
            reply(0);
          case 'cancelLinks':
            cancelLog?.writeAsStringSync(
              '${params['tag']}\n',
              mode: FileMode.append,
              flush: true,
            );
            final stop = _running.remove('${params['tag']}');
            stop?.call();
            reply(stop != null);
          case 'loadLinks':
            _loadLinks(
              send,
              reply,
              '${params['data']}',
              withEvents ? params['tag'] as String? : null,
            );
          default:
            send({
              'id': id,
              'error': {'type': 'Unknown', 'message': 'no ${request['method']}'},
            });
        }
      }, onDone: () => exit(0));
}

/// One links call: links come over time; events only when tagged.
void _loadLinks(
  void Function(Map<String, Object?>) send,
  void Function(Object?) reply,
  String data,
  String? tag,
) {
  final links = <Map<String, Object?>>[];
  final timers = <Timer>[];
  var ended = false;
  Map<String, Object?> link(int n) => {
    'name': 'Mirror $n',
    'url': 'https://video.example/$data/$n.m3u8',
    'type': 'M3U8',
    'quality': 1080,
  };
  void found(int n) {
    final item = link(n);
    links.add(item);
    if (tag != null) send({'event': 'link', 'tag': tag, 'link': item});
  }

  void end({required bool completed}) {
    if (ended) return;
    ended = true;
    for (final timer in timers) {
      timer.cancel();
    }
    final subtitles = [
      {'lang': 'English', 'url': 'https://video.example/$data/en.vtt'},
    ];
    if (tag != null) {
      _running.remove(tag);
      send({
        'event': 'linksDone',
        'tag': tag,
        'completed': completed,
        'count': links.length,
      });
    }
    reply({
      'links': links,
      'subtitles': completed ? subtitles : [],
      'completed': completed,
      'error': null,
    });
  }

  if (tag != null) _running[tag] = () => end(completed: false);
  timers
    ..add(Timer(const Duration(milliseconds: 50), () => found(1)))
    ..add(Timer(const Duration(milliseconds: _secondLinkMs), () {
      found(2);
      if (tag != null) {
        send({
          'event': 'subtitle',
          'tag': tag,
          'subtitle': {
            'lang': 'English',
            'url': 'https://video.example/$data/en.vtt',
          },
        });
      }
    }))
    ..add(Timer(
      const Duration(milliseconds: _answerMs),
      () => end(completed: true),
    ));
}
