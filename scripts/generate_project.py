"""Deterministic Xcode project creation; no XcodeGen or CocoaPods required."""
from pathlib import Path
import hashlib
import json
import plistlib
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def obj(key_name, isa, **fields):
    key = uid(key_name)
    objects[key] = dict(isa=isa, **fields)
    return key

def serialize(x):
    if isinstance(x, dict):
        return "{\n" + "\n".join(json.dumps(str(k))+" = "+serialize(v)+";" for k,v in x.items())+"\n}"
    if isinstance(x, list):
        return "("+", ".join(serialize(v) for v in x)+("," if x else "")+")"
    return json.dumps(str(x))

def phase(name, isa, refs):
    return obj(name, isa, buildActionMask=2147483647, files=refs, runOnlyForDeploymentPostprocessing=0)

def configlist(name, settings):
    refs = []
    for mode in ["Debug","Release"]:
        cfg = dict(settings)
        cfg.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode=="Debug" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if mode=="Debug" else "dwarf-with-dsym")
        if mode=="Debug":
            cfg.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
        refs.append(obj(name+mode, "XCBuildConfiguration", buildSettings=cfg, name=mode))
    return obj(name+"configs", "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

def main():
    (ROOT/"Glucklich.xcodeproj/xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)
    source_refs = {}
    for path in sorted(ROOT.glob("**/*.swift")):
        if "Tests" in path.parts: continue
        rel = str(path.relative_to(ROOT))
        source_refs[rel] = obj("ref"+rel, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=rel, sourceTree="<group>")
    demo = obj("demo", "PBXFileReference", lastKnownFileType="text.json", path="Resources/demo_participant.json", sourceTree="<group>")
    assets = obj("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Resources/Assets.xcassets", sourceTree="<group>")
    phoneprod = obj("phoneprod", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="Glucklich.app", sourceTree="BUILT_PRODUCTS_DIR")
    watchprod = obj("watchprod", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="GlucklichWatch.app", sourceTree="BUILT_PRODUCTS_DIR")
    products = obj("products", "PBXGroup", children=[phoneprod,watchprod], name="Products", sourceTree="<group>")
    main_group = obj("main", "PBXGroup", children=list(source_refs.values())+[demo,assets,products], sourceTree="<group>")
    common = dict(CODE_SIGN_STYLE="Automatic", CURRENT_PROJECT_VERSION=1, MARKETING_VERSION="1.1", SWIFT_VERSION="5.0", GENERATE_INFOPLIST_FILE="NO", PRODUCT_NAME="$(TARGET_NAME)", ENABLE_PREVIEWS="YES", ENABLE_USER_SCRIPT_SANDBOXING="YES")
    targets = {}
    for platform, name, product in [("iOS","Glucklich",phoneprod),("Watch","GlucklichWatch",watchprod)]:
        sources = [obj(name+rel,"PBXBuildFile",fileRef=ref) for rel,ref in source_refs.items() if rel.startswith(platform+"/") or rel.startswith("Shared/")]
        resources = [obj(name+"assetbuild","PBXBuildFile",fileRef=assets)]
        if platform=="iOS": resources.append(obj("demobuild","PBXBuildFile",fileRef=demo))
        phases = [phase(name+"sources","PBXSourcesBuildPhase",sources),phase(name+"frameworks","PBXFrameworksBuildPhase",[]),phase(name+"resources","PBXResourcesBuildPhase",resources)]
        settings = dict(common, INFOPLIST_FILE=platform+"/Info.plist", CODE_SIGN_ENTITLEMENTS=platform+"/Glucklich.entitlements", PRODUCT_BUNDLE_IDENTIFIER="edu.rutgers.healthhack.Glucklich"+(".watchkitapp" if platform=="Watch" else ""), ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon")
        if platform=="iOS": settings.update(SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="17.0", TARGETED_DEVICE_FAMILY=1, SUPPORTS_MACCATALYST="NO")
        else: settings.update(SDKROOT="watchos", SUPPORTED_PLATFORMS="watchos watchsimulator", WATCHOS_DEPLOYMENT_TARGET="10.0", TARGETED_DEVICE_FAMILY=4, SKIP_INSTALL="YES")
        targets[name] = obj(name+"target","PBXNativeTarget", buildConfigurationList=configlist(name,settings), buildPhases=phases, buildRules=[], dependencies=[], name=name, productName=name, productReference=product, productType="com.apple.product-type.application")
    proxy = obj("watchproxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1, remoteGlobalIDString=targets["GlucklichWatch"], remoteInfo="GlucklichWatch")
    dependency = obj("watchdependency", "PBXTargetDependency", target=targets["GlucklichWatch"], targetProxy=proxy)
    embedded = obj("embeddedwatch", "PBXBuildFile", fileRef=watchprod, settings={"ATTRIBUTES":["RemoveHeadersOnCopy"]})
    embed_phase = obj("embedwatch", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embedded], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0)
    objects[targets["Glucklich"]]["buildPhases"].append(embed_phase)
    objects[targets["Glucklich"]]["dependencies"].append(dependency)
    project = obj("project","PBXProject", attributes={"BuildIndependentTargetsInParallel":1,"LastUpgradeCheck":1600,"TargetAttributes":{t:{"CreatedOnToolsVersion":"16.0","SystemCapabilities":{"com.apple.HealthKit":{"enabled":1}}} for t in targets.values()}}, buildConfigurationList=configlist("project",dict(ALWAYS_SEARCH_USER_PATHS="NO",CLANG_ENABLE_MODULES="YES")), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en","Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="",projectRoot="",targets=list(targets.values()))
    output = dict(archiveVersion=1,classes={},objectVersion=56,objects=objects,rootObject=project)
    (ROOT/"Glucklich.xcodeproj/project.pbxproj").write_text("// !$*UTF8*$!\n"+serialize(output)+"\n")
    for name, target in targets.items():
        xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:Glucklich.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:Glucklich.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:Glucklich.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
        (ROOT/f"Glucklich.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme").write_text(xml)
    base = {"CFBundleDevelopmentRegion":"en","CFBundleDisplayName":"Glucklich","CFBundleExecutable":"$(EXECUTABLE_NAME)","CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)","CFBundleInfoDictionaryVersion":"6.0","CFBundleName":"$(PRODUCT_NAME)","CFBundlePackageType":"APPL","CFBundleShortVersionString":"$(MARKETING_VERSION)","CFBundleVersion":"$(CURRENT_PROJECT_VERSION)","NSHealthShareUsageDescription":"Glucklich reads permitted heart rate, activity and external CGM glucose to provide research forecasts."}
    phone = dict(base,LSRequiresIPhoneOS=True,NSCameraUsageDescription="Glucklich photographs your meal and saves it locally with your confirmed nutrition.",UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes":False},UILaunchScreen={},UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"])
    watch = dict(base,WKApplication=True,WKCompanionAppBundleIdentifier="edu.rutgers.healthhack.Glucklich",WKRunsIndependentlyOfCompanionApp=False,WKWatchOnly=False,NSHealthUpdateUsageDescription="Glucklich records your user-started walking sessions to Apple Health.",WKBackgroundModes=["workout-processing"])
    for folder,info in [("iOS",phone),("Watch",watch)]:
        (ROOT/f"{folder}/Info.plist").write_bytes(plistlib.dumps(info))
        (ROOT/f"{folder}/Glucklich.entitlements").write_bytes(plistlib.dumps({"com.apple.developer.healthkit":True}))
    # Stable icon from geometric drawing, not a meal/medical visualization.
    from PIL import Image, ImageDraw
    folder = ROOT/"Resources/Assets.xcassets/AppIcon.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB",(1024,1024),(10,118,112))
    d = ImageDraw.Draw(image)
    d.ellipse((195,195,829,829),fill=(214,245,227))
    d.ellipse((342,350,410,418),fill=(10,118,112))
    d.ellipse((614,350,682,418),fill=(10,118,112))
    d.arc((326,330,698,697),start=12,end=168,fill=(10,118,112),width=44)
    image.save(folder/"icon.png")
    # Xcode's universal 1024 icon slots for iOS and watchOS.
    (folder/"Contents.json").write_text(json.dumps({"images":[{"idiom":"universal","platform":"ios","size":"1024x1024","filename":"icon.png"},{"idiom":"universal","platform":"watchos","size":"1024x1024","filename":"icon.png"}],"info":{"author":"xcode","version":1}},indent=2))
    (folder.parent/"Contents.json").write_text(json.dumps({"info":{"author":"xcode","version":1}}))
    print("Created Glucklich.xcodeproj with iOS and watchOS targets")

if __name__ == "__main__": main()
