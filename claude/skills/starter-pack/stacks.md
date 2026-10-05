# Stacks

Per stack: Makefile, tool configs, values for the template placeholders, CI setup step, hook install. Every stack exposes
`setup`, `fmt`, `check` and `brief`, plus `lint` and `test` where the stack has them, so the hooks and CI call `make
check` and stay stack-neutral. Makefile recipes use a tab.

Every AGENTS.md command list also carries `make setup` (install dependencies and the hooks) and `make brief` (PR size
report against the base branch).

Placeholders filled from here:

| Placeholder | Where | Meaning |
|---|---|---|
| `{{TEST_PATTERN}}` | `scripts/pr-brief.sh` | awk regex of test paths, counted as tests |
| `{{DEPS_PATHSPEC}}` | `scripts/pr-brief.sh` | git pathspecs that flag a dependency change |
| `{{GROUP_DIRS}}` | `scripts/pr-brief.sh` | top-level dirs grouped one level deeper, joined with `\|` |
| `{{CONFIG_FILES}}` | `scripts/pr-brief.sh` | regex of the stack's lint and format configs, flagged as guardrails |
| `{{SETUP_STEPS}}` | `ci.yml` | the stack's setup steps; replace the whole line and indent every line of the steps by 12 spaces |
| `{{EDITORCONFIG_OVERRIDES}}` | `.editorconfig` | per-language overrides; delete the line when empty |
| `{{GENERATED_FILES}}` | `.gitattributes` | lock files and generated paths marked `linguist-generated` |
| `{{MODULE_PATH}}` | `.golangci.yml` | the module path in `go.mod` |
| `{{DEFAULT_BRANCH}}` | hooks, `ci.yml`, `pr-brief.sh`, docs | the default branch from step 1 |
| `{{REPO_NAME}}` | `docs/pull-requests.md` | the repo directory name |
| `{{SCOPE_EXAMPLE}}` | `.githooks/commit-msg` | a real feature folder or top-level source dir; `repo` when none |
| `{{PROJECT_NAME}}`, `{{PROJECT_SUMMARY}}` | `AGENTS.md` | from the README or `package.json`/`go.mod` name; ask the user when neither says |
| `{{FEATURE_ROOT}}` | `AGENTS.md` | the folder holding one module per feature (`internal`, `src`, `components`) |
| `{{COMMANDS}}` | `AGENTS.md` | the Makefile targets, one line each, from the stack's command lines below |
| `{{AREA_ONE}}`, `{{AREA_TWO}}` | `CONTEXT.md` | glossary groups; delete `{{AREA_TWO}}` when the code has one group |

The architecture.md prompts (`{{How this stack ...}}`, rules, readability limits, dependency examples) take the stack's
"Architecture values" below.

## Go

Reference: `/Users/compean/Development/pr-manager`. Copy `.golangci.yml` from there and change the module path and the
`internal/kernel` exclusions to match the repo.

Makefile:

```make
GOLANGCI := go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0

.PHONY: setup fmt lint test check brief

setup:
	git config core.hooksPath .githooks

fmt:
	$(GOLANGCI) fmt

lint:
	$(GOLANGCI) run

test:
	go test -race ./...

check: lint test
	go mod tidy -diff

brief:
	scripts/pr-brief.sh
```

`.golangci.yml`:

```yaml
version: "2"

formatters:
    enable:
        - gofumpt
        - goimports
    settings:
        goimports:
            local-prefixes:
                - {{MODULE_PATH}}

linters:
    default: standard
    enable:
        - errorlint
        - forbidigo
        - revive
        - unparam
        - varnamelen
    settings:
        forbidigo:
            analyze-types: true
            forbid:
                - pattern: ^time\.Now$
                  msg: inject the clock from internal/kernel
                - pattern: ^exec\.Command(Context)?$
                  msg: run processes through the runner in internal/kernel
        revive:
            rules:
                - name: argument-limit
                  arguments: [4]
                - name: function-result-limit
                  arguments: [3]
                - name: cyclomatic
                  arguments: [10]
                - name: max-control-nesting
                  arguments: [3]
                - name: early-return
                - name: indent-error-flow
                - name: superfluous-else
        varnamelen:
            min-name-length: 2
            max-distance: 1
            ignore-names:
                - i
                - j
                - k
            ignore-decls:
                - t *testing.T
    exclusions:
        rules:
            - path: (^|/)(internal/kernel|cmd)/
              linters:
                  - forbidigo
            - path: _test\.go$
              linters:
                  - forbidigo

issues:
    max-issues-per-linter: 0
    max-same-issues: 0
    uniq-by-line: false
```

Values:

- `{{TEST_PATTERN}}`: `_test\.go$|(^|\/)testdata\/`
- `{{DEPS_PATHSPEC}}`: `'go.mod'`
- `{{GROUP_DIRS}}`: `internal|cmd`
- `{{CONFIG_FILES}}`: `\.golangci\.yml`
- `{{SETUP_STEPS}}`:

