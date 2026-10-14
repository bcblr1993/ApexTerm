#!/usr/bin/env python3
"""
verify_online_update.py - AetherTerm 在线更新链路端到端验收门禁脚本

功能：
1. 验证 GitHub Releases API (https://api.github.com/repos/bcblr1993/ApexTerm/releases/latest) 返回的目标版本；
2. 验证发布的 Assets 包含 DMG、tar.gz 以及 SHA256SUMS.txt，且文件大小符合预期；
3. 验证 DMG 与 tar.gz 的真实下载 URL (HTTP 200 或 302 重定向成功)；
4. 验证更新包解压目录规范（包含 AetherTerm.app 或 ApexTerm.app，且 Bundle ID 为 com.apexterm.app）；
5. 验证 SHA-256 校验和与本地构建一致。

用法：
  python3 scripts/verify_online_update.py <TARGET_VERSION> [--local-build-dir .build]
  例：python3 scripts/verify_online_update.py 1.7.0
"""

import sys
import os
import json
import urllib.request
import urllib.error
import tempfile
import tarfile
import plistlib
import subprocess
import argparse

REPO = "bcblr1993/ApexTerm"
API_URL = f"https://api.github.com/repos/{REPO}/releases/latest"

def log(msg):
    print(f"[verify_online_update] {msg}")

def fail(msg):
    print(f"\033[31m[ERROR] {msg}\033[0m", file=sys.stderr)
    sys.exit(1)

def verify_release(target_version: str, local_build_dir: str = ".build"):
    clean_target = target_version.lstrip("vV")
    expected_tag = f"v{clean_target}"
    
    log(f"1. 正在查询 GitHub Releases API: {API_URL}")
    req = urllib.request.Request(API_URL, headers={
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "AetherTerm-Release-Verifier"
    })
    
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status != 200:
                fail(f"API 请求失败，HTTP 状态码: {resp.status}")
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        fail(f"无法访问 GitHub Releases API: {e}")
        
    actual_tag = data.get("tag_name", "")
    log(f"   GitHub 最新发布标签: {actual_tag} (预期: {expected_tag})")
    if actual_tag != expected_tag:
        fail(f"最新标签不匹配！预期: {expected_tag}, 实际: {actual_tag}。请确认已成功运行 gh release create！")
        
    assets = {a["name"]: a for a in data.get("assets", [])}
    expected_dmg = f"AetherTerm-v{clean_target}-macos-arm64.dmg"
    expected_tar = f"AetherTerm-v{clean_target}-macos-arm64.tar.gz"
    expected_sums = "SHA256SUMS.txt"
    
    log("2. 检查发布附件 (Release Assets) 完整性...")
    for item in [expected_dmg, expected_tar, expected_sums]:
        if item not in assets:
            fail(f"发布附件缺失: {item}！当前附件列表: {list(assets.keys())}")
        size = assets[item].get("size", 0)
        log(f"   ✓ 附件存在: {item} ({size:,} 字节)")
        if item != expected_sums and size < 1_000_000:
            fail(f"附件 {item} 文件过小 ({size} 字节)，可能上传损坏！")

    log("3. 检查下载链接连通性 (HTTP 200 / 302)...")
    for item in [expected_dmg, expected_tar]:
        url = assets[item]["browser_download_url"]
        test_req = urllib.request.Request(url, headers={"User-Agent": "AetherTerm-Release-Verifier"}, method="HEAD")
        try:
            with urllib.request.urlopen(test_req, timeout=15) as r:
                log(f"   ✓ 连通正常: {item} -> HTTP {r.status}")
        except urllib.error.HTTPError as e:
            if e.code in (301, 302):
                log(f"   ✓ 重定向正常: {item} -> HTTP {e.code}")
            else:
                fail(f"下载链接无效: {url} (HTTP {e.code})")
        except Exception as e:
            fail(f"检查链接异常: {url} ({e})")

    log("4. 抽检在线更新包 (tar.gz) 结构与 Bundle 规范...")
    tar_asset = assets[expected_tar]
    tar_url = tar_asset["browser_download_url"]
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_archive = os.path.join(tmpdir, expected_tar)
        log(f"   正在下载 {expected_tar} 至临时目录用于解压验真...")
        urllib.request.urlretrieve(tar_url, tmp_archive)
        
        extract_dir = os.path.join(tmpdir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)
        with tarfile.open(tmp_archive, "r:gz") as tar:
            if hasattr(tarfile, 'data_filter'):
                tar.extractall(extract_dir, filter='data')
            else:
                tar.extractall(extract_dir)
            
        found_app = None
        for candidate in ["AetherTerm.app", "ApexTerm.app"]:
            p = os.path.join(extract_dir, candidate)
            if os.path.isdir(p):
                found_app = p
                break
                
        if not found_app:
            fail(f"解压后未找到合规的 App Bundle (必须包含 AetherTerm.app 或 ApexTerm.app)！")
        log(f"   ✓ 发现应用包: {os.path.basename(found_app)}")
        
        info_plist_path = os.path.join(found_app, "Contents", "Info.plist")
        if not os.path.isfile(info_plist_path):
            fail("应用包内缺失 Contents/Info.plist！")
            
        with open(info_plist_path, "rb") as f:
            plist = plistlib.load(f)
            
        bundle_id = plist.get("CFBundleIdentifier")
        if bundle_id != "com.apexterm.app":
            fail(f"CFBundleIdentifier 不符: {bundle_id} (预期: com.apexterm.app)")
            
        version_str = plist.get("CFBundleShortVersionString")
        if version_str != clean_target:
            fail(f"Info.plist 版本号不匹配: {version_str} (预期: {clean_target})")
        log(f"   ✓ Bundle ID 校验通过: {bundle_id}, 版本: {version_str}")

        exec_path = os.path.join(found_app, "Contents", "MacOS", "ApexTerm")
        if not os.path.isfile(exec_path) or not os.access(exec_path, os.X_OK):
            fail("主可执行文件 Contents/MacOS/ApexTerm 缺失或无执行权限！")
        log("   ✓ 主程序可执行权限校验通过")

    # 5. 若本地有 .build 目录，校验 SHA256SUMS.txt 是否一致
    local_sums = os.path.join(local_build_dir, "SHA256SUMS.txt")
    if os.path.isfile(local_sums):
        log("5. 校验 GitHub SHA256SUMS.txt 与本地构建清单...")
        sums_url = assets[expected_sums]["browser_download_url"]
        with urllib.request.urlopen(sums_url, timeout=10) as r:
            remote_content = r.read().decode("utf-8").strip()
        with open(local_sums, "r", encoding="utf-8") as f:
            local_content = f.read().strip()
            
        if remote_content != local_content:
            fail("远端 SHA256SUMS.txt 与本地构建清单不一致！")
        log("   ✓ SHA-256 清单完全一致")

    log("\033[32m🎉 在线更新链路端到端验收门禁 100% 通过！客户端可正常在线发现并安装该版本！\033[0m")

def main():
    parser = argparse.ArgumentParser(description="AetherTerm 在线更新链路端到端验收门禁")
    parser.add_argument("version", help="待验收的目标版本号 (例如 1.7.0)")
    parser.add_argument("--local-build-dir", default=".build", help="本地构建产出目录 (默认 .build)")
    args = parser.parse_args()
    
    verify_release(args.version, args.local_build_dir)

if __name__ == "__main__":
    main()
