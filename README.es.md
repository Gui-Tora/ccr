# ccr

[English](README.md) · **Español**

Selector de sesiones de **Claude Code** y **Codex** para PowerShell. Lista todas tus conversaciones de todos los proyectos, eliges una y te lleva a su carpeta y la retoma.

Se acabó acordarse de en qué carpeta abriste aquel chat para poder hacer `/resume`.

![Pestaña de Claude Code](docs/claude.png)
![Pestaña de Codex](docs/codex.png)

## Características

- Sesiones de Claude Code y Codex en dos pestañas (`←` / `→`).
- Título, último prompt, carpeta y hace cuánto la usaste.
- Búsqueda instantánea por título, prompt o ruta (varias palabras = todas deben coincidir).
- `Enter` hace `cd` a la carpeta del proyecto y lanza `claude --resume <id>` o `codex resume <id>`.
- Rápido: lee solo el principio y el final de cada transcript y guarda una caché; solo relee lo que ha cambiado.
- Sin dependencias: un único script de PowerShell. Funciona en Windows PowerShell 5.1 y PowerShell 7.

## Instalación

```powershell
git clone https://github.com/Gui-Tora/ccr.git
cd ccr
.\install.ps1
```

Abre una terminal nueva y escribe `ccr`.

`install.ps1` solo añade esta línea a tu `$PROFILE` (y la sustituye si ya existía):

```powershell
function ccr { & "C:\ruta\a\ccr\ccr.ps1" @args }
```

> Si PowerShell no deja ejecutar scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

## Uso

```powershell
ccr              # abre el selector
ccr backend      # abre el selector ya filtrado
ccr -Refresh     # reconstruye la caché desde cero
ccr -Demo        # datos inventados, para capturas sin enseñar tus chats
```

| Tecla | Acción |
|---|---|
| escribir | filtrar |
| `←` `→` `Tab` | cambiar entre Claude Code y Codex |
| `↑` `↓` `RePág` `AvPág` `Inicio` `Fin` | moverse |
| `Enter` | ir a la carpeta y retomar la sesión |
| `Esc` | salir |

## De dónde saca los datos

| | Claude Code | Codex |
|---|---|---|
| Sesiones | `~/.claude/projects/*/<id>.jsonl` | `~/.codex/sessions/AAAA/MM/DD/rollout-*-<id>.jsonl` |
| Carpeta | campo `cwd` del transcript | `session_meta.cwd` |
| Título | `custom-title` → `ai-title` → último prompt | `session_index.jsonl` → primer mensaje |
| Último prompt | `last-prompt` | `history.jsonl` → último mensaje del usuario |

Respeta `CLAUDE_CONFIG_DIR` y `CODEX_HOME` si los tienes definidos. La caché vive en `%LOCALAPPDATA%\cc-sessions\`.

`ccr` solo **lee**: nunca modifica ni borra tus sesiones.

## Aviso

Lee formatos internos de Claude Code y Codex que no están documentados ni son estables. Si alguna actualización los cambia, puede que algo deje de salir hasta que se actualice el script.

## Desarrollo

`ccr.ps1` debe guardarse como **UTF-8 con BOM**: Windows PowerShell 5.1 lee los scripts sin BOM como ANSI y los caracteres como `→`, `─` o los acentos rompen el parseo. El `.editorconfig` ya lo configura para los editores que lo respetan.

## Licencia

MIT
