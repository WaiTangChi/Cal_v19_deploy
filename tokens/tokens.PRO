# Tokens for the PRO environment
# Format: KEY=value (literal value, Windows paths as-is). Empty value = not defined.
# No passwords here: they go in secrets\tokens.PRO.secrets (not versioned).

# --- Installation ---
INSTALL_DIR=D:\calypso_v19\PRO
INSTALLER_PATH=D:\calypso_v19\dowloads\calypso-installer-19.26.10.1-win64-rel.exe
# Paths separated by ';'
JDBC_DRIVER_FILES=D:\calypso_v19\dowloads\ojdbc8-23.26.3.0.0.jar
# Deployment
CALYPSO_USER_NAME=calypso_user
PORT_OFFSET=10000
# JDBC
JDBC_DRIVER=oracle.jdbc.driver.OracleDriver
JDBC_URL=jdbc:oracle:thin:@localhost:11521/ORCLPDB1
DB_USER=calypso_db_user
DB_USER_MT=calypso_mt_db_user