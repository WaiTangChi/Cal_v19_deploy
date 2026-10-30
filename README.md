# Cal_v19_deploy

Repositorio de despliegue de Calypso 19.26.10.1. Contiene lo necesario para crear una instalación limpia de Calypso y desplegar en ella una versión concreta del código custom.

El código custom **no** está aquí: vive en `Cal_v19_custom`, que genera un `.cup` versionado y lo publica en Artifactory. Este repo decide qué `.cup` va a cada entorno y con qué configuración.

## Estructura

```
Cal_v19_deploy/
├─ install/
│  ├─ New-CalypsoInstall.ps1        # instalación limpia desatendida
│  └─ calypso-19.26.10.1.varfile    # plantilla del varfile de install4j
└─ README.md
```

Pendiente: configuración por entorno, plantillas de arranque y script de despliegue.

## Instalación limpia

```powershell
.\install\New-CalypsoInstall.ps1 -DestinationDir D:\calypso_v19\build-node
```

| Parámetro | Obligatorio | Por defecto |
|---|---|---|
| `-DestinationDir` | sí | — (no debe existir o debe estar vacío) |
| `-InstallerPath` | no | `D:\calypso_v19\dowloads\calypso-installer-19.26.10.1-win64-rel.exe` |
| `-VarFileTemplate` | no | `install\calypso-19.26.10.1.varfile` |
| `-JdbcDriverFiles` | no | el valor `jdbcDriverFiles` de la plantilla (rutas separadas por `;`) |

El script:
1. Comprueba el instalador, los drivers JDBC y que el destino esté vacío.
2. Genera un varfile temporal con `sys.installationDir` = destino (formato install4j: `D\:\\ruta\\...`).
3. Ejecuta el instalador con `-q -varfile <temporal>` y comprueba el código de salida.
4. Verifica que existen las carpetas básicas (`client\lib`, `server`, `tools\calypso-patcher`, …) y borra el varfile temporal.

Si falla, el log de install4j está en `<destino>\.install4j\installation.log`.

### Plantilla del varfile

- Define los componentes que se instalan (`sys.component.*`). Cualquier cambio aquí afecta a **todos** los entornos y al nodo de build.
- `sys.installationDir` lo sobrescribe el script: el valor de la plantilla no se usa.
- `jdbcDriverFiles` apunta a una ruta de la máquina original. En otra máquina hay que pasar `-JdbcDriverFiles`.
- Formato `.properties`: `\` se escribe `\\` y `:` se escribe `\:`.

## Flujo previsto

```
Build  (Cal_v19_custom)  instalación limpia → clone → bld.bat clean build createCup → .cup a Artifactory
Deploy (este repo)       instalación limpia → .cup de Artifactory → patch.sh -y --fast → local-deployer + config del entorno
```
