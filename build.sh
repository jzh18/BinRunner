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

# 更新签名路径 + 密码（密码/别名经环境变量注入，避免明文入库）
STORE_PWD="${KEYSTORE_PWD:-}"
KEY_ALIAS_INJ="${KEY_ALIAS:-}"
KEY_PWD_INJ="${KEY_PWD:-}"
SED_ARGS="-e s|\"certpath\": \".*\"|\"certpath\": \"$KEY_DIR/debug.cer\"|"
SED_ARGS="$SED_ARGS -e s|\"profile\": \".*\"|\"profile\": \"$KEY_DIR/debug.p7b\"|"
SED_ARGS="$SED_ARGS -e s|\"storeFile\": \".*\"|\"storeFile\": \"$KEY_DIR/debug.p12\"|"
if [ -n "$STORE_PWD" ]; then SED_ARGS="$SED_ARGS -e s|\"storePassword\": \".*\"|\"storePassword\": \"$STORE_PWD\"|"; fi
if [ -n "$KEY_ALIAS_INJ" ]; then SED_ARGS="$SED_ARGS -e s|\"keyAlias\": \".*\"|\"keyAlias\": \"$KEY_ALIAS_INJ\"|"; fi
if [ -n "$KEY_PWD_INJ" ]; then SED_ARGS="$SED_ARGS -e s|\"keyPassword\": \".*\"|\"keyPassword\": \"$KEY_PWD_INJ\"|"; fi
# shellcheck disable=SC2086
sed -i.bak $SED_ARGS app/build-profile.json5

rm -f app/entry/libs/arm64-v8a/libbenchmark.so
rm -f app/entry/libs/arm64-v8a/libmindspore-lite.so
rm -f app/entry/src/main/resources/rawfile/mobilenetv2.ms
cd app
ohpm install --all
hvigorw assembleApp --mode project -p product=default -p buildMode=debug --no-daemon
cd "$SCRIPT_DIR"

# 恢复原签名路径
mv app/build-profile.json5.bak app/build-profile.json5

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