```yaml
- name: Set up Go
  uses: actions/setup-go@v7
  with:
      go-version-file: go.mod
```

- `{{EDITORCONFIG_OVERRIDES}}`:

```
[{*.go,go.mod,Makefile}]
indent_style = tab
```

- `{{GENERATED_FILES}}`: `go.sum linguist-generated`
- Hooks: `make setup` runs `git config core.hooksPath .githooks`.
- `.gitignore`: nothing required.
- AGENTS.md command lines: `make setup` install the git hooks; `make fmt` format the code; `make lint` golangci-lint
  with the repo rules; `make test` go test -race; `make check` lint, test and go.mod drift: what CI and pre-push run;
  `make brief` PR size report.
- Architecture values: a module is a package and its interface is the exported names. Rules: exported names are the
  interface; policy apart from I/O; accept dependencies, do not create them; inject the clock and the process runner;
  return concrete types; no comments. Readability limits: `.golangci.yml` (4 arguments, 3 results, complexity 10,
  nesting 3, names of 2+ characters). Local-substitutable: databases, files, git repositories. True external:
  third-party APIs, the clock, notifications.

## TypeScript / pnpm

Reference: `/Users/compean/Development/job-finder` (a pnpm workspace with Prettier). The hooks install on `pnpm install`
through the `prepare` script.

Makefile:

```make
.PHONY: setup fmt lint test check brief

setup:
	pnpm install
	git config core.hooksPath .githooks

fmt:
	pnpm format

lint:
	pnpm -r --if-present run lint

test:
	pnpm -r --if-present run test

check:
	pnpm format:check
	pnpm -r --if-present run typecheck
	pnpm -r --if-present run lint
	pnpm -r --if-present run test

brief:
	scripts/pr-brief.sh
```

