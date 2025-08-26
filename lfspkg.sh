#!/bin/sh
#
# lfspkg.sh — Gerenciador de pacotes source-based POSIX para LFS
# Recursos:
#  - Recipes em /repo/{base,x11,extras,desktop}/<pkg>/<pkg-ver>/PKGFILE
#  - Build + install via DESTDIR e opcional fakeroot
#  - Aplicação automática de patches após descompactar
#  - Empacotamento em tar.{xz,gz}
#  - Registro de instalados + manifest de arquivos
#  - Sincronização com repositório Git (add/commit)
#  - Cores, spinner, logs, tudo configurável via variáveis
#  - Rebuild de todo o sistema ("respirar" == recompilar tudo)
#
# Compatível com /bin/sh (POSIX). Evita extensões bash.
#
# ------------------------------------------------------------
# CONFIGURAÇÃO
# ------------------------------------------------------------
# Raiz do repositório de recipes
REPO_ROOT=${REPO_ROOT:-/repo}
REPO_TREES=${REPO_TREES:-"base x11 extras desktop"}
# Onde os tarballs (fontes) ficam (pode ser o próprio recipe dir)
SRC_CACHE=${SRC_CACHE:-/var/cache/lfspkg/sources}
# Diretórios de trabalho
BUILD_ROOT=${BUILD_ROOT:-/var/tmp/lfspkg/build}
PKGROOT=${PKGROOT:-/var/tmp/lfspkg/pkg}     # DESTDIR base por pacote
ARTIFACTS_DIR=${ARTIFACTS_DIR:-/var/cache/lfspkg/packages}
LOG_DIR=${LOG_DIR:-/var/log/lfspkg}
DB_DIR=${DB_DIR:-/var/lib/lfspkg}
# Empacotamento: xz preferido, cai para gzip
PKG_COMPRESSOR=${PKG_COMPRESSOR:-xz}        # valores: xz|gzip
# Comandos externos (permite override)
CURL=${CURL:-curl}
WGET=${WGET:-wget}
TAR=${TAR:-tar}
PATCH=${PATCH:-patch}
MAKE=${MAKE:-make}
FAKEROOT_BIN=${FAKEROOT_BIN:-fakeroot}
GIT=${GIT:-git}
SHA256SUM=${SHA256SUM:-sha256sum}
MD5SUM=${MD5SUM:-md5sum}
SED=${SED:-sed}
AWK=${AWK:-awk}

# Git: commit automático ao sincronizar recipes/artefatos
GIT_AUTO_COMMIT=${GIT_AUTO_COMMIT:-1}
GIT_COMMIT_MSG_PREFIX=${GIT_COMMIT_MSG_PREFIX:-"lfspkg:"}

# Cores (usa tput se disponível, senão fallback ANSI; pode desativar com NO_COLOR=1)
if [ -z "$NO_COLOR" ]; then
  if command -v tput >/dev/null 2>&1; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YLW=$(tput setaf 3)
    C_BLU=$(tput setaf 4); C_MAG=$(tput setaf 5); C_CYN=$(tput setaf 6)
    C_BOLD=$(tput bold); C_DIM=$(tput dim); C_RST=$(tput sgr0)
  else
    C_RED='\033[31m'; C_GRN='\033[32m'; C_YLW='\033[33m'
    C_BLU='\033[34m'; C_MAG='\033[35m'; C_CYN='\033[36m'
    C_BOLD='\033[1m'; C_DIM='\033[2m'; C_RST='\033[0m'
  fi
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_MAG=""; C_CYN=""
  C_BOLD=""; C_DIM=""; C_RST=""
fi

