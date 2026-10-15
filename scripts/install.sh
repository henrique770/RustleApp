#!/usr/bin/env bash
# Installs RustleApp on this Mac: checks the requirements, prepares the local transcription server
# (Python venv + Whisper dependencies), builds and signs the app, copies it to /Applications
# (or ~/Applications) and opens it. The first launch shows the setup questionnaire.
# Keep this folder where it is afterwards: the app starts the server from it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf "\n==> %s\n" "$1"; }
fail() { printf "\nErro: %s\n" "$1" >&2; exit 1; }

say "Verificando requisitos"
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] || fail "o RustleApp precisa do macOS 14 (Sonoma) ou mais recente; este Mac tem $MACOS."
command -v swift >/dev/null || fail "Swift não encontrado. Instale as ferramentas de linha de comando: xcode-select --install"
PY="${RUSTLE_PYTHON:-$(command -v python3.12 || command -v python3.11 || command -v python3.10 || true)}"
[ -n "$PY" ] || fail "Python 3.10+ não encontrado. Instale com: brew install python@3.12"
echo "macOS $MACOS · $(swift --version 2>/dev/null | head -1) · $("$PY" --version)"

say "Preparando o servidor de transcrição (pode levar alguns minutos)"
VENV="$ROOT/server/.venv"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$ROOT/server/requirements.txt"

say "Criando o certificado local de assinatura (mantém as permissões entre atualizações)"
"$ROOT/scripts/create-signing-cert.sh"

say "Compilando o app"
"$ROOT/scripts/build-app.sh"

say "Copiando para Aplicativos"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x RustleApp 2>/dev/null || true
rm -rf "$DEST/RustleApp.app"
cp -R "$ROOT/build/RustleApp.app" "$DEST/RustleApp.app"
echo "Instalado em $DEST/RustleApp.app"

say "Abrindo o RustleApp"
open "$DEST/RustleApp.app"
cat <<MSG

Pronto! Na primeira abertura o RustleApp pergunta seu nome e suas preferências e pede as
permissões de Microfone e Acessibilidade. O modelo Whisper (~500 MB) é baixado no primeiro uso.
Não mova nem apague esta pasta ($ROOT): o app inicia o servidor a partir dela.
MSG
