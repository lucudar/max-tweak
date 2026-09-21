#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Полностью автоматический сборщик MAX IPA с tweak
================================================
1. Скачивает последний dylib из GitHub releases (max-tweak)
2. Берёт последний Potuzhno IPA из папки rev
3. Внедряет dylib в IPA
4. Добавляет LC_LOAD_DYLIB в Mach-O (используя insert_dylib если доступен)
5. Выдаёт готовый IPA

Использование:
    python auto_build_complete.py
"""
import os
import sys
import json
import shutil
import zipfile
import urllib.request
import subprocess
import struct
from pathlib import Path
from datetime import datetime

# Фикс кодировки для Windows
if sys.platform == 'win32':
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'strict')
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.buffer, 'strict')

# ═══════════════════════════════════════════════════════════════════════════
# КОНФИГУРАЦИЯ
# ═══════════════════════════════════════════════════════════════════════════

REPO = "lucudar/max-tweak"
DYLIB_NAME = "MAXMods.dylib"
REV_DIR = Path(r"C:\Users\ll\Downloads\вся хуйня\вся хуйня\rev\rev")
OUTPUT_DIR = Path.cwd()  # Выходной IPA в текущей директории

# ═══════════════════════════════════════════════════════════════════════════
# ARM64 ИНСТРУКЦИИ
# ═══════════════════════════════════════════════════════════════════════════

def make_lc_load_dylib(dylib_path_str):
    """
    Создаёт LC_LOAD_DYLIB load command для Mach-O.
    Это вставляется в Load Commands секцию бинарника.
    """
    # LC_LOAD_DYLIB = 0xC (12)
    LC_LOAD_DYLIB = 0xC

    # Структура: cmd(4) + cmdsize(4) + name_offset(4) + timestamp(4) +
    #            current_version(4) + compatibility_version(4) + dylib_path + padding

    path_bytes = dylib_path_str.encode('utf-8') + b'\x00'

    # name offset = 24 (после всех полей структуры)
    name_offset = 24

    # cmdsize должен быть кратен 8
    cmdsize = name_offset + len(path_bytes)
    if cmdsize % 8 != 0:
        padding = 8 - (cmdsize % 8)
        path_bytes += b'\x00' * padding
        cmdsize += padding

    lc = struct.pack('<IIIIII',
        LC_LOAD_DYLIB,           # cmd
        cmdsize,                 # cmdsize
        name_offset,             # dylib.name offset
        2,                       # timestamp (arbitrary)
        0x10000,                 # current_version
        0x10000                  # compatibility_version
    )

    return lc + path_bytes

# ═══════════════════════════════════════════════════════════════════════════
# ФУНКЦИИ
# ═══════════════════════════════════════════════════════════════════════════

def print_header(text):
    """Красивый заголовок"""
    print()
    print("═" * 70)
    print(f"  {text}")
    print("═" * 70)

def print_step(num, text):
    """Шаг процесса"""
    print(f"\n🔹 Шаг {num}: {text}")

def download_latest_dylib():
    """Скачивает последний dylib из GitHub releases"""
    print_step(1, "Скачивание MAXMods.dylib из GitHub")

    dylib_path = OUTPUT_DIR / DYLIB_NAME

    # Проверяем, есть ли уже
    if dylib_path.exists():
        print(f"   ✅ Найден существующий {DYLIB_NAME}")
        return dylib_path

    try:
        api_url = f"https://api.github.com/repos/{REPO}/releases/latest"
        print(f"   📡 Запрос: {api_url}")

        with urllib.request.urlopen(api_url) as response:
            release_data = json.loads(response.read().decode())

        # Ищем dylib в assets
        dylib_url = None
        for asset in release_data.get("assets", []):
            if asset["name"] == DYLIB_NAME:
                dylib_url = asset["browser_download_url"]
                break

        if not dylib_url:
            print(f"   ❌ {DYLIB_NAME} не найден в последнем release")
            return None

        print(f"   📦 Release: {release_data['tag_name']}")
        print(f"   🔗 URL: {dylib_url}")

        urllib.request.urlretrieve(dylib_url, dylib_path)
        print(f"   ✅ Скачано: {dylib_path}")

        return dylib_path

    except Exception as e:
        print(f"   ❌ Ошибка скачивания: {e}")
        return None

def find_latest_potuzhno_ipa():
    """Находит последний Potuzhno IPA в папке rev"""
    print_step(2, "Поиск последнего Potuzhno IPA")

    if not REV_DIR.exists():
        print(f"   ❌ Папка не найдена: {REV_DIR}")
        return None

    # Ищем все Potuzhno_*.ipa
    ipa_files = list(REV_DIR.glob("Potuzhno_v*.ipa"))

    if not ipa_files:
        print("   ❌ Potuzhno IPA файлы не найдены")
        return None

    # Сортируем по времени модификации, берём последний
    latest_ipa = max(ipa_files, key=lambda p: p.stat().st_mtime)

    size_mb = latest_ipa.stat().st_size / 1024 / 1024
    print(f"   ✅ Найден: {latest_ipa.name}")
    print(f"   📊 Размер: {size_mb:.1f} MB")

    return latest_ipa

def inject_dylib_into_ipa(ipa_path, dylib_path):
    """Внедряет dylib в IPA и добавляет LC_LOAD_DYLIB"""
    print_step(3, f"Внедрение {dylib_path.name} в {ipa_path.name}")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_ipa = OUTPUT_DIR / f"MAX_Modded_{timestamp}.ipa"
    temp_dir = OUTPUT_DIR / "temp_ipa_build"

    # Очистка временной папки
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
    temp_dir.mkdir()

    try:
        # 1. Распаковка IPA
        print("   📂 Распаковка IPA...")
        with zipfile.ZipFile(ipa_path, 'r') as zip_ref:
            zip_ref.extractall(temp_dir)

        # 2. Поиск .app bundle
        payload_dir = temp_dir / "Payload"
        app_bundles = list(payload_dir.glob("*.app"))

        if not app_bundles:
            print("   ❌ .app bundle не найден")
            return None

        app_bundle = app_bundles[0]
        print(f"   ✅ Найден: {app_bundle.name}")

        # 3. Создание Frameworks директории
        frameworks_dir = app_bundle / "Frameworks"
        frameworks_dir.mkdir(exist_ok=True)

        # 4. Копирование dylib
        target_dylib = frameworks_dir / dylib_path.name
        shutil.copy2(dylib_path, target_dylib)
        print(f"   ✅ Скопирован dylib в Frameworks/")

        # 5. Поиск исполняемого файла
        exec_name = app_bundle.stem
        executable = app_bundle / exec_name

        if not executable.exists():
            print(f"   ❌ Исполняемый файл не найден: {executable}")
            return None

        print(f"   🔍 Исполняемый файл: {exec_name}")

        # 6. Добавление LC_LOAD_DYLIB
        dylib_load_path = f"@executable_path/Frameworks/{dylib_path.name}"
        print(f"   🔧 Добавление LC_LOAD_DYLIB: {dylib_load_path}")

        # Попытка использовать insert_dylib
        insert_dylib_success = False
        try:
            result = subprocess.run([
                "insert_dylib",
                "--inplace",
                "--all-yes",
                dylib_load_path,
                str(executable)
            ], capture_output=True, text=True, timeout=30)

            if result.returncode == 0:
                print("   ✅ LC_LOAD_DYLIB добавлен через insert_dylib")
                insert_dylib_success = True
            else:
                print(f"   ⚠️  insert_dylib failed: {result.stderr}")
        except FileNotFoundError:
            print("   ⚠️  insert_dylib не найден, пропускаем")
        except Exception as e:
            print(f"   ⚠️  insert_dylib error: {e}")

        if not insert_dylib_success:
            print("   ⚠️  LC_LOAD_DYLIB НЕ добавлен автоматически")
            print("   📝 Нужно добавить вручную через:")
            print(f"       insert_dylib '{dylib_load_path}' '{executable}'")

        # 7. Упаковка обратно в IPA
        print(f"   📦 Упаковка в {output_ipa.name}...")

        with zipfile.ZipFile(output_ipa, 'w', zipfile.ZIP_DEFLATED) as zip_out:
            for root, dirs, files in os.walk(temp_dir):
                for file in files:
                    file_path = Path(root) / file
                    arcname = file_path.relative_to(temp_dir)
                    zip_out.write(file_path, arcname)

        size_mb = output_ipa.stat().st_size / 1024 / 1024
        print(f"   ✅ Создан: {output_ipa}")
        print(f"   📊 Размер: {size_mb:.1f} MB")

        return output_ipa, insert_dylib_success

    except Exception as e:
        print(f"   ❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return None, False

    finally:
        # Очистка
        if temp_dir.exists():
            shutil.rmtree(temp_dir)

# ═══════════════════════════════════════════════════════════════════════════
# ГЛАВНАЯ ФУНКЦИЯ
# ═══════════════════════════════════════════════════════════════════════════

def main():
    print_header("MAX Messenger - Автоматический сборщик с MAXMods tweak")

    print(f"📁 Рабочая директория: {OUTPUT_DIR}")
    print(f"📁 Rev папка: {REV_DIR}")

    # Шаг 1: Скачать dylib
    dylib_path = download_latest_dylib()
    if not dylib_path:
        print("\n❌ ОШИБКА: Не удалось получить dylib")
        sys.exit(1)

    # Шаг 2: Найти последний Potuzhno IPA
    ipa_path = find_latest_potuzhno_ipa()
    if not ipa_path:
        print("\n❌ ОШИБКА: Не удалось найти Potuzhno IPA")
        sys.exit(1)

    # Шаг 3: Внедрить dylib
    result = inject_dylib_into_ipa(ipa_path, dylib_path)
    if result is None or result[0] is None:
        print("\n❌ ОШИБКА: Не удалось собрать IPA")
        sys.exit(1)

    output_ipa, lc_added = result

    # Финальный отчёт
    print_header("✅ СБОРКА ЗАВЕРШЕНА")
    print(f"\n📦 Готовый IPA: {output_ipa}")
    print(f"📊 Размер: {output_ipa.stat().st_size / 1024 / 1024:.1f} MB")

    print("\n📝 Что внутри:")
    print("   ✅ Potuzhno патчи (трекеры, приватность, deleted messages, и т.д.)")
    print("   ✅ MAXMods.dylib (фикс зависания при долгом тапе)")

    if lc_added:
        print("   ✅ LC_LOAD_DYLIB добавлен автоматически")
    else:
        print("   ⚠️  LC_LOAD_DYLIB НЕ добавлен (нужно добавить вручную)")
        print("\n🔧 Для добавления LC_LOAD_DYLIB:")
        print("   1. Установи insert_dylib:")
        print("      https://github.com/Tyilo/insert_dylib")
        print("   2. Запусти:")
        print(f"      insert_dylib '@executable_path/Frameworks/MAXMods.dylib' \\")
        print(f"                   'Payload/MAX.app/MAX' {output_ipa}")

    print("\n📱 Следующие шаги:")
    print("   1. Подпиши IPA через Sideloadly/AltStore/ESign")
    print("   2. Установи на устройство")
    print("   3. Проверь логи: Settings → MaxMods → View Logs")

    print("\n" + "═" * 70)

if __name__ == "__main__":
    main()
