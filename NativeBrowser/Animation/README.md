# Animation

应用自定义窗口与界面动画的统一功能包，由现有 NativeBrowser app target 编译。
UI 组件负责状态和交互，这个包负责动画参数、速度偏好以及共享分屏动画实现。

## 参数入口

所有动画调参都通过 `AnimationValues` 引用。按效果拆文件，不把新效果持续堆进分屏文件：

| 文件 | 参数命名空间 | 职责 |
| --- | --- | --- |
| `AnimationValues.swift` | `AnimationValues.Speed` | 三档比例、时间换算规则 |
| `SplitPageAnimationValues.swift` | `AnimationValues.SplitPages` | 分屏展开、消失、挤压、黄灯收起和玻璃交接 |
| `TabDragAnimationValues.swift` | `AnimationValues.TabDrag` | 浮块托起、变形、排序、落点和交接 |
| `SidebarAnimationValues.swift` | `AnimationValues.Sidebar` | 侧栏开合、Space 分页、悬停、清空反馈 |
| `ToolbarAnimationValues.swift` | `AnimationValues.Toolbar` | 工具栏一级控件出现、消失和销毁等待 |
| `AddressFieldAnimationValues.swift` | `AnimationValues.AddressField` | 地址胶囊、焦点环、站点信息和按钮反馈 |
| `SpotlightAnimationValues.swift` | `AnimationValues.Spotlight` | 新标签页玻璃与建议列表动画、宿主移除等待 |

`BrowserAnimationPreferences.swift` 保存档位偏好；`SplitPages/` 保存共享分屏动画实现。
未来新增窗口、设置面板等效果，应在此包增加对应的 `*AnimationValues.swift` 文件，
扩展 `AnimationValues`，再由组件引用。

## 必须遵守的使用规则

1. **组件中禁止直接写动画速度相关数值**：时长、延迟、spring response、阻尼、
   贝塞尔控制点、速度比例，以及动画专用的缩放 / 进度调参，均放到对应参数文件。
   普通布局尺寸继续由组件布局文件管理，公共窗口几何继续由 `BrowserLayout` 管理。
2. 时间以标准档秒数定义，通过 `AnimationValues.duration(_:)` 统一换算。
   细腻、标准、快速分别乘以 `4/3`、`1`、`2/3`；时长越短，动画越快。
   曲线、阻尼和几何不缩放，因此改变档位只改变节奏。
3. 命名时间属性是计算属性，已经应用档位比例，组件直接使用，**禁止二次缩放**。
   不要用 `static let` 缓存时长，否则修改设置后无法立即影响下一次动画。
4. 与动画绑定的交接延迟、旧页面保留期、宿主销毁等待也必须由此定义，
   避免慢速动画尚未完成就移除组件。优先用完成回调；同一次 flight 需要后续
   中点 / 清理时，开始时捕获时长，之后沿用该时钟。
5. 保留系统 Reduce Motion 分支，不接管系统原生窗口与控件自带的动画。
   数学公式中的 `0` / `1`、插值与归一化系数不是调参魔法值。
   输入 debounce、CEF 调度、等待下一帧 / 轮询频率和指针驱动自动滚动不随速度档位缩放。

参数文件示例：

```swift
extension AnimationValues {
  enum ExamplePanel {
    @MainActor static var revealDuration: TimeInterval {
      AnimationValues.duration(0.24) // 标准档节奏，只在参数文件中定义
    }
    static let dampingFraction = 0.8
  }
}
```

组件使用：

```swift
withAnimation(.smooth(duration: AnimationValues.ExamplePanel.revealDuration)) {
  isPresented = true
}
```

检查新增代码时，确认组件动画调用没有裸数值，相关延迟与清理引用同一个参数层，
再按仓库要求运行 `CONFIGURATION=Debug Scripts/build.sh`。
