"""Read-only identity checks for the Heartbeat test app, on Windows and CI."""
import argparse
from pathlib import Path
import plistlib
import re

APP_ID = "com.koyamahuan.kelivo.heartbeat"
EXTENSION_ID = APP_ID + ".GenerationActivityExtension"
DISPLAY_NAME = "Kelivo Heartbeat"
OLD_ID = "psyche.kelivo"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plist(path):
    with path.open("rb") as source:
        return plistlib.load(source)


def validate_source(root):
    ios = root / "ios"
    project = (ios / "Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    objects = dict(re.findall(
        r'^\t\t([A-Fa-f0-9]{24}) /\*[^\n]*\*/ = \{\n(.*?)^\t\t\};',
        project, re.M | re.S,
    ))
    targets = {}
    for object_id, body in objects.items():
        if "isa = PBXNativeTarget;" in body:
            name = re.search(r"\bname = (\w+);", body)[1]
            targets[name] = (object_id, body)
    require(set(targets) == {"Runner", "RunnerTests", "GenerationActivityExtension"}, "Unexpected iOS targets")
    for name, expected in {"Runner": APP_ID, "RunnerTests": APP_ID + ".RunnerTests", "GenerationActivityExtension": EXTENSION_ID}.items():
        body = targets[name][1]
        config_list = re.search(r"buildConfigurationList = (\w+)", body)[1]
        config_ids = re.findall(r"(\w{24}) /\* (?:Debug|Release|Profile) \*/", objects[config_list])
        require(len(config_ids) == 3, name + " must have three build configurations")
        for config_id in config_ids:
            config = objects[config_id]
            require(re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", config)[1].strip('"') == expected, name + " bundle identity mismatch")
            require('PRODUCT_NAME = "$(TARGET_NAME)";' in config, name + " product name changed")
            require("CODE_SIGN_ENTITLEMENTS" not in config, "Unexpected signing entitlement: review before releasing")
    extension_target = targets["GenerationActivityExtension"][0]
    runner = targets["Runner"][1]
    dependency_ids = re.findall(r"(\w{24}) /\* PBXTargetDependency \*/", runner)
    require(any(f"target = {extension_target}" in objects[item] for item in dependency_ids), "Runner extension dependency missing")
    embed_ids = re.findall(r"(\w{24}) /\* Embed App Extensions \*/", runner)
    require(len(embed_ids) == 1, "Runner extension embed phase missing")
    embed = objects[embed_ids[0]]
    require("dstSubfolderSpec = 13;" in embed and "GenerationActivityExtension.appex in Embed App Extensions" in embed, "Extension must embed in PlugIns")
    require('path = GenerationActivityExtension.appex;' in project, "Extension product missing")
    require(not list(ios.rglob("*.entitlements")), "Unexpected entitlement file: review capabilities and containers")
    require("com.apple.security.application-groups" not in project and "keychain-access-groups" not in project, "Unexpected shared container")
    for path in ios.rglob("*"):
        if path.is_file():
            require(OLD_ID.encode() not in path.read_bytes(), "Old runtime identity in " + str(path.relative_to(root)))
    main = plist(ios / "Runner/Info.plist")
    extension = plist(ios / "GenerationActivityExtension/Info.plist")
    for info in (main, extension):
        require(info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)", "Source plist bundle identity must use target setting")
        require(info["CFBundleDisplayName"] == DISPLAY_NAME, "Display name mismatch")
    require(extension["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension", "WidgetKit extension type changed")
    urls = main["CFBundleURLTypes"]
    require(len(urls) == 1 and urls[0]["CFBundleURLName"] == APP_ID + ".oauth-return", "OAuth URL name mismatch")
    require(set(urls[0]["CFBundleURLSchemes"]) == {"kelivo-heartbeat", APP_ID}, "OAuth schemes must be isolated")
    background = {APP_ID + ".background-generation." + suffix for suffix in ("refresh", "processing")}
    require(set(main["BGTaskSchedulerPermittedIdentifiers"]) == background, "Background task plist identifiers mismatch")
    delegate = (ios / "Runner/AppDelegate.swift").read_text(encoding="utf-8")
    for identifier in background:
        require(delegate.count('"' + identifier + '"') == 1, "Background task runtime identifier mismatch")
    oauth = (root / "lib/core/services/mcp/mcp_oauth_callback_io.dart").read_text(encoding="utf-8")
    ios_callback = oauth.split("final class _IosMcpOAuthCallback", 1)[1].split("final class _IoMcpOAuthCallback", 1)[0]
    require("scheme: '" + APP_ID + "'" in ios_callback and OLD_ID not in ios_callback, "iOS OAuth callback identity mismatch")
    scheme = (ios / "Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme").read_text(encoding="utf-8")
    require('BuildableName = "Runner.app"' in scheme and 'buildImplicitDependencies = "YES"' in scheme, "Runner scheme dependency configuration changed")


def validate_app(app):
    require(app.is_dir(), "Payload/Runner.app missing")
    extension = app / "PlugIns/GenerationActivityExtension.appex"
    require(extension.is_dir(), "Embedded GenerationActivityExtension.appex missing")
    require(sorted(item.name for item in (app / "PlugIns").glob("*.appex")) == [extension.name], "Unexpected app extensions")
    for path, expected in ((app, APP_ID), (extension, EXTENSION_ID)):
        info = plist(path / "Info.plist")
        require(info.get("CFBundleIdentifier") == expected, path.name + " compiled bundle identity mismatch")
        require(info.get("CFBundleDisplayName") == DISPLAY_NAME, path.name + " compiled display name mismatch")
        executable = info.get("CFBundleExecutable", "")
        require(bool(executable) and Path(executable).name == executable, "Invalid bundle executable name")
        require((path / executable).is_file() and (path / executable).stat().st_size > 0, "Bundle executable missing")
    require(plist(extension / "Info.plist")["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension", "Compiled extension type mismatch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        validate_source(Path(__file__).resolve().parents[1])
        if args.app:
            validate_app(args.app)
    except (ValueError, KeyError, OSError, IndexError, TypeError) as error:
        parser.exit(1, "iOS identity validation FAILED: " + str(error) + "\n")
    print("iOS source identity validated" + ("; embedded app identity validated" if args.app else " (Xcode build not performed)"))
