#!/usr/bin/env bash
# 把无签名构建出的 StS2.app 打成可分发的 IPA（含完整游戏内容，自包含）。
# 默认 ad-hoc 签名，并把 increased-memory-limit 内嵌进签名，便于用户用自己的证书重签后侧载。
# 用法: bash ios-export/make-ipa.sh [app路径] [输出.ipa]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

APP="${1:-$SCRIPT_DIR/.work/dd/Build/Products/Release-iphoneos/StS2.app}"
OUT="${2:-$SCRIPT_DIR/build/StS2.ipa}"

fail(){ echo "❌ $1" >&2; exit 1; }
[ -d "$APP" ] || fail "找不到 .app: $APP（先跑无签名 xcodebuild）"
[ -f "$APP/StS2.pck" ] || fail "$APP 内没有 StS2.pck（不是自包含）"

# 签名身份：能解析到有效证书就用它，否则 ad-hoc('-')（用户重签时会被替换）
IDENT="-"
if [ -n "${STS2_SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$STS2_SIGN_IDENTITY"; then
  IDENT="$STS2_SIGN_IDENTITY"
fi
echo "▶ 签名身份: $IDENT"

# 只内嵌大内存权限；application-identifier/team-id 等交给重签工具用真实 profile 生成
EMB_ENT="$(mktemp -t ent)"
cat > "$EMB_ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
</dict></plist>
EOF

STAGE="$(mktemp -d)/ipa"
mkdir -p "$STAGE/Payload"
echo "▶ 拷贝 .app（APFS 克隆，快且不额外占盘）…"
cp -Rc "$APP" "$STAGE/Payload/StS2.app" 2>/dev/null || cp -R "$APP" "$STAGE/Payload/StS2.app"

# iOS 27 起,用 iOS 27 SDK 链接的 App 若未采用 UIScene 生命周期会在启动时被系统 trap 杀掉
# (EXC_BREAKPOINT / UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption)。
# Godot 4.5.1 引擎尚无 UIScene 支持(4.7 才有),而升级 Godot 会破坏 C#/GDExtension ABI。
# 该门槛只针对"用 27 SDK 构建"的 App: 把可执行文件的 LC_BUILD_VERSION sdk 重新戳为 26.5,
# 即绕过此门槛,其余行为不变(引擎原本在 iOS<=26 生命周期下工作正常)。
APPBIN="$STAGE/Payload/StS2.app/StS2"
echo "▶ 重戳可执行文件 SDK 版本 → 26.5（绕过 iOS 27 UIScene 强制）…"
if xcrun vtool -set-build-version ios 15.0 26.5 -replace -output "$APPBIN.vt" "$APPBIN" 2>/dev/null; then
  mv "$APPBIN.vt" "$APPBIN"; chmod +x "$APPBIN"
  plutil -replace DTSDKName -string "iphoneos26.5" "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null
  plutil -replace DTPlatformVersion -string "26.5" "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null
  # 递增 build 号,确保重装覆盖旧版(否则可能装到缓存旧包)
  plutil -replace CFBundleVersion -string "0.107.2" "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null
  # 标记为游戏 → 启用 iOS/iPadOS Game Mode(仅 Info.plist,无需 entitlement/profile)
  plutil -replace LSSupportsGameMode -bool true "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null
  plutil -replace LSApplicationCategoryType -string "public.app-category.games" "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null
  xcrun vtool -show-build "$APPBIN" 2>/dev/null | grep -E "sdk|minos" | sed 's/^/  /'
else
  echo "  ! vtool 失败,继续(可能仍会在 iOS 27 上崩溃)"
fi

echo "▶ 签名内嵌框架…"
for fw in "$STAGE/Payload/StS2.app/Frameworks/"*.framework; do
  [ -d "$fw" ] || continue
  codesign -f -s "$IDENT" --generate-entitlement-der "$fw" >/dev/null 2>&1 || fail "签框架失败: $fw"
done

echo "▶ 签名主 App（内嵌 increased-memory-limit）…"
codesign -f -s "$IDENT" --generate-entitlement-der --entitlements "$EMB_ENT" "$STAGE/Payload/StS2.app" \
  >/dev/null 2>&1 || fail "签 .app 失败"
codesign -d --entitlements - "$STAGE/Payload/StS2.app" 2>/dev/null | grep -q increased-memory \
  && echo "  ✓ increased-memory-limit 已内嵌" || echo "  ! 未检出 increased-memory-limit"

echo "▶ 打包 IPA（zip -1，约 2G，需几分钟）…"
rm -f "$OUT"
( cd "$STAGE" && zip -qry -1 "$OUT" Payload ) || fail "打包 zip 失败"

BID=$(plutil -extract CFBundleIdentifier raw "$STAGE/Payload/StS2.app/Info.plist" 2>/dev/null)
echo "✅ 完成: $OUT"
echo "   大小: $(du -h "$OUT" | cut -f1)   bundle: $BID"
echo "   说明: 用你的证书重签后侧载；如重签工具不会自动带 increased-memory-limit,"
echo "        请在签名时勾选/注入大内存权限(见 .work/ent_mem.plist)。"
