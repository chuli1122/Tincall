# 发行与打包 / Releases and packaging

## 中文

`Tincall`／`Release` 用于个人自行签名，保留完整核心通话功能；`Tincall-AppStore`／`StoreRelease` 启用商店版试用和购买流程。

主 App、实时活动扩展和通话 Intent 扩展的版本、构建号须一致，三个 target 的四种配置需同步修改。对外版本号与内部构建号分别管理；新的 App Store 上传使用更高且未用过的构建号。

### 制作自签 IPA

在装有 Xcode 的 Mac 上，从对应发行源码根目录运行，输出目录须位于仓库外且尚不存在：

```sh
bash tools/package-self-sign.sh /absolute/path/to/new-release-folder
```

脚本归档 `Tincall`／`Release`，检查扩展、版本和第三方材料，移除临时代码签名并确认包内无签名或描述文件，生成：

| 文件 | 用途 |
| --- | --- |
| `Tincall-VERSION-buildNUMBER-selfsign-unsigned.ipa` | 供使用者自行重签 |
| `Tincall-VERSION-buildNUMBER-library-materials.zip` | 对应的 LAME 源码、重建／替换说明和第三方声明，须与 IPA 一同提供 |
| `BUILD.txt` | 本地构建记录 |

GitHub Release 附上 IPA、库材料和简短的自签说明。源码使用对应标签自动生成的 Source code 下载，许可保留在源码内，无需另传源码 ZIP 或 LICENSE。归档、DerivedData 和日志留在本机。

先固定并检查公开源码快照，再从该快照构建；源码变化后须重新构建。接收者按[自签指南](SELF_SIGN.md)处理主 App、两个扩展、框架和 App Group。免费 Personal Team 不支持所需 APNs 能力；后台来电的签名、绑定和发送端要求见[推送说明](../cloudflare/README.md)。

LAME 按 LGPL 提供，其修改、替换、重链接及必要调试权利不受 Tincall 的个人使用限制影响。其他组件见[第三方声明](third_party.md)。

## English

`Tincall` / `Release` provides the core calling features for personal self-signing. `Tincall-AppStore` / `StoreRelease` enables the store trial and purchase flows.

Keep the version and build number identical across the app, Live Activity and call Intent extension, in all four configurations. The public version and internal build number are separate; each new App Store upload needs a higher, unused build number.

On a Mac with Xcode, run from the release source snapshot. The output must be a new directory outside the source tree:

```sh
bash tools/package-self-sign.sh /absolute/path/to/new-release-folder
```

The script archives `Tincall` / `Release`, checks the extensions, versions and library materials, removes temporary code signatures, and confirms that no signatures or provisioning profiles remain. It creates an unsigned IPA, a matching `library-materials.zip` with LAME source and notices, and a local `BUILD.txt` record.

Attach the IPA, library materials and brief signing instructions to the GitHub Release. Use GitHub's generated Source code downloads for the matching tag, with the project license inside the source. No separate source ZIP or LICENSE attachment is needed. Keep archives, DerivedData and logs local.

Build from the reviewed release snapshot and rebuild after source changes. Follow the [English setup guide](setup.en.md) to re-sign the app, both extensions and frameworks, and configure the App Group. A free Personal Team cannot provide the APNs capabilities required for background calls.

The LGPL rights to modify, replace, relink and debug LAME are unaffected by Tincall's personal-use restrictions. See [third-party components](third_party.md).