When the repo already pins `prettier`, keep its version. `--if-present` skips a script the repo lacks, in a single package and in a workspace alike. `package.json` scripts to add
(keep the repo's own `lint`, `typecheck` and `test`):

```json
{
    "scripts": {
        "prepare": "git config core.hooksPath .githooks || true",
        "format": "prettier --write .",
        "format:check": "prettier --check .",
        "pr:brief": "bash scripts/pr-brief.sh"
    },
    "devDependencies": {
        "prettier": "^3.9.9"
    }
}
```

`.prettierrc`:

```json
{
    "printWidth": 130,
    "tabWidth": 4,
    "useTabs": false,
    "singleQuote": true,
    "jsxSingleQuote": true,
    "semi": true,
    "trailingComma": "all",
    "bracketSpacing": true
}
```

`.prettierignore`:

```
node_modules/
dist/
build/
coverage/
.next/
pnpm-lock.yaml
docs/
.github/pull_request_template.md
.claude/
design/
```

Values:

- `{{TEST_PATTERN}}`: `\.(test|spec)\.|(^|\/)(tests?|e2e|__tests__)\/`
- `{{DEPS_PATHSPEC}}`: `'package.json' '*/package.json'`
- `{{GROUP_DIRS}}`: `apps|packages` for a workspace, `src` for a single package
- `{{CONFIG_FILES}}`: `\.prettierrc|\.prettierignore|eslint\.config\.[a-z]+`
- `{{SETUP_STEPS}}`:

```yaml
- name: Set up pnpm
  uses: pnpm/action-setup@v4

- name: Set up Node.js
  uses: actions/setup-node@v4
  with:
      node-version: 22
      cache: pnpm

- name: Install dependencies
  run: pnpm install --frozen-lockfile
```

- `{{EDITORCONFIG_OVERRIDES}}`: `[Makefile]` with `indent_style = tab`
- `{{GENERATED_FILES}}`: `pnpm-lock.yaml linguist-generated`, plus generated output such as migrations
- Hooks: the `prepare` script, or `make setup`.
- `.gitignore`: `node_modules/`, `dist/`, `coverage/`.
- AGENTS.md command lines: list only the targets whose scripts exist. `make setup` pnpm install and the git hooks;
  `make fmt` Prettier write; `make lint` the repo's `lint` script; `make test` the repo's `test` script; `make check`
  Prettier check plus the repo's typecheck, lint and test scripts that exist: what CI and pre-push run; `make brief` PR
  size report. Name a script that is missing as absent, never as a command.
- Architecture values: a module is a folder and its interface is its `index.ts` exports (the file other folders import when there is no `index.ts`). Rules: the exports are the
  interface; policy apart from I/O; accept dependencies, do not create them; inject the clock; return concrete types; no
  comments. Readability limits: the repo's ESLint config when it exists; otherwise write "Prettier only (`.prettierrc`)"
  and these review limits: 4 parameters, 3 results, complexity 10, nesting 3. Local-substitutable: databases, files.
  True external: third-party APIs, the clock, notifications.

## C / ESP-IDF

`uvx` runs a pinned clang-format with no install and needs network. `make check` format-checks, scans the pure
components and checks committed whitespace; builds need an ESP-IDF toolchain and stay out of CI. `SOURCES` reads
`git ls-files`: `git add` new `.c` and `.h` files before `make fmt` and `make check`.

Makefile:

```make
CLANG_FORMAT := uvx clang-format@23.1.2
SOURCES := $(shell git ls-files '*.c' '*.h')
PURE := components/spectrum components/hints

.PHONY: setup fmt check brief

setup:
	git config core.hooksPath .githooks

fmt:
	$(if $(SOURCES),$(CLANG_FORMAT) -i $(SOURCES))

check:
	$(if $(SOURCES),$(CLANG_FORMAT) --dry-run --Werror $(SOURCES))
	@! git grep -nE '#include [<"](esp_|freertos/|driver/|lvgl)' -- $(PURE) || { echo "Pure components stay pure C: no ESP-IDF, FreeRTOS or LVGL includes." >&2; exit 1; }
	git diff --check $$(git hash-object -t tree /dev/null) HEAD

brief:
	scripts/pr-brief.sh
```

`PURE` lists the repo's hardware-free components: the folders under `components/` whose sources include no ESP-IDF,
FreeRTOS, driver or LVGL header (`git grep -lE '#include [<"](esp_|freertos/|driver/|lvgl)' -- components`). Name those,
or delete the `PURE` line and the pure-include line of `check` when none exist.

`.clang-format`:

```yaml
BasedOnStyle: LLVM
IndentWidth: 4
ColumnLimit: 120
InsertBraces: true
AllowShortFunctionsOnASingleLine: None
AllowShortBlocksOnASingleLine: Never
```

Values:

- `{{TEST_PATTERN}}`: `(^|\/)(test|tests|host_test|test_apps)\/|(^|\/)test_[^\/]*\.c$`
- `{{DEPS_PATHSPEC}}`: `'*idf_component.yml'`
- `{{GROUP_DIRS}}`: `components`
- `{{CONFIG_FILES}}`: `\.clang-format`
- `{{SETUP_STEPS}}`:

```yaml
- name: Set up uv
  uses: astral-sh/setup-uv@v10.2.0
```

- `{{EDITORCONFIG_OVERRIDES}}`: `[Makefile]` with `indent_style = tab`
- `{{GENERATED_FILES}}`: `dependencies.lock linguist-generated`
- Hooks: `make setup` runs `git config core.hooksPath .githooks`.
- `.gitignore`: `build/`, `sdkconfig.old`, `managed_components/`.
- AGENTS.md command lines: `make setup` install the git hooks; `make fmt` clang-format the sources; `make check` format
  check, pure-component includes and whitespace: what CI and pre-push run; `make brief` PR size report. Add the `idf.py`
  build and test commands the repo documents.
- Architecture values: a module is a component and its interface is the functions its public headers declare (the
  functions other files call when there is no header). Rules: the public headers are the interface; policy apart from
  I/O; pure components include no ESP-IDF, FreeRTOS, driver or LVGL header; accept dependencies, do not create them;
  no comments. Readability limits: `.clang-format` (120 columns, 4-space indent, braces always); no linter runs, so add
  these review limits: 4 parameters, complexity 10, nesting 3. Local-substitutable: files, host-built unit tests.
  True external: hardware peripherals, the clock.

## Other stacks

Keep the same targets and let the standard tools fill them. `make check` is the one command CI and pre-push run: format
check, lint, tests, and a drift check for lock files and generated output.

| Stack | `fmt` | `lint` | `test` | drift in `check` | CI setup step |
|---|---|---|---|---|---|
| Python (uv) | `uv run ruff format .` | `uv run ruff check .` | `uv run pytest` | `uv lock --check` | `astral-sh/setup-uv@v10.2.0` |
| Rust | `cargo fmt` | `cargo clippy --all-targets -- -D warnings` | `cargo test` | `cargo fmt --check` | `dtolnay/rust-toolchain@stable` |
| Other | the formatter's write mode | the linter, warnings as errors | the test runner | the package manager's lock check | the stack's official setup action |

For each:

- `setup` installs dependencies, then runs `git config core.hooksPath .githooks`.
- `check` runs the formatter in check mode first, then lint, test and the drift check.
- Pin tool versions in the Makefile.
- Set the placeholders as above: the test-path regex, the manifest files, the top-level source dirs, the lint config
  names, the `.gitignore` entries and the architecture values (module, interface, rules, readability limits,
  dependency examples) from the stack's idioms.
- Resolve action tags with `gh api repos/<owner>/<action>/releases/latest --jq .tag_name` before pinning.
