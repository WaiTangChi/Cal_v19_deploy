# Cal_v19_deploy

Deployment repository for Calypso 19.26.10.1. It contains what is needed to create a clean Calypso installation, build the custom code into a `.cup`, and deploy a specific `.cup` version to each environment.

The custom code is **not** here: it lives in `Cal_v19_custom`. This repository builds it into a versioned `.cup` and decides which `.cup` goes to each environment and with which configuration.

## Layout

```
Cal_v19_deploy/
├─ build/
│  └─ Build-Cup.ps1                 # disposable build node -> .cup
├─ install/
│  ├─ New-CalypsoInstall.ps1        # clean unattended installation
│  └─ calypso-19.26.10.1.varfile    # install4j varfile template (with tokens)
├─ lib/
│  ├─ Tokens.psm1                   # token loading and template rendering
│  └─ Processes.psm1                # process handling (wait, detect and stop processes using a folder)
├─ tokens/
│  ├─ tokens.BUILD
│  ├─ tokens.DEV
│  ├─ tokens.PRE
│  └─ tokens.PRO
├─ secrets/                         # NOT versioned (only *.example)
└─ README.md
```

Pending: local-deployer configuration, startup templates and deployment script.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Script execution allowed, e.g. `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`, or run with `powershell -ExecutionPolicy Bypass -File <script> ...`.

## Per-environment tokens

Templates in this repository contain no environment values, only `@@@KEY@@@` markers. When a script runs with `-Environment <ENV>`, the markers are replaced with that environment's values.

### Load order

Each source overrides the previous one:

| Source | Mandatory | Versioned |
|---|---|---|
| `tokens\tokens.COMMON` | no | yes |
| `tokens\tokens.<ENV>` | **yes** | yes |
| `secrets\tokens.<ENV>.secrets` | no | **no** |
| `-TokenOverride @{ KEY = 'value' }` | no | — |

### Format

```properties
# comment
INSTALL_DIR=D:\calypso_v19\DEV
JDBC_DRIVER_FILES=D:\drivers\ojdbc8.jar;D:\drivers\other.jar
```
- `KEY`: only `A-Z`, `0-9` and `_`. A duplicate key in the same file is an error.
- `value`: everything after the first `=`, **literal**. Windows paths are written as-is, without escaping.
- An empty value counts as **not defined**.
- Passwords and other secrets go only in `secrets\tokens.<ENV>.secrets`, never in `tokens\`.

### Escaping by file type

The value is escaped according to the extension of the generated file:

| Extension | Escaping | Example `D:\calypso_v19\DEV` |
|---|---|---|
| `.varfile`, `.properties` | Java/install4j `.properties`: `\`→`\\`, `:`→`\:`, non-ASCII→`\uXXXX` | `D\:\\calypso_v19\\DEV` |
| `.xml` | XML: `& < > " '` | `D:\calypso_v19\DEV` |
| anything else | none | `D:\calypso_v19\DEV` |

### Errors

Rendering fails, without producing any output, if:
- a template uses a token that is not defined for the environment (all missing tokens are listed);
- any `@@@` remains unresolved, e.g. a token written in lowercase;
- `tokens\tokens.<ENV>` does not exist.

### Tokens in use

| Token | Used in | Description |
|---|---|---|
| `INSTALL_DIR` | varfile, `New-CalypsoInstall.ps1` | Calypso installation folder |
| `INSTALLER_PATH` | `New-CalypsoInstall.ps1` | Installer `calypso-installer-19.26.10.1-win64-rel.exe` |
| `JDBC_DRIVER_FILES` | varfile, `New-CalypsoInstall.ps1` | JDBC drivers, separated by `;` |
| `SOURCE_REPO_URL` | `Build-Cup.ps1` | Source repository (`Cal_v19_custom`) |
| `CUP_OUTPUT_DIR` | `Build-Cup.ps1` | Folder where `.cup` files are stored (temporary, until Artifactory is available) |

## Clean installation

```powershell
.\install\New-CalypsoInstall.ps1 -Environment DEV

# One-off different path:
.\install\New-CalypsoInstall.ps1 -Environment DEV -TokenOverride @{ INSTALL_DIR = 'D:\calypso_v19\other' }
```

The script:
1. Loads the environment tokens and checks that `INSTALL_DIR`, `INSTALLER_PATH` and `JDBC_DRIVER_FILES` are defined.
2. Checks that the installer and the JDBC drivers exist, and that the target folder does not exist or is empty.
3. Renders the varfile from `install\calypso-19.26.10.1.varfile` into a temporary file.
4. Runs the installer with `-q -varfile <temporary>` and checks the exit code.
5. Checks that the basic folders exist (`client\lib`, `server`, `tools\calypso-patcher`, …) and deletes the temporary varfile.

If it fails, the install4j log is at `<INSTALL_DIR>\.install4j\installation.log`.

The installer runs the installation's own Gradle several times (`installLibraries`, `createClientPackage`, `patch` of the JDBC driver…). By default Gradle leaves a daemon alive that locks installation files and makes `Start-Process -Wait` never return. Therefore the script:
- runs the installer with `-Dorg.gradle.daemon=false` added to `GRADLE_OPTS`, which the installer inherits;
- waits only for the installer process, not for its children;
- warns if any process is still using `INSTALL_DIR` when it finishes.

### Varfile template

- It defines the components to install (`sys.component.*`). Any change here affects **all** environments and the build node.
- Anything that depends on the environment or the machine is a token: `@@@INSTALL_DIR@@@` and `@@@JDBC_DRIVER_FILES@@@`.

## .cup build

```powershell
.\build\Build-Cup.ps1 -Ref develop     # branch -> X.Y.Z-SNAPSHOT
.\build\Build-Cup.ps1 -Ref v1.4.0      # tag    -> 1.4.0 (release)
```

It uses the `BUILD` environment (can be changed with `-Environment`). Steps:
1. If `INSTALL_DIR` holds a previous build node (with the `.calypso-build-node` marker), it is deleted. If it holds **anything else**, the script stops without touching it.
2. Installs a clean Calypso with `install\New-CalypsoInstall.ps1`, then stops any process the installer left using the node.
3. Replaces `custom-extensions\custom-projects` with a clone of `SOURCE_REPO_URL` at `-Ref` (`--depth 1`).
4. Runs `bld.bat clean build createCup --no-daemon` from `custom-extensions`. With `--no-daemon` no Gradle process is left locking files on deletion.
5. Validates the `.cup`:
   - it contains **exactly one** `*-rel.zip`;
   - tag `vX.Y.Z` → the `.cdf` version must be exactly `X.Y.Z`;
   - branch → the version must end with `-SNAPSHOT`.
6. Stores in `CUP_OUTPUT_DIR`:
   - `custom-projects-distribution-<version>.cup`
   - `custom-projects-distribution-<version>.cup.sha256`
   - `custom-projects-distribution-<version>.build-info.txt` (version, ref, commit, source, date, machine, sha256, files)

   A release version is **never overwritten**; a SNAPSHOT is.
7. Deletes the build node, also when something failed: it stops the processes using it and retries up to 5 times. With `-KeepInstall` it is kept for troubleshooting, and the next run deletes it.

Machine requirements: `git` in the PATH with SSH access to the source repository, a valid `JAVA_HOME` for Calypso's Gradle, and access to Maven (Maven Central or a proxy).

## Intended flow

```
Build  (Build-Cup.ps1)   clean installation → clone Cal_v19_custom → bld.bat clean build createCup → stored .cup
Deploy (pending)         clean installation → stored .cup → patch.sh -y --fast → local-deployer + environment configuration
```
