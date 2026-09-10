# Scripts de Automatizacion de Entorno (WAMP + PHP + Composer)

Esta carpeta contiene las herramientas para preparar y restaurar automaticamente el entorno de desarrollo en cualquier maquina con Windows y WAMP.

## Archivos

- **`setup_wamp_env.bat`**: Lanzador principal con auto-elevacion UAC (`fltmc`). Detecta WAMP, configura PHP 8.2 en el `PATH` (Sistema y Usuario), habilita extensiones obligatorias (`zip`, `gd`, `mbstring`, `curl`, `fileinfo`, `pdo_mysql`, `openssl`), verifica/crea la base de datos `tienda_virtual` y ofrece ejecutar `composer install`.
- **`setup_wamp_env.ps1`**: Script de PowerShell que orquesta la logica, desduplicacion de `PATH`, modificacion de `.ini` y snapshots de respaldo.
- **`rollback_wamp_env.bat`**: Herramienta de restauracion inmediata en un clic. Revierte el `PATH`, los archivos `.ini` y los perfiles de PowerShell al estado previo exacto anterior a los cambios.

## Uso

### Configurar Entorno
Doble clic en `setup_wamp_env.bat` o desde la terminal:
```cmd
.\scripts\setup_wamp_env.bat
```

### Revertir Cambios (Rollback)
Doble clic en `rollback_wamp_env.bat` o desde la terminal:
```cmd
.\scripts\rollback_wamp_env.bat
```
