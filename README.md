# Xkiro API × pi-coding-agent Integration

> Documentación completa de la integración entre la **API de Xkiro** y el agente de codificación **[pi-coding-agent](https://github.com/earendil-works/pi-coding-agent)** (paquete `@earendil-works/pi-coding-agent`).

Este repositorio contiene todo lo necesario para que el comando `/model` de `pi` muestre los **40 modelos gratuitos** ofrecidos por Xkiro y permita cambiar entre ellos desde la TUI.

---

## Tabla de contenidos

- [Visión general](#visión-general)
- [Arquitectura](#arquitectura)
- [Requisitos previos](#requisitos-previos)
- [Instalación rápida](#instalación-rápida)
- [Configuración manual paso a paso](#configuración-manual-paso-a-paso)
- [El script setup_models.sh](#el-script-setup_modelssh)
- [Estructura del models.json](#estructura-del-modelsjson)
- [Catálogo de modelos gratuitos](#catálogo-de-modelos-gratuitos)
- [Uso desde la TUI](#uso-desde-la-tui-de-pi)
- [Persistir el modelo entre sesiones](#persistir-el-modelo-entre-sesiones)
- [Uso por línea de comandos (--model)](#uso-por-línea-de-comandos---model)
- [Troubleshooting](#troubleshooting)
- [Buenas prácticas y seguridad](#buenas-prácticas-y-seguridad)
- [Limitaciones conocidas](#limitaciones-conocidas)
- [Cómo actualizar los modelos](#cómo-actualizar-los-modelos)

---

## Visión general

**pi-coding-agent** (en adelante, *pi*) es un agente de IA para terminal. Para enviar prompts a un LLM necesita un *provider* configurado. La integración con Xkiro se hace mediante el mecanismo de **custom providers** que pi carga desde `~/.pi/agent/models.json`.

Xkiro expone un endpoint OpenAI-compatible (`/v1/chat/completions`) y un endpoint `/v1/models` que lista los modelos disponibles, indicando su `access_tier` (`free`, `pro`, etc.). Esto permite:

1. Descargar dinámicamente el catálogo de modelos.
2. Filtrar únicamente los que tengan `access_tier == "free"`.
3. Persistir la configuración resultante en `~/.pi/agent/models.json`.
4. Permitir que el usuario cambie de modelo con `/model` o con `pi --model <id>`.

### Resultado

- `pi` reconoce el provider `xkiro`.
- El menú `/model` lista los 40 modelos gratuitos.
- La API key se guarda una sola vez y se reutiliza.
- El script de setup es idempotente y se puede re-ejecutar.

---

## Arquitectura

```
Xkiro REST API (https://api.xkiro.com)
   GET /v1/models   POST /v1/chat/...
            |
            v  curl + Bearer token
   setup_models.sh
   - descarga modelos
   - filtra access_tier
   - genera JSON final
            |
            v  escribe
   ~/.pi/agent/
     models.json   (provider xkiro + 40 modelos)
     auth.json     (API key persistida)
     settings.json (defaultProvider opcional)
            |
            v  leído al iniciar / /model
   pi-coding-agent (TUI)  ->  /model -> selector
```

### Componentes

| Componente | Ubicación | Rol |
|---|---|---|
| `setup_models.sh` | `~/setup_models.sh` | Descarga y normaliza el catálogo |
| `models.json` | `~/.pi/agent/models.json` | Catálogo persistente que lee pi |
| `auth.json` | `~/.pi/agent/auth.json` | API key cacheada por pi |
| `xkiro_models.json` | `$HOME/xkiro_models.json` | Cache temporal |

---

## Requisitos previos

- **Termux** (o cualquier Linux/macOS con bash 4+).
- **pi-coding-agent** instalado globalmente:
  ```bash
  npm install -g @earendil-works/pi-coding-agent
  ```
- **curl** y **python3** disponibles en el PATH.
- Una **API key de Xkiro** con permisos para `/v1/models`.
- **gh** (opcional, sólo para clonar/empujar este repo).

---

## Instalación rápida

```bash
# 1. Clona este repo
git clone https://github.com/juanbas2005/xkiro-pi-integration.git
cd xkiro-pi-integration

# 2. Copia el script a tu HOME y dale permisos
cp setup_models.sh ~/setup_models.sh
chmod +x ~/setup_models.sh

# 3. Edita la API key dentro del script (variable API_KEY al inicio)
#    o pásala como variable de entorno (recomendado):
export XKIRO_API_KEY="sk-xt-..."

# 4. Ejecuta
bash ~/setup_models.sh

# 5. Lanza pi
pi
# dentro de la TUI: /model   y selecciona "xkiro / <modelo>"
```

Si todo fue bien, deberías ver al final del script:

```
✅ ~/.pi/agent/models.json actualizado con 40 modelos gratuitos
```

---

## Configuración manual paso a paso

Si prefieres no usar el script, puedes crear el archivo a mano.

### 1. Crea el directorio

```bash
mkdir -p ~/.pi/agent
```

### 2. Escribe `models.json`

Crea `~/.pi/agent/models.json` con este contenido (reemplaza la API key):

```json
{
  "providers": {
    "xkiro": {
      "baseUrl": "https://api.xkiro.com/v1",
      "api": "openai-completions",
      "apiKey": "sk-xt-TU_API_KEY_AQUI",
      "models": []
    }
  }
}
```

> **Importante:** el campo `apiKey` aquí es un *placeholder* que pi usa sólo para detectar que el provider requiere auth. La clave real se valida cuando pi intenta enviar un chat completion. Si tienes un servidor local sin auth, pon cualquier string (`"ollama"`, `"local"`, etc.) y usa `/login` o `--api-key`.

### 3. Llena `models` (o re-ejecuta el script)

La forma más sencilla es usar el script incluido en este repo; él rellena el array `models` con los 40 modelos gratuitos.

### 4. Lanza pi

```bash
pi
# /model  ->  xkiro  ->  elige un modelo
```


---

## El script setup_models.sh

### ¿Qué hace?

1. Hace `GET https://api.xkiro.com/v1/models` con el header `Authorization: Bearer <API_KEY>`.
2. Guarda la respuesta cruda en `$HOME/xkiro_models.json` (NO usa `/tmp` para no contaminar el filesystem global del sistema).
3. Ejecuta un bloque `python3` que:
   - Lee el JSON descargado.
   - Filtra `data[]` por `access_tier == "free"`.
   - Construye el array `models` con la forma que espera pi: `id`, `name`, `contextWindow`, `maxTokens`, `reasoning`, `input` (text/image), `cost`.
   - Añade el sufijo `(Free)` al nombre si no lo trae, para distinguirlo en el selector.
4. Escribe el resultado en `~/.pi/agent/models.json` con indent=2.
5. Imprime el conteo final y la lista de nombres.

### Variables que puedes personalizar

| Variable | Default | Descripción |
|---|---|---|
| `API_KEY` | `sk-xt-...` (hardcoded) | API key de Xkiro. **Edita el script o usa variable de entorno** |
| `BASE_URL` | `https://api.xkiro.com/v1` | URL base de la API |
| `MODELS_FILE` | `$HOME/xkiro_models.json` | Archivo temporal de descarga |
| `CONFIG_FILE` | `$HOME/.pi/agent/models.json` | Destino final |

### Características de robustez

- `--connect-timeout 15` y `--max-time 60` evitan cuelgues.
- `--retry 3 --retry-delay 2 --retry-connrefused` reintenta ante fallos transitorios.
- Verifica `HTTP_CODE == 200` y que el archivo no esté vacío.
- Si el JSON es inválido, aborta con código 1.
- Si `models.json` queda vacío tras el procesamiento, aborta con código 1.


---

## Estructura del models.json

Pi espera esta forma (ver `docs/models.md` del proyecto pi):

```json
{
  "providers": {
    "<nombre>": {
      "baseUrl": "https://api.xkiro.com/v1",
      "api": "openai-completions",
      "apiKey": "sk-xt-...",
      "models": [
        {
          "id": "deepseek/deepseek-v4-flash",
          "name": "DeepSeek V4 Flash (Free)",
          "contextWindow": 1048576,
          "maxTokens": 65536,
          "reasoning": true,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

### Campos por modelo

| Campo | Tipo | Significado |
|---|---|---|
| `id` | string | ID que se envía a la API en `model` |
| `name` | string | Etiqueta visible en `/model` |
| `contextWindow` | int | Tamaño máximo de la ventana de contexto (tokens) |
| `maxTokens` | int | Máximo de tokens de salida por respuesta |
| `reasoning` | bool | Si soporta reasoning (pi lo usa para `reasoning_effort`) |
| `input` | array | `["text"]` o `["text","image"]` si soporta visión |
| `cost` | object | Costes en USD por millón de tokens (todos 0 en free) |

### Campos opcionales a nivel de provider

```json
{
  "providers": {
    "xkiro": {
      "baseUrl": "...",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "maxTokensField": "max_tokens"
      }
    }
  }
}
```

Útil si la API no entiende el role `developer` o el campo `reasoning_effort`. Xkiro en la práctica acepta ambos, por lo que no hace falta configurarlos.

| ID | Nombre | Contexto | Salida | Visión |
|---|---|---|---|---|
| `deepseek/deepseek-v4-flash` | DeepSeek V4 Flash (Free) | 1,048,576 | 65,536 | no |
| `openai/gpt-5.3-codex-spark` | Codex 5.3 Spark (Free) | 128,000 | 65,536 | no |
| `qwen/qwen3.5-omni-plus:free` | Qwen3.5 Omni Plus (Free) | 262,144 | 65,536 | si |
| `minimax/minimax-m3:free` | MiniMax M3 (Free) | 1,000,000 | 65,536 | si |
| `minimax/minimax-m2.7:free` | MiniMax M2.7 (Free) | 204,800 | 65,536 | no |
| `mistralai/mistral-large-2512` | Mistral Large 3 (Free) | 256,000 | 16,384 | si |
| `mistralai/mistral-medium-3.5` | Mistral Medium 3.5 (Free) | 256,000 | 65,536 | si |
| `mistralai/mistral-small-2603` | Mistral Small 4 (Free) | 256,000 | 65,536 | si |
| `mistralai/codestral-2508` | Codestral (Free) | 256,000 | 16,384 | no |
| `mistralai/devstral-medium` | Devstral 2 (Free) | 256,000 | 16,384 | no |
| `mistralai/ministral-8b` | Ministral 3 8B (Free) | 256,000 | 8,192 | si |
| `mistralai/ministral-3b` | Ministral 3 3B (Free) | 128,000 | 8,192 | si |
| `minimax/minimax-m2.5-highspeed:free` | MiniMax M2.5 Highspeed (Free) | 204,800 | 65,536 | no |
| `minimax/minimax-m2:free` | MiniMax M2 (Free) | 204,800 | 65,536 | no |
| `minimax/minimax-m2.7-highspeed:free` | MiniMax M2.7 Highspeed (Free) | 204,800 | 65,536 | no |
| `minimax/minimax-m2.5:free` | MiniMax M2.5 (Free) | 204,800 | 65,536 | no |
| `deepseek/deepseek-chat-v3.1` | DeepSeek V3.1 (Free) | 163,840 | 65,536 | no |
| `mistralai/ministral-14b` | Ministral 3 14B (Free) | 256,000 | 8,192 | si |
| `minimax/minimax-m2.1:free` | MiniMax M2.1 (Free) | 204,800 | 65,536 | no |
| `minimax/minimax-m2.1-highspeed:free` | MiniMax M2.1 Highspeed (Free) | 204,800 | 65,536 | no |
| `qwen/qwen3.7-plus:free` | Qwen3.7 Plus (Free) | 1,000,000 | 65,536 | si |
| `qwen/qwen3.6-plus:free` | Qwen3.6 Plus (Free) | 1,000,000 | 65,536 | si |
| `qwen/qwen3.5-plus:free` | Qwen3.5 Plus (Free) | 1,000,000 | 65,536 | si |
| `qwen/qwen3.5-397b-a17b:free` | Qwen3.5 397B A17B (Free) | 262,144 | 65,536 | si |
| `qwen/qwen3.5-omni-flash:free` | Qwen3.5 Omni Flash (Free) | 262,144 | 65,536 | si |
| `qwen/qwen3-max:free` | Qwen3 Max (Free) | 262,144 | 65,536 | si |
| `deepseek/deepseek-v4-pro` | DeepSeek V4 Pro (Free) | 1,048,576 | 65,536 | no |
| `deepseek/deepseek-v3.2` | DeepSeek V3.2 (Free) | 131,072 | 65,536 | no |
| `qwen/qwen-plus-2025-07-28:free` | Qwen Plus 0728 (Free) | 131,072 | 65,536 | si |
| `qwen/qwen3-vl-plus:free` | Qwen3 VL Plus (Free) | 262,144 | 65,536 | si |
| `sensenova/sensenova-6.8-flash-lite` | SenseNova 6.8 Flash-Lite (Free) | 262,144 | 65,536 | si |
| `sensenova/sensenova-6.7-flash-lite` | SenseNova 6.7 Flash-Lite (Free) | 262,144 | 65,536 | si |
| `qwen/qwen3.8-max:free` | Qwen3.8 Max (Free) | 1,000,000 | 65,536 | si |
| `qwen/qwen3.7-max:free` | Qwen3.7 Max (Free) | 1,000,000 | 65,536 | no |
| `qwen/qwen3.6-max-preview:free` | Qwen3.6 Max Preview (Free) | 262,144 | 65,536 | no |
| `qwen/qwen3.6-27b:free` | Qwen3.6 27B (Free) | 262,144 | 65,536 | si |
| `qwen/qwen3.5-flash:free` | Qwen3.5 Flash (Free) | 1,000,000 | 65,536 | si |
| `qwen/qwen3.6-35b-a3b:free` | Qwen3.6 35B A3B (Free) | 262,144 | 65,536 | si |
| `qwen/qwen3-coder-plus:free` | Qwen3 Coder Plus (Free) | 1,048,576 | 65,536 | si |
| `qwen/qwen3-omni-flash:free` | Qwen3 Omni Flash (Free) | 262,144 | 65,536 | si |

---

## Uso desde la TUI de pi

Una vez configurado, dentro de pi:

```
/model
```

Verás una lista con todos los modelos disponibles. Filtra escribiendo:

- `xkiro` → sólo los de Xkiro
- `qwen` → sólo los de Qwen
- `free` → los que tengan "Free" en el nombre

Selecciona con Enter. La sesión actual usará ese modelo.

### Guardar como default

Edita `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "xkiro"
}
```

> Sin `defaultModel`, pi recuerda el último modelo de la sesión anterior. Si quieres uno fijo, añádelo: `"defaultModel": "deepseek/deepseek-v4-flash"` (ver [esta nota](#-si-quieres-que-pi-recuerde-el-último-modelo-entre-sesiones)).

### Login persistente

Si prefieres que pi guarde la key (no la hardcodees en `models.json`):

```
/login
# Selecciona "xkiro", pega tu API key
```

Pi la cifrará y guardará en `~/.pi/agent/auth.json`. El `apiKey` en `models.json` puede quedarse como placeholder.

---

## Uso por línea de comandos (--model)

Si sólo quieres probar un modelo puntual sin entrar a la TUI:

```bash
pi --provider xkiro --model deepseek/deepseek-v4-flash
pi --provider xkiro --model qwen/qwen3.7-plus:free
pi --provider xkiro --model minimax/minimax-m3:free
pi --provider xkiro --model mistralai/mistral-large-2512
```

También puedes combinarlo con un prompt directo:

```bash
pi --provider xkiro --model deepseek/deepseek-v4-flash -p "Explícame qué hace este repo"
```


---

## Troubleshooting

### `/model` solo muestra 1 modelo (o ninguno)

**Causa más probable:** una extensión `registerProvider` está sobrescribiendo el catálogo.

```bash
ls ~/.pi/agent/extensions/
```

Si ves un archivo como `xkiro-provider.ts` o similar, **bórralo**:

```bash
rm ~/.pi/agent/extensions/xkiro-provider.ts
```

Luego reabre pi. Ahora `/model` mostrará los 40.

> Detalle: `pi.registerProvider(...)` reemplaza completamente la entrada del provider. Si el `models.json` también lo define, **gana la extensión**. Ver `docs/extensions.md` y `docs/custom-provider.md` de pi.

### `HTTP 401 Unauthorized`

La API key es incorrecta, expiró o no tiene permisos para `/v1/models`. Comprueba:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer sk-xt-..." \
  https://api.xkiro.com/v1/models
```

Debe devolver `200`.

### `HTTP 429 Too Many Requests`

Estás rate-limited. El script ya reintenta 3 veces; si persiste, espera unos minutos.

### El script dice "JSON inválido"

La respuesta de Xkiro cambió de schema. Inspecciona:

```bash
cat ~/xkiro_models.json | head -c 500
```

Probablemente falte el campo `access_tier` o venga con otro nombre. Ajusta el filtro dentro del bloque `PYEOF` del script.

### pi ignora el provider

Comprueba la sintaxis del JSON:

```bash
python3 -c "import json; print(json.load(open('/data/data/com.termux/files/home/.pi/agent/models.json')))"
```

Si lanza error, hay un problema de sintaxis (coma de más, comilla mal cerrada, etc.).


---

## Buenas prácticas y seguridad

- **No commitees tu API key.** El script la tiene hardcoded por simplicidad, pero lo correcto es:
  - Usar variable de entorno: `export XKIRO_API_KEY="sk-xt-..."` y modificar el script para que la lea.
  - O guardar en `~/.pi/agent/auth.json` vía `/login` y dejar el `apiKey` del `models.json` como placeholder.
- **Permisos del archivo:** `chmod 600 ~/.pi/agent/models.json` para que solo tú lo leas. (Ya viene así por defecto: `-rw-------`.)
- **Re-ejecuta el script periódicamente:** Xkiro añade modelos nuevos. Con un cron mensual lo automatizas:
  ```bash
  # crontab -e
  0 0 1 * *  bash ~/setup_models.sh
  ```
- **No subas `models.json` con tu key a un repo público** — aunque pi lo trata como placeholder, otros servicios no.

---

## Limitaciones conocidas

- **Tools / function calling:** no todos los modelos gratuitos de Xkiro soportan tools. Si pi intenta usar `bash` o `read` y el modelo no los acepta, verás errores 400.
- **Streaming:** depende del modelo. La mayoría sí; algunos legacy no.
- **`reasoning_effort`:** Xkiro lo acepta, pero los valores soportados varían (`low`, `medium`, `high`, o numéricos).
- **Rate limits:** los modelos free comparten quota. Si haces muchas requests seguidas, puedes recibir 429.
- **No hay `system` role en algunos modelos pequeños:** el bloque `compat.supportsDeveloperRole = false` a nivel de modelo puede ayudar.

---

## Cómo actualizar los modelos

Cuando Xkiro saque modelos nuevos, basta con:

```bash
bash ~/setup_models.sh
```

El script:

1. Re-descarga el catálogo actualizado.
2. Vuelve a filtrar los `access_tier == "free"`.
3. Sobrescribe `~/.pi/agent/models.json`.

No hace falta reinstalar pi ni recargar nada — al abrir `/model` ya verás los nuevos.

---

## Referencias

- [pi-coding-agent en GitHub](https://github.com/earendil-works/pi-coding-agent)
- [Documentación oficial: Custom Models](https://github.com/earendil-works/pi-coding-agent/blob/main/docs/models.md)
- [Documentación oficial: Custom Providers](https://github.com/earendil-works/pi-coding-agent/blob/main/docs/custom-provider.md)
- [Documentación oficial: Extensions](https://github.com/earendil-works/pi-coding-agent/blob/main/docs/extensions.md)
- [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat)

---

## Bonus: combinar con Ponytail (menos código por sesión)

Para reducir aún más el consumo de tokens (y por tanto el rate-limit) en tus sesiones con Xkiro, instala **[Ponytail](https://github.com/DietrichGebert/ponytail)** — un skill de "lazy senior dev" que fuerza al agente a tomar siempre el camino más corto que funcione.

### Instalación

```bash
pi install git:github.com/DietrichGebert/ponytail
```

### ¿Por qué ayuda con Xkiro?

- Los modelos **free** de Xkiro comparten quota. Menos tokens por respuesta = más sesiones antes del 429.
- Ponytail aplica una "escalera" antes de cada cambio:
  1. ¿Necesita existir? → YAGNI
  2. ¿Ya existe en el código? → reusar
  3. ¿Stdlib lo hace? → usarlo
  4. ¿Feature nativa? → usarla
  5. ¿Dep ya instalada? → usarla, no añadir nueva
  6. ¿Una línea? → una línea
  7. Solo entonces: el mínimo que funcione

### Niveles

- `lite` — suave, sólo evita over-engineering obvio
- `full` (default) — equilibrio
- `ultra` — máxima reducción, útil para tareas triviales

Cambia con `/ponytail lite|full|ultra` o apágalo con `stop ponytail` / `normal mode`.

### Comandos disponibles en pi

- `/ponytail` — control de nivel
- `/ponytail-audit` — audita código existente
- `/ponytail-review` — revisión estilo "lazy senior"
- `/ponytail-debt` — detecta deuda técnica
- `/ponytail-gain` — calcula ahorro de LOC/tokens
- `/ponytail-help` — ayuda

### Benchmark del autor (Claude Code, FastAPI + React, Haiku 4.5, n=4)

| vs baseline | LOC | tokens | coste | tiempo | safe |
|---|--:|--:|--:|--:|--:|
| **ponytail** | **-54%** | **-22%** | **-20%** | **-27%** | **100%** |
| caveman (control prosa concisa) | -20% | +7% | +3% | +2% | 100% |
| prompt "YAGNI + one-liners" | -33% | -14% | -21% | -30% | 95% |

Ponytail es el único que recorta las 4 métricas y mantiene el 100% de seguridad.

### Ejemplo rápido

Tú: *"Necesito un date picker en mi web"*

Sin ponytail: instala flatpickr, componente wrapper, stylesheet, debate de timezones.
Con ponytail:
```html
<input type="date">
```

### Combinación recomendada

```bash
pi --provider xkiro --model deepseek/deepseek-v4-flash
# dentro de pi:
/ponytail ultra
# ya estás en modo "una línea si se puede" + modelo free
```

---


---

## Persistir el modelo entre sesiones

Pi **no** recuerda automáticamente el último modelo que usaste en una sesión — hay que guardarlo explícitamente.

### Método 1: dentro de la TUI (recomendado)

1. Abre `/model`.
2. Filtra escribiendo, p. ej. `xkiro`.
3. Navega al modelo que quieras y selecciónalo con **Enter** (sólo cambia esta sesión).
4. Para **persistirlo** entre sesiones: repite y, **antes** de confirmar, pulsa **`Ctrl+S`**.

Pi escribe `defaultProvider` y `defaultModel` en `~/.pi/agent/settings.json`. La próxima vez que abras pi, arrancará ya con ese modelo.

> Si seleccionas con Enter pero **sin** pulsar Ctrl+S, el cambio dura solo la sesión actual. Al cerrar, se pierde. Esto es por diseño — te da un "modo prueba" sin tocar tu config.

### Método 2: editar settings.json a mano

```json
{
  "defaultProvider": "xkiro"
}
```

Equivalente a Ctrl+S pero sin abrir la TUI. Útil para scripts o dotfiles. Para fijar un modelo concreto, añade `defaultModel`.

### Por qué tu pi puede estar "olvidando" el último modelo

Tres causas habituales:

1. **Estás pulsando Enter sin Ctrl+S** en `/model`. → Solución: pulsa `Ctrl+S` siempre.
2. **`settings.json` tiene un `defaultProvider` que no es xkiro** (p. ej. `"opencode"`) y por eso arranca con ése. → Solución: cambiarlo al método 2.
3. **Una extensión `registerProvider` machaca el provider antes de leer settings.** → Solución: borrar la extensión (ver [Troubleshooting](#troubleshooting)).

### Verificar la config actual

```bash
cat ~/.pi/agent/settings.json | grep -A1 default
```

Debe mostrar `"defaultProvider": "xkiro"` y un `defaultModel` que exista en tu `models.json`.


### ⚠️ Si quieres que pi RECUERDE el último modelo entre sesiones

No pongas `defaultModel` en `settings.json`. Déjalo solo así:

```json
{
  "defaultProvider": "xkiro"
}
```

Cuando `defaultModel` está **ausente**, pi arranca con el último modelo de tu sesión anterior. Cuando **está presente**, siempre gana sobre el historial.

### Cuándo usar cada variante

| Quieres... | `defaultProvider` | `defaultModel` |
|---|---|---|
| Que recuerde el último modelo (recomendado) | `"xkiro"` | *omitir* |
| Que SIEMPRE arranque con un modelo fijo | `"xkiro"` | `"deepseek/deepseek-v4-flash"` |
| Que pregunte cada vez | *omitir* | *omitir* |

