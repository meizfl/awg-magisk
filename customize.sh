#!/system/bin/sh
# customize.sh - выполняется Magisk Manager/App при установке модуля

SKIPUNZIP=0

ui_print "- AmneziaWG (awg-quick) Magisk Module"
ui_print "- Определение архитектуры устройства..."

case "$ARCH" in
  arm64) BIN_ARCH="arm64" ;;
  arm)   BIN_ARCH="arm" ;;
  x64)   BIN_ARCH="x86_64" ;;
  x86)   BIN_ARCH="x86" ;;
  *) ui_print "! Неизвестная архитектура: $ARCH"; abort "! Установка прервана" ;;
esac

ui_print "- Архитектура: $BIN_ARCH"

# Если в архиве бинарники разложены по под-папкам arch/<arch>/,
# переносим нужные в bin/ и удаляем остальные, чтобы не раздувать модуль.
if [ -d "$MODPATH/bin/arch" ]; then
  if [ -d "$MODPATH/bin/arch/$BIN_ARCH" ]; then
    cp -f "$MODPATH/bin/arch/$BIN_ARCH/"* "$MODPATH/bin/" 2>/dev/null
  else
    ui_print "! Бинарники для $BIN_ARCH не найдены в архиве"
    abort "! Пересоберите модуль для этой архитектуры (build/build.sh)"
  fi
  rm -rf "$MODPATH/bin/arch"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/awg" 0 0 0755
set_perm "$MODPATH/bin/awg-quick" 0 0 0755
set_perm "$MODPATH/bin/amneziawg-go" 0 0 0755
set_perm "$MODPATH/bin/awg-supervisor" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
mkdir -p "$MODPATH/logs"
set_perm_recursive "$MODPATH/logs" 0 0 0755 0644
mkdir -p "$MODPATH/run"
set_perm_recursive "$MODPATH/run" 0 0 0755 0755

ui_print "- Не забудьте отредактировать config/wg0.conf перед запуском!"
ui_print "- Готово."
