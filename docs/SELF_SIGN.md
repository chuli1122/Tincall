# Tincall 自签与安装

可以从 [最新发布页](https://github.com/chuli1122/Tincall/releases/latest) 下载 IPA 后自行重签安装，也可以从源码构建。两种方式都需要 iOS 26 或以上的 iPhone，以及适用的签名和设备权限。个人使用范围见 [许可](../LICENSE)。

## 使用官方 IPA

在 [最新发布页](https://github.com/chuli1122/Tincall/releases/latest) 的 Assets 中下载 `*-selfsign-unsigned.ipa`，使用自己的签名方式重签安装，可省去源码编译和 Xcode 构建。具体签名工具需要什么电脑或账号，以该工具说明为准；IPA 本身不让任意设备免签安装。

签名工具须正确处理主 App、实时活动扩展 `TincallCallWidget`、通话 Intent 扩展 `TincallCallIntents`、框架及其权限。App Group 和推送需要签名团队与描述文件支持，不能保证所有重签方式都保留这些功能。签名有效期到期后需要重新签名。

重签成品 IPA 时，下文修改 Xcode／xcconfig 的步骤不会改变已有二进制；需要由重签工具实际完成以下对应设置：

- 修改主 App 和两个扩展的 Bundle ID，为三个 target 分别使用匹配的描述文件与签名权限。
- 主 App 和实时活动扩展的 App Group，以及这两个包的 `Info.plist` 中已展开的 `TincallAppGroupIdentifier`，必须指向自己已授权的同一共享组；不能只替换签名里的组名。通话 Intent 扩展当前不使用共享组。
- 后台来电须保留主 App 的 `aps-environment`，并为最终主 App 标识配置自己的 APNs 发送端。完整步骤、变量示例、手机绑定与排错见 [自签推送配置](../cloudflare/README.md#自签后台来电配置步骤)。

若工具无法正确处理这些标识与权限，使用下面的源码构建方式。免费个人签名不提供后台推送来电；普通拨出通话及已配置服务的前台来电不依赖 APNs。

更新时下载新 IPA，沿用相同签名身份、App 标识和共享组配置进行覆盖安装，先备份重要数据，不要先卸载旧版。模型、语音和后端服务仍需在 App 中自行配置。可以分享官方发布页链接；未经授权，不向他人再分发原包或重签后的安装包，也不代签代装。

## 从源码构建的准备

需要 Mac、能构建本工程的 Xcode，以及自己的 Apple 开发者账号。工程使用 Swift 6、iOS 26 SDK 能力；Xcode 还须支持手机当前系统。首次构建会解析 ONNX Runtime 1.24.2，本地 LAME 源码已随库提供。依赖许可见 [第三方声明](third_party.md)。

## 先配置三个 target

用 Xcode 打开 `ios/Tincall.xcodeproj`，选择 `Tincall` scheme。在三个 target 的 Signing & Capabilities 中分别设置自己的 Team，保持自动签名，并更换唯一标识：

| Target | 示例 Bundle Identifier |
| --- | --- |
| Tincall | `com.yourname.tincall` |
| TincallCallWidget | `com.yourname.tincall.CallWidget` |
| TincallCallIntents | `com.yourname.tincall.CallIntents` |

两个扩展标识都必须以前缀“主 App 标识 + 点”开头。Debug、Release、StoreDebug 和 StoreRelease 都要检查。不要用一个全局 PRODUCT_BUNDLE_IDENTIFIER 命令参数同时覆盖三个 target，也不要复用作者的团队、证书或描述文件。

## App Group 与推送的实际位置

主 App 与实时活动扩展使用 App Group，通话 Intent 扩展当前不使用共享组。修改 `ios/TincallCallWidget/CallActivityAppGroup.xcconfig` 中的 `TINCALL_APP_GROUP_IDENTIFIER`，例如 `group.com.yourname.tincall`，并在自己的团队中给主 App 与实时活动扩展的 App ID 授权同一组。代码通过 Info.plist 的 `TincallAppGroupIdentifier` 读取该值。

以下 entitlements 中的共享组均引用 `$(TINCALL_APP_GROUP_IDENTIFIER)`，无需分别改写组名。修改共享 xcconfig 后，在主 App 与实时活动扩展的 Signing & Capabilities 中确认授权组与之相同：

- `ios/Tincall/Resources/Tincall.entitlements`：无推送主 App。
- `ios/Tincall/Resources/TincallPush.entitlements`：带推送主 App。
- `ios/TincallCallWidget/TincallCallWidget.entitlements`：扩展。

主 App 的两个 entitlements 文件还包含 Siri 与默认通话 App 权限，需由自己的团队和描述文件授权；通话 Intent 扩展没有独立 entitlements 文件。不要把三个 target 配成同一套权限。

当前共享 xcconfig 默认启用主 App 的推送 entitlements，Debug 使用 development，Release 使用 production；`ios/Push.xcconfig` 是同方向的显式覆盖，不是默认启用推送的唯一入口。签名、App 内环境、发送端 APNs 环境与 topic 必须匹配。改 Bundle ID 后还要同步自己的发送端 topic。

需要后台来电时，团队与描述文件必须支持 Push Notifications，配置匹配签名的 APNs 发送端并在手机完成设备绑定。实时活动有本地更新和可选的远端启动路径，远端启动还需要对应的 Live Activity topic；详见 [推送说明](../cloudflare/README.md)。

## Personal Team 的限制

以 Xcode 实际能力和描述文件为准。免费 Personal Team 通常需要约每七天重新签名，不能承诺永久安装或后台推送来电。

若账号不支持推送，在自己的本地配置将 `TINCALL_PUSH_ENTITLEMENTS` 改为 `Tincall/Resources/Tincall.entitlements`，并确认最终签名不含 `aps-environment`；不要只在界面删 capability 却仍引用推送文件。App 内不启用后台来电。

App Group 也要核对账号支持。当前卡片、共享状态和快捷交互依赖共享容器，不能承诺删除 App Group 后全部功能正常；需要这些能力时使用具备相应授权的团队。麦克风、语音识别权限、后台 audio 声明和 CallKit API 各有用途，不应为通过签名而一并删除。

## 构建与安装

连接手机、解锁并信任 Mac，在手机打开开发者模式。选择目标 iPhone，Xcode Run 构建安装。首次启动按系统要求信任开发者，配置自己的模型和语音服务。

也可在已完成上述配置后运行：

```sh
xcodebuild -project ios/Tincall.xcodeproj -scheme Tincall \
  -configuration Debug -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath /tmp/tincall-self-sign \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build

xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  /tmp/tincall-self-sign/Build/Products/Debug-iphoneos/Tincall.app
```

将占位符替换为本地真实值。不要把证书、私钥、描述文件、个人 Team／设备信息或签名产物提交到仓库。覆盖安装前保留需要的数据；卸载重装不是默认修复步骤。

## 检查与排错

- 标识占用：选择自己的唯一 Bundle ID，同步扩展前缀。
- 描述文件／entitlements 不匹配：逐个核对 target、Team、App Group、推送环境，刷新自动签名；不要用关闭签名冒充真机可安装。
- 安装过期：用同一团队和标识重新构建覆盖安装，先备份本地记录。
- 模型无回复：签名不提供模型或服务账号，继续按 [接入指引](agent_prompt.md) 配置。

安装后先拨出一通电话，确认收音、回复、播放与挂断正常。启用后台来电后，再将 App 退到后台或锁屏测试响铃和接听；实时活动还需在 iOS 设置中允许，并按推送指南配置远端启动。

## 版本与打包

关于页及反馈模板从安装包读取版本和构建号。自行编译时，主 App 与两个扩展的版本和构建号必须一致；不要把旧 IPA 重命名为新版。维护者可按[发行打包说明](release.md)生成没有商店购买限制、供个人重签的 IPA；签名及推送权限仍需按本页配置。英文步骤见 [English setup guide](setup.en.md)。
