# -*- coding: utf-8 -*-
# 打 Temu 插件运行时文件为 zip（UTF-8 文件名，跨平台一致）。
# 脚本本身放在插件目录【外】，避免以下划线/中文文件名污染扩展目录。
import zipfile, os, sys

SRC = r'E:\project\temu\temu-plugin'
OUT = r'E:\project\temu\temu-plugin-v22.3-库存归零+B路径假上架静默恢复.zip'
RUNTIME = [
    'manifest.json', 'background.js', 'content.js', 'content-front.js',
    'inject.js', 'logger.js', 'feishuApp.js', 'popup.html', 'popup.js',
    'options.html', 'options.js', '使用说明.txt',
]

missing = [f for f in RUNTIME if not os.path.isfile(os.path.join(SRC, f))]
if missing:
    print('缺文件:', missing); sys.exit(1)

if os.path.exists(OUT):
    os.remove(OUT)

with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in RUNTIME:
        z.write(os.path.join(SRC, f), f)  # arcname 原名；中文自动 UTF-8 + flag bit11

sz = os.path.getsize(OUT)
print('生成:', OUT)
print('大小: %.1f KB' % (sz / 1024))
print('--- 包内容 ---')
with zipfile.ZipFile(OUT) as z:
    for i in z.infolist():
        print('%-24s %8d bytes  utf8=%s' % (i.filename, i.file_size, bool(i.flag_bits & 0x800)))
