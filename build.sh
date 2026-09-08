#!/bin/bash
# 一键构建 BinRunner wheel 包
# 用法:
#   export DEVECO_SDK_HOME="/path/to/sdk"   # HarmonyOS SDK 根目录
#   export OHOS_NDK="$DEVECO_SDK_HOME/default/openharmony/native"
#   ./build.sh
# 产物: dist/binrunner-*.whl
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 环境变量检查
if [ -z "$DEVECO_SDK_HOME" ]; then
  echo "请设置 DEVECO_SDK_HOME 指向 HarmonyOS SDK 根目录"
  echo "  例: export DEVECO_SDK_HOME=/path/to/sdk"
  exit 1
fi
if [ -z "$OHOS_NDK" ]; then
  echo "请设置 OHOS_NDK 指向 OHOS native SDK"
  echo "  例: export OHOS_NDK=\$DEVECO_SDK_HOME/default/openharmony/native"
  exit 1
fi

export PATH="$OHOS_NDK/llvm/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"

# 检查必需工具
for cmd in ohpm hvigorw aarch64-unknown-linux-ohos-clang; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "未找到 $cmd，请确认 Command Line Tools 已安装且 PATH 正确"
    exit 1
  fi
done

echo "=== Step 1/3: Build hello binary ==="
bash examples/hello/build.sh

echo ""
echo "=== Step 2/3: Build base HAP ==="

# App 版本与 Python 包版本联动：versionName/versionCode 取自 binrunner.__version__
python3 scripts/sync_app_version.py

# 签名证书（hvigor 在 certpath 父目录下找 material/ 子目录）
# 脱敏：CI/发布签名证书与密码经环境变量（GitHub Secrets）注入，仓库不落私钥明文。
#   证书来源优先级：
#     1) BINRUNNER_KEYSTORE_B64 / BINRUNNER_PROFILE_B64 / BINRUNNER_CERT_B64（base64，CI/发布）
#     2) 仓库 .github/docker/certs/（本地开发回退，勿提交生产私钥）
#     3) openssl 自签（仅本地一次性调试，生成的 p7b 为空，不可安装）
#   密码：KEYSTORE_PWD / KEY_ALIAS / KEY_PWD（若未设，回退到 build-profile.json5 原有值）
KEY_DIR="$SCRIPT_DIR/.build/keystore"
CI_CERT_DIR="$SCRIPT_DIR/.github/docker/certs"