# ------------------------------------------------------------
# UTILITÁRIOS: log, erro, spinner, run_logged
# ------------------------------------------------------------
STAMP() { date +"%Y-%m-%d %H:%M:%S"; }
LOGFILE_GLOBAL=""
ensure_dirs() {
  mkdir -p "$SRC_CACHE" "$BUILD_ROOT" "$PKGROOT" "$ARTIFACTS_DIR" "$LOG_DIR" "$DB_DIR"
}
log_init() {
  ensure_dirs
  LOGFILE_GLOBAL="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
  : > "$LOGFILE_GLOBAL"
}
log() {
  printf "%s[%s]%s %s\n" "$C_DIM" "$(STAMP)" "$C_RST" "$1" | tee -a "$LOGFILE_GLOBAL"
}
info() { printf "%sℹ %s%s\n" "$C_CYN" "$1" "$C_RST" | tee -a "$LOGFILE_GLOBAL"; }
success() { printf "%s✔ %s%s\n" "$C_GRN" "$1" "$C_RST" | tee -a "$LOGFILE_GLOBAL"; }
warn() { printf "%s⚠ %s%s\n" "$C_YLW" "$1" "$C_RST" | tee -a "$LOGFILE_GLOBAL"; }
err() { printf "%s✖ %s%s\n" "$C_RED" "$1" "$C_RST" | tee -a "$LOGFILE_GLOBAL" 1>&2; }

# spinner: executa comando em subshell, exibe spinner até terminar
spinner_run() {
  # uso: spinner_run "mensagem" comando args...
  msg=$1; shift
  printf "%s⟳ %s%s" "$C_BLU" "$msg" "$C_RST"
  (
    # subshell: executa comando e redireciona stdout/err para FIFO
    "$@"
  ) &
  cmd_pid=$!
  # animação simples
  spin='|/-\\'
  i=1
  while kill -0 "$cmd_pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r%s⟳ %s %s%s" "$C_BLU" "$msg" "$(printf %s "${spin:$i:1}")" "$C_RST"
    sleep 0.1
  done
  wait "$cmd_pid"
  rc=$?
  if [ $rc -eq 0 ]; then
    printf "\r"
    success "$msg — concluído"
  else
    printf "\r"
    err "$msg — falhou (rc=$rc)"
  fi
  return $rc
}

# Executa um comando, captura saída para log, mostra spinner
run_logged() {
  # uso: run_logged "etiqueta" logfile comando args...
  label=$1; shift
  logfile=$1; shift
  : > "$logfile"
  ( "$@" ) >>"$logfile" 2>&1 &
  cmd_pid=$!
  spin='|/-\\'; i=1
  printf "%s⏳ %s%s" "$C_MAG" "$label" "$C_RST"
  while kill -0 "$cmd_pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r%s⏳ %s %s%s" "$C_MAG" "$label" "$(printf %s "${spin:$i:1}")" "$C_RST"
    sleep 0.1
  done
  wait "$cmd_pid"; rc=$?
  if [ $rc -eq 0 ]; then printf "\r"; success "$label"; else printf "\r"; err "$label (rc=$rc)"; fi
  return $rc
}

# ------------------------------------------------------------
# PARSING DE RECIPE (PKGFILE)
# ------------------------------------------------------------
# PKGFILE é um shell simples com variáveis, ex:
#   NAME=gcc
#   VERSION=13.2.0
#   SOURCE_URL=https://ftp.gnu.org/gnu/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz
#   SOURCE_SHA256=...  # opcional
#   MD5=...            # opcional
#   CONFIGURE=./configure --prefix=/usr --disable-multilib
#   MAKEFLAGS=-j$(nproc)
#   PATCHES="foo.patch bar.patch"   # relativo a ./patches no recipe
#   PREPARE() { something; }        # hooks opcionais
#   BUILD() { ./configure ...; make; }
#   INSTALL() { make DESTDIR="$DESTDIR" install; }
# Se BUILD/INSTALL não forem definidos, o fluxo padrão será usado.

