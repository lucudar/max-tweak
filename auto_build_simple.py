#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Упрощённый сборщик MAX IPA
===========================
1. Берёт последний Potuzhno IPA из папки rev
2. Распаковывает его
3. Подготавливает структуру для внедрения dylib
4. Ждёт dylib от пользователя или скачивает из GitHub если доступен
"""
import os
import sys
import zipfile
import shutil
import urllib.request
import json
from pathlib import Path
from datetime import datetime

# Фикс кодировки для Windows
if sys.platform == 'win32':
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'strict')
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.buffer, 'strict')

# === КОНФИГУРАЦИЯ ===
REV_FOLDER = Path.home() / "Downloads/вся хуйня/вся хуйня/rev/rev"
OUTPUT_DIR = Path("output")
DYLIB_NAME = "MAXMods.dylib"
GITHUB_REPO = "lucudar/max-tweak"

class Colors:
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    RESET = '\033[0m'
    BOLD = '\033[1m'

def print_step(num, text):
    print(f"\n{Colors.BLUE}🔹 Шаг {num}: {text}{Colors.RESET}")

def print_success(text):
    print(f"{Colors.GREEN}   ✓ {text}{Colors.RESET}")

def print_error(text):
    print(f"{Colors.RED}   ❌ {text}{Colors.RESET}")

def print_warning(text):
    print(f"{Colors.YELLOW}   ⚠️  {text}{Colors.RESET}")

def find_latest_ipa(folder):
    """Найти последний Potuzhno IPA"""
    if not folder.exists():
        return None

    ipa_files = list(folder.glob("Potuzhno*.ipa"))
    if not ipa_files:
        return None

    # Сортируем по времени модификации
    latest = max(ipa_files, key=lambda p: p.stat().st_mtime)
    return latest

def try_download_dylib():
    """Попытка скачать dylib из GitHub releases"""
    try:
        url = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
        print(f"   📡 Проверяю GitHub releases...")

        req = urllib.request.Request(url)
        req.add_header('User-Agent', 'Python-MAX-Builder')

        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read())

        # Ищем dylib в assets
        for asset in data.get('assets', []):
            if asset['name'].endswith('.dylib'):
                print_success(f"Найден {asset['name']}")
                dylib_url = asset['browser_download_url']

                dylib_path = OUTPUT_DIR / DYLIB_NAME
                print(f"   📥 Скачиваю {dylib_url}")
                urllib.request.urlretrieve(dylib_url, dylib_path)
                print_success(f"Скачан: {dylib_path}")
                return dylib_path

        return None
    except Exception as e:
        print_warning(f"Не удалось скачать с GitHub: {e}")
        return None

def main():
    print("=" * 70)
    print(f"{Colors.BOLD}  MAX Messenger - Упрощённый сборщик{Colors.RESET}")
    print("=" * 70)
    print(f"📁 Рабочая директория: {Path.cwd()}")
    print(f"📁 Rev папка: {REV_FOLDER}")

    # Создаём output директорию
    OUTPUT_DIR.mkdir(exist_ok=True)

    # Шаг 1: Найти IPA
    print_step(1, "Поиск Potuzhno IPA")
    ipa_path = find_latest_ipa(REV_FOLDER)

    if not ipa_path:
        print_error(f"IPA файл не найден в {REV_FOLDER}")
        print("   💡 Убедитесь, что папка существует и содержит Potuzhno*.ipa")
        return 1

    print_success(f"Найден: {ipa_path.name}")
    print(f"   📊 Размер: {ipa_path.stat().st_size / 1024 / 1024:.1f} MB")

    # Шаг 2: Распаковать IPA
    print_step(2, "Распаковка IPA")
    extract_dir = OUTPUT_DIR / "Payload_extracted"

    if extract_dir.exists():
        shutil.rmtree(extract_dir)
    extract_dir.mkdir()

    with zipfile.ZipFile(ipa_path, 'r') as zip_ref:
        zip_ref.extractall(extract_dir)

    # Найти .app
    app_dir = None
    payload_dir = extract_dir / "Payload"
    if payload_dir.exists():
        apps = list(payload_dir.glob("*.app"))
        if apps:
            app_dir = apps[0]

    if not app_dir:
        print_error("Не найдена Payload/*.app структура")
        return 1

    print_success(f"Распаковано: {app_dir.name}")

    # Шаг 3: Попытка получить dylib
    print_step(3, "Получение MAXMods.dylib")

    dylib_path = try_download_dylib()

    if not dylib_path:
        print_warning("Dylib не скачан автоматически")
        print(f"\n{Colors.YELLOW}📝 НУЖНО СДЕЛАТЬ ВРУЧНУЮ:{Colors.RESET}")
        print(f"   1. Собери dylib на macOS: cd max-tweak && make")
        print(f"   2. Скопируй .theos/obj/MAXMods.dylib сюда")
        print(f"   3. Положи его в: {OUTPUT_DIR / DYLIB_NAME}")
        print(f"   4. Запусти скрипт снова")

        # Проверим, может dylib уже есть
        manual_dylib = OUTPUT_DIR / DYLIB_NAME
        if manual_dylib.exists():
            print_success(f"Dylib уже есть: {manual_dylib}")
            dylib_path = manual_dylib
        else:
            return 0

    # Шаг 4: Внедрение dylib
    print_step(4, "Внедрение dylib в IPA")

    # Создаём папку для dylib
    dylib_folder = app_dir / "Frameworks"
    dylib_folder.mkdir(exist_ok=True)

    # Копируем dylib
    target_dylib = dylib_folder / DYLIB_NAME
    shutil.copy2(dylib_path, target_dylib)
    print_success(f"Dylib скопирован: {target_dylib.relative_to(extract_dir)}")

    # Шаг 5: Упаковка финального IPA
    print_step(5, "Создание финального IPA")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    final_ipa = OUTPUT_DIR / f"MAX_Tweaked_{timestamp}.ipa"

    # Упаковываем обратно
    with zipfile.ZipFile(final_ipa, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(extract_dir):
            for file in files:
                file_path = Path(root) / file
                arcname = file_path.relative_to(extract_dir)
                zipf.write(file_path, arcname)

    print_success(f"IPA создан: {final_ipa}")
    print(f"   📊 Размер: {final_ipa.stat().st_size / 1024 / 1024:.1f} MB")

    # Очистка
    shutil.rmtree(extract_dir)
    print_success("Временные файлы удалены")

    print(f"\n{Colors.GREEN}{Colors.BOLD}✨ ГОТОВО!{Colors.RESET}")
    print(f"📦 Финальный IPA: {final_ipa.absolute()}")
    print(f"\n{Colors.YELLOW}⚠️  ВНИМАНИЕ:{Colors.RESET}")
    print("   Для установки на устройство нужно подписать IPA")
    print("   Используй Sideloadly, AltStore или подобные инструменты")

    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}⚠️  Прервано пользователем{Colors.RESET}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{Colors.RED}❌ ОШИБКА: {e}{Colors.RESET}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