if [ ! -f "$KEY_DIR/debug.p12" ]; then
  mkdir -p "$KEY_DIR" "$KEY_DIR/material"

  # 1) 从环境变量（Secrets）还原签名材料
  if [ -n "${BINRUNNER_KEYSTORE_B64:-}" ] && [ -n "${BINRUNNER_PROFILE_B64:-}" ] && [ -n "${BINRUNNER_CERT_B64:-}" ]; then
    echo "使用 Secrets 签名证书（base64 还原）..."
    echo "$BINRUNNER_KEYSTORE_B64" | base64 -d > "$KEY_DIR/debug.p12"
    echo "$BINRUNNER_PROFILE_B64"  | base64 -d > "$KEY_DIR/debug.p7b"
    echo "$BINRUNNER_CERT_B64"     | base64 -d > "$KEY_DIR/debug.cer"
  elif [ -f "$CI_CERT_DIR/debug.p12" ] && [ -f "$CI_CERT_DIR/debug.cer" ]; then
    echo "使用项目 CI 签名证书（本地回退）..."
    cp -r "$CI_CERT_DIR"/* "$KEY_DIR/" 2>/dev/null || true
  else
    PASS="12345678901234567890123456789012"
    echo "生成 debug 签名证书（openssl，仅本地调试，p7b 为空不可安装）..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_DIR/debug.key" 2>/dev/null
    openssl req -new -x509 -key "$KEY_DIR/debug.key" -out "$KEY_DIR/debug.cer" \
      -days 3650 -subj "/CN=BinRunner CI" 2>/dev/null
    openssl pkcs12 -export -in "$KEY_DIR/debug.cer" -inkey "$KEY_DIR/debug.key" \
      -out "$KEY_DIR/debug.p12" -passout pass:"$PASS" 2>/dev/null
    touch "$KEY_DIR/debug.p7b"
  fi
  cp "$KEY_DIR"/debug.* "$KEY_DIR/material/" 2>/dev/null || true
  chmod 600 "$KEY_DIR"/*.p12 2>/dev/null || true
  echo "debug certificate: $KEY_DIR"
fi

# 签名方式分流：
#   CI/发布（有 Secrets，真实短密码）→ 清空 signingConfigs 让 hvigor 产「未签名 HAP」，
#     再改用 hap-sign-tool 签名（hap-sign-tool 接受任意长度密码；hvigor 内嵌签名要求
#     storePassword/keyPassword ≥32 字符或 DevEco 加密串，注入短明文会报 00303116）。
#   本地（无 Secrets）→ 保留 build-profile 的 signingConfigs，走 hvigor 内嵌签名
#     （openssl 回退自签用的就是 32 字符密码，见上方 PASS）。
STORE_PWD="${KEYSTORE_PWD:-}"
KEY_ALIAS_INJ="${KEY_ALIAS:-}"
KEY_PWD_INJ="${KEY_PWD:-$STORE_PWD}"

CI_SIGN=0
if [ -n "${BINRUNNER_KEYSTORE_B64:-}" ] && [ -n "${BINRUNNER_PROFILE_B64:-}" ] \
   && [ -n "${BINRUNNER_CERT_B64:-}" ] && [ -n "$STORE_PWD" ]; then
  CI_SIGN=1
  echo "CI 签名模式：构建未签名 HAP，随后用 hap-sign-tool 签名"
  python3 - <<'PYEOF'
import re
from pathlib import Path
p = Path("app/build-profile.json5")
s = p.read_text(encoding="utf-8")
s = re.sub(r'"signingConfigs"\s*:\s*\[.*?\]', '"signingConfigs": []', s, flags=re.S)
s = re.sub(r'\s*"signingConfig"\s*:\s*"[^"]*",?', '', s)
p.write_text(s, encoding="utf-8")
PYEOF
  HAP_SIGN_TOOL="${HAP_SIGN_TOOL:-}"
  if [ -z "$HAP_SIGN_TOOL" ] && [ -n "$DEVECO_SDK_HOME" ]; then
    HAP_SIGN_TOOL="$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar"
  fi
  if [ -z "$HAP_SIGN_TOOL" ] || [ ! -f "$HAP_SIGN_TOOL" ]; then
    HAP_SIGN_TOOL=$(find /opt "$SCRIPT_DIR" -name hap-sign-tool.jar 2>/dev/null | head -n 1 || true)
  fi
  if [ -z "$HAP_SIGN_TOOL" ] || [ ! -f "$HAP_SIGN_TOOL" ]; then
    echo "未找到 hap-sign-tool.jar（可设 HAP_SIGN_TOOL 指定）" >&2
    exit 1
  fi
  echo "hap-sign-tool: $HAP_SIGN_TOOL"
else
  SED_ARGS=(
    -e "s|\"certpath\": \".*\"|\"certpath\": \"$KEY_DIR/debug.cer\"|"
    -e "s|\"profile\": \".*\"|\"profile\": \"$KEY_DIR/debug.p7b\"|"
    -e "s|\"storeFile\": \".*\"|\"storeFile\": \"$KEY_DIR/debug.p12\"|"
  )
  [ -n "$STORE_PWD" ] && SED_ARGS+=(-e "s|\"storePassword\": \".*\"|\"storePassword\": \"$STORE_PWD\"|")
  [ -n "$KEY_ALIAS_INJ" ] && SED_ARGS+=(-e "s|\"keyAlias\": \".*\"|\"keyAlias\": \"$KEY_ALIAS_INJ\"|")
  [ -n "$KEY_PWD_INJ" ] && SED_ARGS+=(-e "s|\"keyPassword\": \".*\"|\"keyPassword\": \"$KEY_PWD_INJ\"|")
  sed -i.bak "${SED_ARGS[@]}" app/build-profile.json5
fi

rm -f app/entry/libs/arm64-v8a/libbenchmark.so
rm -f app/entry/libs/arm64-v8a/libmindspore-lite.so
rm -f app/entry/src/main/resources/rawfile/mobilenetv2.ms
cd app
ohpm install --all
hvigorw assembleApp --mode project -p product=default -p buildMode=debug --no-daemon

if [ "$CI_SIGN" -eq 1 ]; then
  # hvigor 产出的是未签名 HAP，这里用 Secrets 还原的证书/Profile 签名。
  # 输出沿用 hvigor 的 entry-default-signed.hap 命名，Step 3 复制逻辑不变。
  echo "=== CI 签名（hap-sign-tool）==="
  UNSIGNED=entry/build/default/outputs/default/entry-default-unsigned.hap
  SIGNED_OUT=entry/build/default/outputs/default/entry-default-signed.hap
  [ -f "$UNSIGNED" ] || { echo "未找到未签名 HAP: $UNSIGNED" >&2; exit 1; }
  java -jar "$HAP_SIGN_TOOL" sign-app \
    -mode localSign \
    -keyAlias "$KEY_ALIAS_INJ" \
    -keyPwd "$KEY_PWD_INJ" \
    -appCertFile "$SCRIPT_DIR/.build/keystore/debug.cer" \
    -profileFile "$SCRIPT_DIR/.build/keystore/debug.p7b" \
    -profileSigned 1 \
    -inFile "$UNSIGNED" \
    -signAlg "${SIGN_ALG:-SHA256withECDSA}" \
    -keystoreFile "$SCRIPT_DIR/.build/keystore/debug.p12" \
    -keystorePwd "$STORE_PWD" \
    -outFile "$SIGNED_OUT" \
    -compatibleVersion 8 \
    -signCode 1
  echo "CI 签名完成：$SIGNED_OUT"
else
  # 本地：恢复原签名路径
  mv app/build-profile.json5.bak app/build-profile.json5
fi
cd "$SCRIPT_DIR"

echo ""
echo "=== Step 3/3: Copy artifacts & build wheel ==="
mkdir -p binrunner/data
cp app/entry/build/default/outputs/default/entry-default-signed.hap binrunner/data/binrunner.hap
cp examples/hello/hello binrunner/data/hello
python3 -m pip install --quiet build 2>/dev/null
python3 -m build

echo ""
ls -lh dist/*.whl
echo "Done."