load_recipe() {
  PKGDIR=$1
  if [ ! -f "$PKGDIR/PKGFILE" ]; then
    err "PKGFILE não encontrado em $PKGDIR"
    return 1
  fi
  # shellcheck disable=SC2039,SC2163
  # Carrega em subshell para evitar poluir ambiente; exporta interessantes
  # Porém precisamos no ambiente atual — então ". PKGFILE" diretamente:
  # O mantenedor é responsável por não executar coisas perigosas.
  #
  # Variáveis padrão
  NAME=""; VERSION=""; SOURCE_URL=""; SOURCE_SHA256=""; MD5="";
  CONFIGURE=""; MAKEFLAGS=""; PATCHES="";
  PREPARE() { :; }; BUILD() { :; }; INSTALL() { :; };
  . "$PKGDIR/PKGFILE"
  if [ -z "$NAME" ] || [ -z "$VERSION" ]; then
    err "Recipe inválida (NAME/VERSION) em $PKGDIR/PKGFILE"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------
# FUNÇÕES DE BAIXA/VERIFICAÇÃO/EXTRAÇÃO
# ------------------------------------------------------------
fetch_source() {
  url=$1
  out=$2
  if [ -f "$out" ]; then
    info "Fonte já presente: $out"
    return 0
  fi
  if command -v "$CURL" >/dev/null 2>&1; then
    "$CURL" -L -o "$out" "$url"
  elif command -v "$WGET" >/dev/null 2>&1; then
    "$WGET" -O "$out" "$url"
  else
    err "Nem curl nem wget disponíveis para baixar $url"
    return 1
  fi
}

verify_checksum() {
  file=$1; sha=$2; md5=$3
  if [ -n "$sha" ] && command -v "$SHA256SUM" >/dev/null 2>&1; then
    sum=$($SHA256SUM "$file" | $AWK '{print $1}')
    [ "$sum" = "$sha" ] || { err "SHA256 não confere"; return 1; }
    success "SHA256 ok"
  elif [ -n "$md5" ] && command -v "$MD5SUM" >/dev/null 2>&1; then
    sum=$($MD5SUM "$file" | $AWK '{print $1}')
    [ "$sum" = "$md5" ] || { err "MD5 não confere"; return 1; }
    success "MD5 ok"
  else
    warn "Sem checksum para verificar $file"
  fi
}

extract_source() {
  tarball=$1; dest=$2
  mkdir -p "$dest"
  case "$tarball" in
    *.tar.xz)   $TAR -xJf "$tarball" -C "$dest" ;;
    *.txz)      $TAR -xJf "$tarball" -C "$dest" ;;
    *.tar.gz)   $TAR -xzf "$tarball" -C "$dest" ;;
    *.tgz)      $TAR -xzf "$tarball" -C "$dest" ;;
    *.tar.bz2)  $TAR -xjf "$tarball" -C "$dest" ;;
    *.zip)      unzip -q "$tarball" -d "$dest" ;;
    *)          $TAR -xf "$tarball" -C "$dest" ;;
  esac
}

apply_patches() {
  srcdir=$1; patchdir=$2; list=$3
  [ -z "$list" ] && return 0
  for p in $list; do
    if [ -f "$patchdir/$p" ]; then
      ( cd "$srcdir" && $PATCH -p1 < "$patchdir/$p" ) || return 1
      info "Patch aplicado: $p"
    else
      err "Patch não encontrado: $patchdir/$p"; return 1
    fi
  done
}

# ------------------------------------------------------------
# BUILD/INSTALL padrão
# ------------------------------------------------------------
std_build() {
  # Executa ./configure (se existir) e make
  wd=$1
  ( cd "$wd" && \
    if [ -x ./configure ]; then ./configure $CONFIGURE; fi && \
    $MAKE ${MAKEFLAGS:-} )
}

std_install() {
  wd=$1; dest=$2
  ( cd "$wd" && $MAKE DESTDIR="$dest" install )
}

