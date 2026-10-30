# Cal_v19_deploy

Deployment repository for Calypso 19.26.10.1. It contains what is needed to create a clean Calypso installation, build the custom code into a `.cup`, and deploy a specific `.cup` version to each environment.

The custom code is **not** here: it lives in `Cal_v19_custom`. This repository builds it into a versioned `.cup` and decides which `.cup` goes to each environment and with which configuration.

## Layout

```
Cal_v19_deploy/
├─ build/
│  └─ Build-Cup.ps1                 # disposable build node -> .cup
├─ db/
│  ├─ oraclemeta.sql                # core schema: tablespace, user, grants (tokenized)
│  ├─ oracle_create_middle_tier.sql # middle-tier schema: tablespace, user, grants (tokenized)
│  └─ create_calypso_user.sql       # Calypso admin group and user (data inserts)
├─ deploy/
│  └─ Deploy-EnvProperties.ps1      # renders envProperties\ into %USERPROFILE%\Calypso
├─ envProperties/
│  └─ calypsouser.properties.<ENV>  # tokenized Calypso environment property files, one per environment
├─ install/
│  ├─ New-CalypsoInstall.ps1        # clean unattended installation
│  └─ calypso-19.26.10.1.varfile    # install4j varfile template (with tokens)
├─ lib/
│  ├─ Tokens.psm1                   # token loading and template rendering
│  └─ Processes.psm1                # process handling (wait, detect and stop processes using a folder)
├─ tokens/
│  ├─ tokens.BUILD
│  ├─ tokens.DEV
│  ├─ tokens.INT
│  ├─ tokens.PRE
│  └─ tokens.PRO
├─ secrets/                         # NOT versioned, except the template:
│  └─ tokens.DUMMY.secrets.example  # list of secret tokens every environment needs
└─ README.md
```

Pending: script to render and run the `db\` scripts, local-deployer configuration, startup templates and full deployment script.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Script execution allowed, e.g. `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`, or run with `powershell -ExecutionPolicy Bypass -File <script> ...`.

## Environments

| Environment | Purpose | `PORT_OFFSET` |
|---|---|---|
| `BUILD` | Disposable node used only to build the `.cup` | — |
| `DEV` | Development | 25000 |
| `INT` | Integration | 20000 |
| `PRE` | Pre-production | 15000 |
| `PRO` | Production | 10000 |

All of them can run side by side on the same machine because each one has its own database schemas and port offset (`calypso.deployment.port-offset`). The offset is added to every server port: with the current base ports (highest: gateway, 8080 + 720) every offset is valid, but the risk and position-keeping messaging base ports (61617, 61620, 62917…) would exceed 65535 with any offset above ~2600 if those components are enabled.

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
- Passwords and other secrets go only in `secrets\tokens.<ENV>.secrets`, never in `tokens\`. To create it, copy `secrets\tokens.DUMMY.secrets.example` to `secrets\tokens.<ENV>.secrets` and fill in every value.

### Escaping by file type

The value is escaped according to the format of the generated file, detected from its name:

| File name | Escaping | Example `jdbc:oracle:thin:@host:1521/PDB` |
|---|---|---|
| `*.varfile`, `*.properties`, `*.properties.<ENV>` | Java/install4j `.properties`: `\`→`\\`, `:`→`\:`, non-ASCII→`\uXXXX` | `jdbc\:oracle\:thin\:@host\:1521/PDB` |
| `*.xml` | XML: `& < > " '` | `jdbc:oracle:thin:@host:1521/PDB` |
| anything else | none | `jdbc:oracle:thin:@host:1521/PDB` |

Token values are therefore **always written unescaped**: `JDBC_URL=jdbc:oracle:thin:@localhost:11521/ORCLPDB1`, not `jdbc\:oracle\:...` (it would be escaped twice).

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
| `CALYPSO_USER_NAME` | `calypsouser.properties.<ENV>` | Calypso client user |
| `CALYPSO_USER_PASSWORD` | `calypsouser.properties.<ENV>` | Calypso client password (**secret**) |
| `JDBC_DRIVER` | `calypsouser.properties.<ENV>` | JDBC driver class |
| `JDBC_URL` | `calypsouser.properties.<ENV>` | JDBC URL (unescaped) |
| `DB_USER`, `DB_PASS` | `calypsouser.properties.<ENV>` | Core schema user / password (**secret**) |
| `DB_USER_MT`, `DB_PASS_MT` | `calypsouser.properties.<ENV>` | Middle-tier schema user / password (**secret**) |
| `PORT_OFFSET` | `calypsouser.properties.<ENV>` | `calypso.deployment.port-offset` |
| `DB_TABLESPACE` | `db\oraclemeta.sql` | Core schema tablespace |
| `DB_MT_USER`, `DB_MT_PASS`, `DB_MT_TABLESPACE` | `db\oracle_create_middle_tier.sql` | Middle-tier schema user / password (**secret**) / tablespace |

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

## Environment property files

```powershell
.\deploy\Deploy-EnvProperties.ps1 -Environment DEV
.\deploy\Deploy-EnvProperties.ps1 -Environment DEV, INT, PRE -WhatIf     # show what would change
```

For each environment `<ENV>` it renders every template in `envProperties\` whose name ends with `.<ENV>` using that environment's tokens, and writes it with the same name into `%USERPROFILE%\Calypso` (`-TargetDir` to change it):
- unchanged file → left as is;
- changed file → the previous version is kept as `<name>.<yyyyMMdd-HHmmss>.bak` and the file is replaced (the Calypso client may have saved settings into it, `SAVE_TO_FILE=true`);
- new file → created.

Everything is rendered before anything is written: if a token is missing in any template of any requested environment, the target folder is not touched. Rendered files contain passwords, so the temporary rendering folder is always deleted.

These files are what `-env <ENV>` reads, both in the deployed servers and in the IntelliJ run configurations of `Cal_v19_custom` (`.run\`).

## Database schemas (`db\`)

Templates to create the Oracle schemas of an environment, run as a privileged user **inside the PDB**, never in `CDB$ROOT`:

```sql
SHOW CON_NAME                              -- must show the PDB (e.g. ORCLPDB1), not CDB$ROOT
ALTER SESSION SET CONTAINER = ORCLPDB1;    -- if connected to the root
```

Creating a user in `CDB$ROOT` fails with `ORA-65096: invalid common user or role name`; the fix is switching to the PDB, not using a `C##` prefix.

| Script | Run as | Creates |
|---|---|---|
| `oraclemeta.sql` | `SYSTEM` / DBA, in the PDB | Core tablespace and user (`DB_USER`) |
| `oracle_create_middle_tier.sql` | `SYSTEM` / DBA, in the PDB | Middle-tier tablespace and user |
| `create_calypso_user.sql` | core schema owner, after the Calypso schema is created with ExecuteSQL | `admins` group and the Calypso application user |

There is no rendering script for these templates yet. The datafile path (`/opt/oracle/product/19c/dbhome_1/dbs/`) is the one of the current Oracle VM.

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

## Development installation

The full procedure to rebuild a development installation (clean install, source repository, IntelliJ, log folders, environment property files and local deployer) is in the README of `Cal_v19_custom`, section *Development installation from scratch*.

## Intended flow

```
Build  (Build-Cup.ps1)   clean installation → clone Cal_v19_custom → bld.bat clean build createCup → stored .cup
Deploy (pending)         clean installation → stored .cup → patch.sh -y --fast → local-deployer + environment configuration
```
