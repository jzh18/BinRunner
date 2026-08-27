#!/usr/bin/env bash
# sign-hap.sh — 用 hap-sign-tool 给未签名 HAP 签名（自助签名脚本）
#
# 用法:
#   scripts/sign-hap.sh <输入.hap> <输出.hap> [证书目录]
#
# 参数:
#   输入.hap    未签名的 HAP（如 nightly release 里的 binrunner-unsigned.hap）
#   输出.hap    签名后的 HAP
#   证书目录    含 debug.cer / debug.p7b / debug.p12，默认 .build/keystore
#
# 环境变量（密码一律走环境变量，不落命令行历史）:
#   KEYSTORE_PWD   必填，keystore(.p12) 密码
#   KEY_ALIAS      必填，keystore 私钥别名
#   KEY_PWD        可选，key 密码（缺省同 KEYSTORE_PWD）
#   SIGN_ALG       可选，签名算法，默认 SHA256withECDSA
#   HAP_SIGN_TOOL  可选，hap-sign-tool.jar 显式路径
#   DEVECO_SDK_HOME 可选，DevEco SDK 根目录（用于自动定位 jar）
#
# 示例:
#   KEYSTORE_PWD='xxx' KEY_ALIAS=debugKey \
#     scripts/sign-hap.sh binrunner-unsigned.hap binrunner-signed.hap ./certs
set -euo pipefail

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 2 ] || usage

IN_HAP=$1
OUT_HAP=$2
CERT_DIR=${3:-.build/keystore}

: "${KEYSTORE_PWD:?需要环境变量 KEYSTORE_PWD（keystore 密码）}"
: "${KEY_ALIAS:?需要环境变量 KEY_ALIAS（私钥别名）}"
KEY_PWD=${KEY_PWD:-$KEYSTORE_PWD}
SIGN_ALG=${SIGN_ALG:-SHA256withECDSA}

for f in "$CERT_DIR/debug.cer" "$CERT_DIR/debug.p7b" "$CERT_DIR/debug.p12"; do
  [ -f "$f" ] || { echo "ERROR: 缺少 $f（证书目录: $CERT_DIR）" >&2; exit 1; }
done
[ -f "$IN_HAP" ] || { echo "ERROR: 输入文件不存在: $IN_HAP" >&2; exit 1; }

# 定位 hap-sign-tool.jar：显式指定 > 常见 SDK 路径 > 全盘兜底
JAR=${HAP_SIGN_TOOL:-}
if [ -z "$JAR" ]; then
  CANDIDATES=(
    "${DEVECO_SDK_HOME:-$HOME/.local/opt/hmos-commandline-tools/sdk}/default/openharmony/toolchains/lib/hap-sign-tool.jar"
    "/opt/harmonyos-sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
    "${OHOS_NDK:-/nonexistent}/../toolchains/lib/hap-sign-tool.jar"
  )
  for c in "${CANDIDATES[@]}"; do
    [ -f "$c" ] && JAR=$c && break
  done
fi
if [ -z "$JAR" ]; then
  JAR=$(find /opt "$HOME/.local/opt" /usr/local -name 'hap-sign-tool.jar' -type f 2>/dev/null | head -1)
fi
[ -n "$JAR" ] && [ -f "$JAR" ] || { echo "ERROR: 找不到 hap-sign-tool.jar；请设 HAP_SIGN_TOOL 或 DEVECO_SDK_HOME" >&2; exit 1; }

echo "jar:        $JAR"
echo "in:         $IN_HAP"
echo "out:        $OUT_HAP"
echo "cert dir:   $CERT_DIR"
echo "sign alg:   $SIGN_ALG"

java -jar "$JAR" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT_DIR/debug.cer" \
  -profileFile "$CERT_DIR/debug.p7b" \
  -profileSigned 1 \
  -inFile "$IN_HAP" \
  -signAlg "$SIGN_ALG" \
  -keystoreFile "$CERT_DIR/debug.p12" \
  -keystorePwd "$KEYSTORE_PWD" \
  -outFile "$OUT_HAP" \
  -compatibleVersion 8 \
  -signCode 1

echo "OK: $OUT_HAP ($(stat -c%s "$OUT_HAP") bytes)"
unzip -l "$OUT_HAP" >/dev/null && echo "valid zip"