# ------------------------------------------------------------
# EMPACOTAMENTO E REGISTRO
# ------------------------------------------------------------
package_make() {
  dest=$1; name=$2; ver=$3
  mkdir -p "$ARTIFACTS_DIR"
  pkgname="${name}-${ver}.tar"
  tmpdir=$(dirname "$dest")
  ( cd "$dest" && $TAR -cf "$tmpdir/$pkgname" . ) || return 1
  case "$PKG_COMPRESSOR" in
    xz)
      xz -f "$tmpdir/$pkgname" || return 1
      out="$ARTIFACTS_DIR/${pkgname}.xz"
      mv "$tmpdir/$pkgname.xz" "$out" ;;
    gzip|gz)
      gzip -f "$tmpdir/$pkgname" || return 1
      out="$ARTIFACTS_DIR/${pkgname}.gz"
      mv "$tmpdir/$pkgname.gz" "$out" ;;
    *)
      warn "Compressor desconhecido, usando gzip"
      gzip -f "$tmpdir/$pkgname" || return 1
      out="$ARTIFACTS_DIR/${pkgname}.gz"
      mv "$tmpdir/$pkgname.gz" "$out" ;;
  esac
  printf "%s\n" "$out"
}

register_install() {
  name=$1; ver=$2; dest=$3
  mkdir -p "$DB_DIR"
  db="$DB_DIR/installed.db"
  manifest="$DB_DIR/${name}-${ver}.files"
  # Lista de arquivos relativos ao / (remove prefixo DESTDIR)
  ( cd "$dest" && find . -type f -o -type l -o -type d | $SED 's#^\./##' ) > "$manifest"
  # entrada simples NAME VERSION DATE
  printf "%s %s %s\n" "$name" "$ver" "$(STAMP)" >> "$db"
  success "Registrado ${name}-${ver} (manifesto em $manifest)"
}

# ------------------------------------------------------------
# GIT SYNC
# ------------------------------------------------------------
repo_git_sync() {
  root=$1; msg=$2
  if [ ! -d "$root/.git" ]; then
    warn "$root não é um repositório git; ignorando commit"
    return 0
  fi
  ( cd "$root" && $GIT add -A && $GIT status --porcelain | grep -q . ) || return 0
  if [ "$GIT_AUTO_COMMIT" = "1" ]; then
    ( cd "$root" && $GIT commit -m "$GIT_COMMIT_MSG_PREFIX $msg" ) || return 0
    success "Git commit realizado em $root"
  else
    info "Alterações preparadas em $root (commit automático desativado)"
  fi
}

