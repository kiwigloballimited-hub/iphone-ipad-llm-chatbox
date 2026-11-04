"""Summarise an exported .xcloc: list strings that have no translation.

Usage: loc_report.py <localization dir> [--all]
Prints one JSON object per line prefixed with "LOC|" so it is easy to find in CI logs.
"""
import glob
import json
import sys
import xml.etree.ElementTree as ET

NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
root_dir = sys.argv[1]
show_all = "--all" in sys.argv
printed = set()  # 同一个字符串在多种语言里都缺翻译时只列一次

for xliff in sorted(glob.glob(f"{root_dir}/*.xcloc/Localized Contents/*.xliff")):
    tree = ET.parse(xliff)
    language = None
    total = missing = 0
    for file_el in tree.getroot().findall("x:file", NS):
        language = file_el.get("target-language")
        original = file_el.get("original")
        for unit in file_el.iter(f"{{{NS['x']}}}trans-unit"):
            total += 1
            source = unit.find("x:source", NS)
            target = unit.find("x:target", NS)
            translated = target is not None and (target.text or "").strip() != ""
            if not translated:
                missing += 1
            key = (original, unit.get("id"))
            if (show_all or not translated) and key not in printed:
                printed.add(key)
                print("LOC|" + json.dumps({
                    "lang": language,
                    "file": original,
                    "id": unit.get("id"),
                    "source": source.text if source is not None else "",
                    "translated": translated,
                }, ensure_ascii=False))
    print(f"LOCSUMMARY|{language}|total={total}|missing={missing}")
