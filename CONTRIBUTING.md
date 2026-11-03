# Contributing

Work on a short-lived branch off `main`. Flutter 3.47.8 is managed with FVM (see `.fvmrc`); the backend and relay need Node 22.

## Checks

Before opening a pull request, run what CI runs:

```sh
fvm flutter analyze
fvm flutter test
npm --prefix functions run lint
npm --prefix functions run build
npm --prefix functions test
npm --prefix realtime test
python3 .github/workflows/check_doc_links.py
```

CI runs the same on every push to `main` and every pull request ([ci.yml](.github/workflows/ci.yml)): Flutter analyze and test, Functions lint, build, and test, relay tests, and the docs link check.

## Conventions

Follow [Development](docs/development.md) and the [style section](docs/architecture.md#style) of the client spec. Client lints come from `analysis_options.yaml` (`flutter_lints`, 80 columns).

## Docs

Code, docs, and UI copy are English. Keep links relative; every relative link is verified by the CI docs job, so check external URLs by hand.
