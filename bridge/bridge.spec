# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

hiddenimports = [
    "waitress",
    "dotenv",
    "flask",
    "jinja2",
    "werkzeug",
    "click",
    "itsdangerous",
    "markupsafe",
]

hiddenimports += collect_submodules("waitress")
hiddenimports += collect_submodules("dotenv")
hiddenimports += collect_submodules("flask")

datas = [
    ("..\\README.md", "."),
    ("..\\LICENSE", "."),
    ("..\\qris-donasi.jpg", "."),
]

datas += collect_data_files("waitress")

a = Analysis(
    ["bridge.py"],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pandas", "scipy"],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="BlackCubeBridge",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)