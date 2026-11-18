import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:dash0_flutter_sdk/src/vcs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start(
  Map<String, String> env, {
  Dash0VcsAttributes? vcs,
  bool disable = false,
  String? environment,
  String? deploymentName,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test-app',
      endpoint: testEndpoint,
      batchSize: 1,
      vcs: vcs,
      disableVcsDetection: disable,
      environment: environment,
      deploymentName: deploymentName,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
    buildEnvironment: env,
  );
  return (client, transport);
}

Object? res(Dash0Client c, String key) => attr(c.resource, key);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('detects vcs attributes from the build environment', () async {
    final (c, _) = await start({
      'DASH0_VCS_PROVIDER_NAME': 'github',
      'DASH0_VCS_OWNER_NAME': 'Lock128',
      'DASH0_VCS_REPOSITORY_NAME': 'app',
      'DASH0_VCS_REF_HEAD_NAME': 'main',
      'DASH0_VCS_REF_HEAD_REVISION': 'abc123',
      'DASH0_VCS_CHANGE_ID': '42',
    });
    expect(res(c, 'vcs.provider.name'), 'github');
    expect(res(c, 'vcs.owner.name'), 'Lock128');
    expect(res(c, 'vcs.repository.name'), 'app');
    expect(res(c, 'vcs.repository.url.full'), 'https://github.com/Lock128/app');
    expect(res(c, 'vcs.ref.head.name'), 'main');
    expect(res(c, 'vcs.ref.head.revision'), 'abc123');
    expect(res(c, 'vcs.change.id'), '42');
  });

  test('options win over the build environment', () async {
    final (c, _) = await start(
      {'DASH0_VCS_REF_HEAD_NAME': 'env', 'DASH0_VCS_CHANGE_ID': '7'},
      vcs: const Dash0VcsAttributes(refHeadName: 'manual'),
    );
    expect(res(c, 'vcs.ref.head.name'), 'manual');
    expect(res(c, 'vcs.change.id'), '7');
  });

  test('disableVcsDetection keeps manual values only', () async {
    final (c, _) = await start(
      {'DASH0_VCS_REF_HEAD_NAME': 'env', 'DASH0_VCS_CHANGE_ID': '7'},
      vcs: const Dash0VcsAttributes(refHeadRevision: 'sha'),
      disable: true,
    );
    expect(res(c, 'vcs.ref.head.revision'), 'sha');
    expect(res(c, 'vcs.ref.head.name'), isNull);
    expect(res(c, 'vcs.change.id'), isNull);
  });

  test('no vcs attributes without values', () async {
    final (c, _) = await start({});
    expect(res(c, 'vcs.provider.name'), isNull);
    expect(res(c, 'vcs.repository.url.full'), isNull);
  });

  test('derives provider, owner and repository from the url', () async {
    final (c, _) = await start({
      'DASH0_VCS_REPOSITORY_URL_FULL': 'https://gitlab.com/group/sub/proj.git',
    });
    expect(res(c, 'vcs.provider.name'), 'gitlab');
    expect(res(c, 'vcs.owner.name'), 'group');
    expect(res(c, 'vcs.repository.name'), 'proj');
    expect(res(c, 'vcs.repository.url.full'),
        'https://gitlab.com/group/sub/proj.git');
  });

  test('parses github, gitlab and bitbucket urls', () {
    expect(parseRepositoryUrl('https://github.com/a/b.git'),
        (provider: 'github', owner: 'a', repo: 'b'));
    expect(parseRepositoryUrl('https://bitbucket.org/a/b'),
        (provider: 'bitbucket', owner: 'a', repo: 'b'));
    expect(parseRepositoryUrl('https://example.com/a/b'), isNull);
    expect(parseRepositoryUrl('https://github.com/a'), isNull);
    expect(parseRepositoryUrl('nonsense'), isNull);
  });

  test('credentials are removed from the repository url', () async {
    expect(stripUserInfo('https://user:token@github.com/o/r.git'),
        'https://github.com/o/r.git');
    expect(stripUserInfo('https://github.com/o/r'), 'https://github.com/o/r');
    final (c, _) = await start({
      'DASH0_VCS_REPOSITORY_URL_FULL':
          'https://x-access-token:s3@github.com/o/r.git',
    });
    expect(res(c, 'vcs.repository.url.full'), 'https://github.com/o/r.git');
    expect(res(c, 'vcs.owner.name'), 'o');
    final (c2, _) = await start({},
        vcs: const Dash0VcsAttributes(
            repositoryUrlFull: 'https://u:p@example.com/o/r'));
    expect(res(c2, 'vcs.repository.url.full'), 'https://example.com/o/r');
  });

  test('vcs and deployment attributes appear on logs, spans and metrics',
      () async {
    final (c, t) = await start({
      'DASH0_VCS_REF_HEAD_REVISION': 'abc',
      'DASH0_DEPLOYMENT_ID': 'run-9',
    }, vcs: const Dash0VcsAttributes(refHeadName: 'main'));
    c.sendEvent('x');
    c.startSpan('s').end();
    c.counter('n').add(1);
    await c.flush();
    final bodies = [
      for (final s in t.sent) ...[
        for (final k in ['resourceLogs', 'resourceSpans', 'resourceMetrics'])
          if (s.body[k] != null) (s.body[k]! as List).first as Map,
      ],
    ];
    expect(bodies.length, greaterThanOrEqualTo(3));
    for (final b in bodies) {
      final r = b['resource']! as Map<String, Object?>;
      expect(attr(r, 'vcs.ref.head.name'), 'main');
      expect(attr(r, 'vcs.ref.head.revision'), 'abc');
      expect(attr(r, 'deployment.id'), 'run-9');
    }
  });

  test('environment and deployment fall back to dart-defines', () async {
    final env = {
      'DASH0_ENVIRONMENT': 'staging',
      'DASH0_DEPLOYMENT_NAME': 'dep',
      'DASH0_DEPLOYMENT_ID': '1',
    };
    final (c, _) = await start(env);
    expect(res(c, 'deployment.environment.name'), 'staging');
    expect(res(c, 'deployment.name'), 'dep');
    expect(res(c, 'deployment.id'), '1');
    final (c2, _) =
        await start(env, environment: 'prod', deploymentName: 'mine');
    expect(res(c2, 'deployment.environment.name'), 'prod');
    expect(res(c2, 'deployment.name'), 'mine');
    expect(res(c2, 'deployment.id'), '1');
  });
}
