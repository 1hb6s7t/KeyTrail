# 可选 BongoCat 桌宠集成

公开源码包含桌宠窗口、Metal 渲染和键位反馈的接入代码，不包含 Cubism SDK、模型、纹理或预构建小猫应用。普通统计与数据浮窗不依赖这些外部资源。

## 来源与许可

- BongoCat 固定提交：[`b82b4750b776df1408db07d5858d37db1594c3f3`](https://github.com/ayangweb/BongoCat/commit/b82b4750b776df1408db07d5858d37db1594c3f3)。
- 模型来源：[resources/models/standard](https://github.com/ayangweb/BongoCat/tree/b82b4750b776df1408db07d5858d37db1594c3f3/resources/models/standard)。
- 上游关联的 [Awesome-BongoCat 目录](https://github.com/ayangweb/Awesome-BongoCat) 将经典模型署名为 MMmmmoko。这是来源线索，不等于完整的模型再分发授权。
- BongoCat 应用源码采用 Apache-2.0；ABI 声明的 Swift 适配保留来源注释和 NOTICE。角色、模型、纹理及 Live2D SDK 分别适用其自身条款，不能由 KeyTrail 的 LICENSE 重新授权。

详见 [第三方说明](../THIRD_PARTY_NOTICES.md)。当前源码包排除上述外部资源；包含它们的二进制发行需要单独核实模型及 SDK 的使用、发行条件。

## 开发者本地接入

先自行阅读并接受适用条款，准备官方 Cubism SDK for Native（当前接入结构使用 5-r.5）。脚本不下载 SDK、不代替开发者接受许可，也不在 CI 获取模型。

如确认适用许可允许你的本地用途，可显式运行固定来源下载脚本：

```sh
python3 scripts/prepare-bongo-assets.py
KEYTRAIL_CUBISM_SDK=/absolute/path/to/CubismSdkForNative ./scripts/package-cat-app.sh
```

脚本将资源写入已忽略的 `artifacts/bongo-assets/`，核对固定 Git blob 与 SHA-256，已有不匹配文件拒绝覆盖。下载范围包含模型入口、moc3、三张纹理、表情和动作、键盘底图、53 张键位图层及上游 LICENSE；manifest 记录来源和摘要。音频、预览封面与 SDK 不在下载范围。模型的音频引用不加载。

打包默认写入新的 `artifacts/KeyTrail-Cat-dev.app`，可用 `KEYTRAIL_CAT_APP_OUTPUT` 指定另一个绝对路径。已有输出默认拒绝覆盖；现用受保护包即使显式要求覆盖也会拒绝。临时签名变化可能需要通过 macOS 正常流程重新授权，因此开发与现用应用应分别保存。构建成功不能替代输入监控、辅助功能、实体键位或性能验证。

## macOS 物理键映射

以下十进制 keycode 对应 Apple SDK `HIToolbox/Events.h` 的 `kVK_ANSI_*` 和独立键定义核对；资源 ID 是 PNG 文件名去掉扩展名。它表示物理键位置，不能推断输入法提交文本或用户实际输入的字符。非 ANSI 布局的键帽字符可能与模型的固定图案不同。

| 物理键 | keycode → 资源 ID |
| --- | --- |
| A–F | 0→KeyA，11→KeyB，8→KeyC，2→KeyD，14→KeyE，3→KeyF |
| G–L | 5→KeyG，4→KeyH，34→KeyI，38→KeyJ，40→KeyK，37→KeyL |
| M–R | 46→KeyM，45→KeyN，31→KeyO，35→KeyP，12→KeyQ，15→KeyR |
| S–Z | 1→KeyS，17→KeyT，32→KeyU，9→KeyV，13→KeyW，7→KeyX，16→KeyY，6→KeyZ |
| 主键盘数字 0–4 | 29→Num0，18→Num1，19→Num2，20→Num3，21→Num4 |
| 主键盘数字 5–9 | 23→Num5，22→Num6，26→Num7，28→Num8，25→Num9 |
| 左/右 Command | 55→Meta，54→Meta；上游只有一张 Meta，不能声称可视上区分左右 |
| 左/右 Option | 58→AltLeft，61→AltRight |
| 左/右 Control | 59→ControlLeft，62→ControlRight |
| 左/右 Shift | 56→ShiftLeft，60→ShiftRight |
| 主键盘 Return | 36→Enter |
| 后向删除 / 前向删除 | 51→Backspace，117→Delete；Apple 的 `kVK_Delete` 是后向删除，不可反接 |
| 空格 / Tab / Escape | 49→Space，48→Tab，53→Escape |
| Caps Lock / Fn | 57→CapsLock，63→Fn；Fn 只对应实际 Function 键，不作缺图键的兜底 |
| Grave / Slash | 50→BackQuote，44→Slash；文件名 `BackQuote` 的大小写须完全一致 |

Shift+数字仍对应实际数字键和 Shift 状态，不把生成的符号映射到另一物理位置。资源不支持的主键盘符号包括 Equal(24)、Minus(27)、RightBracket(30)、LeftBracket(33)、Quote(39)、Semicolon(41)、Backslash(42)、Comma(43)、Period(47)。方向键、F1–F20、Home/End/PageUp/PageDown/Help、媒体键及 ISO/JIS 特有键同样没有本套独立图，不可冒充 Space、Fn 或其他现成键位。

小键盘有独立物理位置，但本套没有小键盘图。为保持实际键位要求，KeypadEnter(76) 不映射到主键盘 Enter，Keypad0–9(82,83,84,85,86,87,88,89,91,92) 不映射到主键盘 Num0–9；小键盘操作符也返回无资源。若以后产品决定按键功能归并，须单独披露这种可视化限制，不能默认为完整键位对应。

采集端只向桌宠发送白名单内的瞬时资源 ID 和按下状态，不将事件顺序或坐标持久化。缺图键不冒充 Space 或 Fn。修饰键通过 flagsChanged 路径处理；暂停、锁屏、监听重置和退出清空瞬时按键状态。实际行为须通过 PetChecks 和实体键盘检查分别验证。

