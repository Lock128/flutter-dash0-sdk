import 'options.dart';
import 'semantic_conventions.dart' as sc;

/// Values passed with `--dart-define` at build time.
///
/// `String.fromEnvironment` is evaluated at compile time, so each key has to
/// be spelled out as a literal.
const Map<String, String> dash0BuildEnvironment = {
  'DASH0_ENVIRONMENT': String.fromEnvironment('DASH0_ENVIRONMENT'),
  'DASH0_DEPLOYMENT_NAME': String.fromEnvironment('DASH0_DEPLOYMENT_NAME'),
  'DASH0_DEPLOYMENT_ID': String.fromEnvironment('DASH0_DEPLOYMENT_ID'),
  'DASH0_VCS_PROVIDER_NAME': String.fromEnvironment('DASH0_VCS_PROVIDER_NAME'),
  'DASH0_VCS_OWNER_NAME': String.fromEnvironment('DASH0_VCS_OWNER_NAME'),
  'DASH0_VCS_REPOSITORY_NAME':
      String.fromEnvironment('DASH0_VCS_REPOSITORY_NAME'),
  'DASH0_VCS_REPOSITORY_URL_FULL':
      String.fromEnvironment('DASH0_VCS_REPOSITORY_URL_FULL'),
  'DASH0_VCS_REF_HEAD_NAME': String.fromEnvironment('DASH0_VCS_REF_HEAD_NAME'),
  'DASH0_VCS_REF_HEAD_REVISION':
      String.fromEnvironment('DASH0_VCS_REF_HEAD_REVISION'),
  'DASH0_VCS_CHANGE_ID': String.fromEnvironment('DASH0_VCS_CHANGE_ID'),
};

/// Accepted hosts per provider. The first host is the canonical one.
const Map<String, List<String>> _providerHosts = {
  'github': ['github.com', 'gist.github.com'],
  'gitlab': ['gitlab.com'],
  'bitbucket': ['bitbucket.org'],
};

String? _clean(String? v) {
  final t = v?.trim();
  return t == null || t.isEmpty ? null : t;
}

/// Returns the non-empty value of [key] in [env], or null.
String? buildEnv(Map<String, String> env, String key) => _clean(env[key]);

({String provider, String owner, String repo})? parseRepositoryUrl(
    String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;
  final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  String? provider;
  _providerHosts.forEach((p, hosts) {
    if (hosts.contains(host)) provider = p;
  });
  if (provider == null) return null;
  final path = uri.path.replaceFirst(RegExp(r'^/+'), '').replaceFirst(
        RegExp(r'\.git$'),
        '',
      );
  final segments = path.split('/');
  if (segments.length < 2) return null;
  final owner = segments.first;
  final repo = segments.last;
  if (owner.isEmpty || repo.isEmpty) return null;
  return (provider: provider!, owner: owner, repo: repo);
}

/// Resolves the `vcs.*` resource attributes. Precedence per field:
/// `options.vcs`, then the build environment unless
/// `options.disableVcsDetection`. Provider, owner and repository are derived
/// from the repository URL when missing, and the URL from them.
Map<String, String> resolveVcsAttributes(
  Dash0Options options,
  Map<String, String> env,
) {
  final o = options.vcs;
  final detect = !options.disableVcsDetection;
  String? pick(String? manual, String key) =>
      _clean(manual) ?? (detect ? buildEnv(env, key) : null);

  var provider = pick(o?.providerName, 'DASH0_VCS_PROVIDER_NAME');
  var owner = pick(o?.ownerName, 'DASH0_VCS_OWNER_NAME');
  var repo = pick(o?.repositoryName, 'DASH0_VCS_REPOSITORY_NAME');
  var url = pick(o?.repositoryUrlFull, 'DASH0_VCS_REPOSITORY_URL_FULL');
  final ref = pick(o?.refHeadName, 'DASH0_VCS_REF_HEAD_NAME');
  final revision = pick(o?.refHeadRevision, 'DASH0_VCS_REF_HEAD_REVISION');
  final change = pick(o?.changeId, 'DASH0_VCS_CHANGE_ID');

  final parsed = parseRepositoryUrl(url);
  if (parsed != null) {
    provider ??= parsed.provider;
    owner ??= parsed.owner;
    repo ??= parsed.repo;
  }
  if (url == null && provider != null && owner != null && repo != null) {
    final hosts = _providerHosts[provider];
    if (hosts != null) url = 'https://${hosts.first}/$owner/$repo';
  }

  return {
    if (provider != null) sc.vcsProviderName: provider,
    if (owner != null) sc.vcsOwnerName: owner,
    if (repo != null) sc.vcsRepositoryName: repo,
    if (url != null) sc.vcsRepositoryUrlFull: url,
    if (ref != null) sc.vcsRefHeadName: ref,
    if (revision != null) sc.vcsRefHeadRevision: revision,
    if (change != null) sc.vcsChangeId: change,
  };
}
