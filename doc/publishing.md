# Publishing to pub.dev

## First publish (manual)

pub.dev only allows automated publishing after the package exists, so the first release is manual.

1. Check that `pubspec.yaml` has the right `version` and `CHANGELOG.md` has a matching `## <version>` heading.
2. Run `flutter analyze` and `flutter test`.
3. Run `dart pub publish --dry-run` and fix any warnings.
4. From a machine logged into pub.dev with the uploader account, run `flutter pub publish` (or `dart pub publish`).
   Publishing cannot be undone, so check the dry-run output first.

## Enable automated publishing

1. Open the package on pub.dev, go to the **Admin** tab, then **Automated publishing**.
2. Enable **Publishing from GitHub Actions**.
3. Set the repository to `Lock128/flutter-dash0-sdk` and the tag pattern to `v{{version}}`.
4. Optional: enter the GitHub environment name `pub.dev` and add required reviewers to that environment in the GitHub
   repository settings. `.github/workflows/publish.yml` already uses `environment: pub.dev`, so the environment is
   created on first use. If you enable it on pub.dev, the names must match.

The workflow `.github/workflows/publish.yml` runs on tags matching `v[0-9]+.[0-9]+.[0-9]+*`. It installs Flutter with
`subosito/flutter-action`, runs analyze and tests, then `flutter pub publish --force`, after checking that the tag matches the `pubspec.yaml` version and is on `main`, authenticating with OIDC
(`id-token: write`), so no secret is stored. The reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml`
is not used because it installs only the Dart SDK and cannot resolve the Flutter SDK dependency of this package.

## Release steps

1. Bump `version` in `pubspec.yaml` and `dash0SdkVersion` in `lib/src/client.dart`.
2. Add a `## <version>` section at the top of `CHANGELOG.md`.
3. Update the install snippet in `README.md` if the major or minor version changed.
4. Run `flutter analyze`, `flutter test` and `dart pub publish --dry-run`, then merge to `main`.
5. Tag and push: `git tag v<version> && git push origin v<version>`.

## Verified publisher

A package published by a personal account shows no publisher. To show a verified publisher, create one on pub.dev
(this needs a verified domain), then move the package with the **Admin** tab, **Publisher**. This is optional.
