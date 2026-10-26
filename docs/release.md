# 发行版本与 IPA / Release versions and IPA

## 中文

源码、自签 IPA、App Store 包是同一工程的不同构建方式。`Tincall`／`Release` 保留完整核心功能，不显示商店购买入口；`Tincall-AppStore`／`StoreRelease` 才启用试用和购买流程。不要从已加密的 App Store 下载包制作自签版，也不要把商店包仅改名后发布。

### 版本对应

- 主 App `Tincall`、实时活动扩展 `TincallCallWidget` 和通话 Intent 扩展 `TincallCallIntents` 使用相同的版本、构建号；在 Xcode 的三个 target、四种配置中同步修改。关于页和反馈模板读取包内版本。
- 同一发行附上与 IPA 来自同次源码快照的源代码，发行标题写明版本、构建号及自行签名版。先固定源码再构建；构建后若修改源码，重新构建，不能把其他版本的源码当作对应源码。
- App Store 再次上传须使用未上传过的更高构建号。源码版构建不改变已送审或已安装的包；商店和公开版的发行记录分别保存。

### 制作个人自签 IPA

在装有 Xcode 的 Mac 上，从对应源码根目录执行；目标必须是仓库外的新目录，已有目录会拒绝：

```sh
bash tools/package-self-sign.sh /absolute/path/to/new-release-folder
```

脚本固定使用 `Tincall`／`Release`，从源码归档，不传入作者证书，不签名、不安装、不上传。它直接读取归档中的主 App 及所有嵌入 `.appex` 的版本，确认两个必需扩展都在包内、版本和构建号一致，并检查必要的库／许可文件。包含签名或描述文件的产物会被拒绝。随后生成：

| 文件 | 用途 |
| --- | --- |
| `Tincall-VERSION-buildNUMBER-selfsign-unsigned.ipa` | 供接收者个人重签；不是免签包 |
| `Tincall-VERSION-buildNUMBER-library-materials.zip` | 同包 LAME 完整源码、构建／替换说明及第三方声明，必须一并提供 |
| `BUILD.txt` | 版本、scheme、配置及 Xcode 版本记录 |

发行时还须提供对应的、已检查的源码快照和项目许可。不要公开整个输出目录：`DerivedData`、归档、日志和中间目录仅留本机。开发仓库应先导出公开快照，不能直接压缩包含内部资料的开发目录。

接收者按[自签指南](SELF_SIGN.md)处理主 App、两个扩展、框架及主 App／实时活动扩展的共享组。免费 Personal Team 不提供所需 APNs 能力，不能承诺锁屏来电。换团队、Bundle ID 或环境后需重新绑定推送；按[推送说明](../cloudflare/README.md)检查前台、后台和锁屏来电，以及接听后的音频、挂断与实时活动。

### 第三方库材料

`LibraryMaterials/LAME` 是此次构建的本地动态库源码及包定义；其 README 提供 arm64 iOS 重建和替换步骤。Tincall 的个人使用限制不覆盖该库按 LGPL 获得的修改、替换、重链接及必要调试权利。ONNX Runtime 的完整上游声明同时进入 App 和配套 ZIP；其他组件见[第三方声明](third_party.md)。

## English

The source, self-signing and App Store editions use the same project. `Tincall` / `Release` keeps core calling available without the StoreKit gate. `Tincall-AppStore` / `StoreRelease` enables trial and purchase flows. Do not turn an encrypted App Store download into a self-signing release or simply rename a store build.

Keep the version and build number identical across all three targets (`Tincall`, `TincallCallWidget` and `TincallCallIntents`) and all four configurations. The About page and feedback template read these values from the installed bundle. Publish the source snapshot used for that exact IPA with the same release. Freeze the source before building; rebuild if it changes. A new App Store upload needs a higher, unused build number. Local source builds do not change an existing submission or installed app.

On a Mac with Xcode, run from that source snapshot:

```sh
bash tools/package-self-sign.sh /absolute/path/to/new-release-folder
```

The output must be a new directory outside the source tree. The script archives `Tincall` / `Release` without signing, requires both extensions, checks the version and build number of the app and every embedded `.appex`, and checks the required libraries and notices. It rejects signatures and provisioning profiles, then creates an unsigned IPA, a `library-materials.zip` containing the matching LAME source and notices, and `BUILD.txt` with build details. It does not install or publish anything.

Distribute the IPA, library-materials ZIP, build record, matching reviewed source snapshot and project license together. Do not upload the entire output folder: archives, DerivedData, logs and staging files are local build artifacts. Export a reviewed public snapshot first; never ZIP the internal development checkout for publication.

Recipients must re-sign the app, both extensions and frameworks and configure their own App Group for the app and Live Activity extension. Follow the [English setup guide](setup.en.md). A free Personal Team cannot provide the APNs capabilities required for background calls. Rebind devices after changing the team, bundle ID or signing environment, then check foreground, background and locked-screen ringing, call audio, hang-up and Live Activities.

`LibraryMaterials/LAME` contains the dynamic library's matching source, package definition and arm64 iOS rebuild/replacement instructions. Tincall's personal-use restrictions do not override the LGPL rights to modify, replace, relink or debug that library. The complete upstream ONNX Runtime notices are included both inside the app and in the materials ZIP. See [third-party components](third_party.md).
