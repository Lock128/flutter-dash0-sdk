import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

// Pass with --dart-define=DASH0_URL=... --dart-define=DASH0_AUTH_TOKEN=...
const _url = String.fromEnvironment(
  'DASH0_URL',
  defaultValue: 'https://ingress.eu-west-1.aws.dash0.com',
);
const _token = String.fromEnvironment('DASH0_AUTH_TOKEN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_token.isNotEmpty) {
    try {
      await Dash0.init(
        Dash0Options(
          serviceName: 'dash0-flutter-example',
          serviceVersion: '1.0.0',
          environment: 'development',
          endpoint: const Dash0Endpoint(url: _url, authToken: _token),
          propagators: [
            Dash0Propagator.traceparent([RegExp(r'^https://example\.com')]),
          ],
          // Vitals, rage clicks and metrics are on by default. Profiling is
          // opt-in, so list everything that should be active.
          enabledInstrumentations: {
            ...Dash0Instrumentation.values,
          },
          // Record the replay of 100% of sessions in this example.
          sessionReplaySamplingRate: 100,
          replay: const Dash0ReplayOptions(
            screenshotInterval: Duration(seconds: 15),
          ),
          profiling: const Dash0ProfilingOptions(
            runtimeSampleInterval: Duration(seconds: 10),
          ),
        ),
      );
    } catch (e) {
      // Telemetry must never prevent the app from starting.
      debugPrint('Dash0 init failed: $e');
    }
  }

  // Reports uncaught asynchronous errors in addition to the handlers that
  // Dash0.init installs.
  Dash0.runGuarded(
      () => runApp(const Dash0ReplayBoundary(child: ExampleApp())));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFF6200EE),
      navigatorObservers: [Dash0.navigatorObserver],
      initialRoute: '/',
      onGenerateRoute: (settings) => PageRouteBuilder<void>(
        settings: settings,
        pageBuilder: (context, _, __) =>
            settings.name == '/' ? const HomePage() : const DetailsPage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final http.Client _client = Dash0.httpClient();
  String _status = 'idle';
  int _taps = 0;

  Future<void> _load() async {
    try {
      final response = await _client.get(Uri.parse('https://example.com'));
      setState(() => _status = 'HTTP ${response.statusCode}');
    } catch (e) {
      setState(() => _status = 'failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Status: $_status'),
          GestureDetector(
            onTap: _load,
            child: const Text('Send HTTP request'),
          ),
          GestureDetector(
            onTap: () => Dash0.sendEvent('button_clicked', title: 'Clicked'),
            child: const Text('Send custom event'),
          ),
          GestureDetector(
            onTap: () => Dash0.reportError(StateError('Example error')),
            child: const Text('Report error'),
          ),
          GestureDetector(
            // Counts as a metric; tapping it 3 times quickly sends an
            // browser.rage_click event.
            onTap: () {
              setState(() => _taps++);
              Dash0.counter('example.button.taps', unit: '{tap}').add(1);
            },
            child: Text('Count taps ($_taps)'),
          ),
          GestureDetector(
            // A span with frame and memory attributes.
            onTap: () => Dash0.profile('example.heavy_work', (span) async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }),
            child: const Text('Profile some work'),
          ),
          // Blanked in replay screenshots.
          const Dash0Mask(child: Text('Sensitive: 1234 5678')),
          GestureDetector(
            onTap: () => Navigator.of(context).pushNamed('/details'),
            child: const Text('Open details'),
          ),
        ],
      ),
    );
  }
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Details')),
    );
  }
}