# ------------------------------------------------------------
# PIPELINE DE BUILD
# ------------------------------------------------------------
# Caminho de recipe: base/gcc/gcc-13.2.0  (relativo a $REPO_ROOT)
#
cmd_build() {
  rel=$1
  PKGDIR="$REPO_ROOT/$rel"
  load_recipe "$PKGDIR" || return 1

  pkglog="$LOG_DIR/${NAME}-${VERSION}.log"
  log "Iniciando build de ${NAME}-${VERSION}"

  # origin do tarball
  src_url=${SOURCE_URL:-}
  tarname=${src_url##*/}
  [ -n "$tarname" ] || tarname="${NAME}-${VERSION}.tar"
  tarpath="$SRC_CACHE/$tarname"

  ensure_dirs
  [ -n "$src_url" ] && run_logged "Baixando fonte" "$pkglog" fetch_source "$src_url" "$tarpath" || true
  if [ -f "$tarpath" ]; then
    [ -n "$SOURCE_SHA256" ] || [ -n "$MD5" ] && run_logged "Verificando checksum" "$pkglog" verify_checksum "$tarpath" "$SOURCE_SHA256" "$MD5" || true
  else
    warn "Tarball não encontrado: $tarpath (prosseguindo se recipe lida baixar em PREPARE)"
  fi

  # diretórios
  WRK="$BUILD_ROOT/${NAME}-${VERSION}"
  DESTDIR="$PKGROOT/${NAME}-${VERSION}/dest"
  WRKSRC="$WRK/src"
  mkdir -p "$WRKSRC" "$DESTDIR"

  # extração
  if [ -f "$tarpath" ]; then
    run_logged "Extraindo" "$pkglog" extract_source "$tarpath" "$WRKSRC" || return 1
  fi

  # entra no subdiretório de fonte (assume única raiz)
  SUBDIR=$(ls -1 "$WRKSRC" | head -n1)
  [ -n "$SUBDIR" ] || SUBDIR="."
  SRCDIR="$WRKSRC/$SUBDIR"

  # patches
  if [ -n "$PATCHES" ]; then
    run_logged "Aplicando patches" "$pkglog" apply_patches "$SRCDIR" "$PKGDIR/patches" "$PATCHES" || return 1
  fi

  # PREPARE hook
  if type PREPARE >/dev/null 2>&1; then
    run_logged "PREPARE" "$pkglog" sh -c "DESTDIR='$DESTDIR' WRKSRC='$SRCDIR' PREPARE" || return 1
  fi

  # BUILD
  if [ "$(type BUILD 2>/dev/null | $AWK '{print $1}')" = "function" ] || [ "$(type BUILD 2>/dev/null | $AWK 'NR==1{print}')" = "BUILD is a shell function" ]; then
    run_logged "BUILD" "$pkglog" sh -c "cd '$SRCDIR' && DESTDIR='$DESTDIR' BUILD" || return 1
  else
    run_logged "Compilando (padrão)" "$pkglog" std_build "$SRCDIR" || return 1
  fi

  # INSTALL (com fakeroot se não root)
  INSTALL_CMD="std_install '$SRCDIR' '$DESTDIR'"
  if [ "$(id -u)" != "0" ]; then
    if command -v "$FAKEROOT_BIN" >/dev/null 2>&1; then
      INSTALL_CMD="$FAKEROOT_BIN sh -c 'if type INSTALL >/dev/null 2>&1; then cd \"$SRCDIR\" && DESTDIR=\"$DESTDIR\" INSTALL; else std_install \"$SRCDIR\" \"$DESTDIR\"; fi'"
    else
      warn "fakeroot não encontrado; tentando instalar mesmo assim (pode falhar)"
      INSTALL_CMD="sh -c 'if type INSTALL >/dev/null 2>&1; then cd \"$SRCDIR\" && DESTDIR=\"$DESTDIR\" INSTALL; else std_install \"$SRCDIR\" \"$DESTDIR\"; fi'"
    fi
  else
    INSTALL_CMD="sh -c 'if type INSTALL >/dev/null 2>&1; then cd \"$SRCDIR\" && DESTDIR=\"$DESTDIR\" INSTALL; else std_install \"$SRCDIR\" \"$DESTDIR\"; fi'"
  fi
  run_logged "INSTALL" "$pkglog" sh -c "$INSTALL_CMD" || return 1

  # Empacota
  PKGFILE=$(package_make "$DESTDIR" "$NAME" "$VERSION") || return 1
  info "Pacote gerado: $PKGFILE"

  # Registro
  register_install "$NAME" "$VERSION" "$DESTDIR" || return 1

  # Sync git (recipes e artefatos)
  repo_git_sync "$REPO_ROOT" "recipes ${NAME}-${VERSION}"
  repo_git_sync "$ARTIFACTS_DIR" "artefatos ${NAME}-${VERSION}"

  success "Build concluído: ${NAME}-${VERSION}"
  printf "%s\n" "$PKGFILE"
}

# ------------------------------------------------------------
# INSTALAÇÃO DO PACOTE (extrair no /)
# ------------------------------------------------------------
cmd_install_pkg() {
  tarball=$1
  [ -f "$tarball" ] || { err "Pacote não encontrado: $tarball"; return 1; }
  log "Instalando pacote $tarball no sistema (/)"
  case "$tarball" in
    *.tar.xz) $TAR -xJf "$tarball" -C / ;;
    *.tar.gz|*.tgz) $TAR -xzf "$tarball" -C / ;;
    *.tar) $TAR -xf "$tarball" -C / ;;
    *) err "Formato não suportado: $tarball"; return 1 ;;
  esac
  success "Instalado: $tarball"
}

# ------------------------------------------------------------
# LISTAR E ESTADO
# ------------------------------------------------------------
cmd_list_installed() {
  db="$DB_DIR/installed.db"
  [ -f "$db" ] || { warn "Nada instalado"; return 0; }
  cat "$db" | $AWK '{printf "%-24s %-12s %s\n", $1, $2, $3" "$4}'
}

cmd_list_recipes() {
  for t in $REPO_TREES; do
    find "$REPO_ROOT/$t" -maxdepth 3 -mindepth 3 -type f -name PKGFILE | while read -r f; do
      pkg=$(printf "%s" "$f" | $SED "s#^$REPO_ROOT/##; s#/PKGFILE##")
      printf "%s\n" "$pkg"
    done
  done | sort
}

# ------------------------------------------------------------
# REBUILD (respirar) — recompila todos recipes detectados
# ------------------------------------------------------------
cmd_rebuild_all() {
  log "Rebuild de todo o sistema"
  cmd_list_recipes | while read -r rel; do
    info "Rebuild: $rel"
    if ! cmd_build "$rel"; then
      err "Falha ao rebuildar: $rel"; return 1
    fi
  done
}

# ------------------------------------------------------------
# INICIALIZAÇÃO/HELP
# ------------------------------------------------------------
cmd_init() {
  ensure_dirs
  for t in $REPO_TREES; do
    mkdir -p "$REPO_ROOT/$t"
  done
  mkdir -p "$SRC_CACHE" "$ARTIFACTS_DIR"
  success "Estrutura criada em $REPO_ROOT"
}

usage() {
  cat <<USAGE
${C_BOLD}lfspkg.sh${C_RST} — gerenciador POSIX para LFS

Comandos:
  init                                   — cria estrutura básica em \$REPO_ROOT
  list-recipes                           — lista recipes detectadas
  list-installed                         — lista pacotes registrados
  build <tree/pacote/pacote-versao>      — compila e empacota a partir do recipe
  install-pkg </caminho/para/pacote.tar.*> — instala um pacote no sistema (/)
  rebuild-all                            — recompila todos os recipes (respirar)

Variáveis principais (override via env ou editar no topo):
  REPO_ROOT, REPO_TREES, SRC_CACHE, BUILD_ROOT, PKGROOT, ARTIFACTS_DIR,
  LOG_DIR, DB_DIR, PKG_COMPRESSOR, FAKEROOT_BIN, GIT, CURL/WGET, etc.

Recipe (PKGFILE) de exemplo:
  NAME=hello
  VERSION=2.12
  SOURCE_URL=https://ftp.gnu.org/gnu/hello/hello-2.12.tar.xz
  SOURCE_SHA256=e59...  # opcional
  CONFIGURE=./configure --prefix=/usr
  MAKEFLAGS=-j4
  PATCHES="fix-musl.patch"
  INSTALL() { make DESTDIR="$DESTDIR" install; }
USAGE
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
main() {
  log_init
  cmd=$1; shift 2>/dev/null || true
  case "$cmd" in
    init) cmd_init ;;
    list-recipes) cmd_list_recipes ;;
    list-installed) cmd_list_installed ;;
    build) [ -n "$1" ] || { usage; exit 1; }; cmd_build "$1" ;;
    install-pkg) [ -n "$1" ] || { usage; exit 1; }; cmd_install_pkg "$1" ;;
    rebuild-all) cmd_rebuild_all ;;
    ""|-h|--help|help) usage ;;
    *) err "Comando desconhecido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
