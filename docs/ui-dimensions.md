# ExHViewer 控件与尺寸标准

本文件维护 ExHViewer 自己的尺寸规格。与 Civit Viewer、HGhub 共用分类、证据字段和检查方法，不共用具体尺寸。ExHViewer 没有侧栏，也没有独立的用户头像控件。

本轮先完成全 App 源码盘点，再按授权收敛同职责控件、清理不可达实现，并对例外逐项取舍。基线 HEAD 为 `abf2ec12523e8b09956a2be9886967c3a16f9dc5`，工作区包含未提交的缓存、状态及全页官方网页改动；HEAD 不能代表当前画面。逐文件 SHA-256 和组件引用见 [ui-control-inventory.json](ui-control-inventory.json)。全页登录、居中空态等已随122版覆盖；本轮分栏手势和固定外壳改动为123版，最终手机状态以交付记录为准。

## 证据层级与维护

| 层级 | 本文的含义 | 不代表什么 |
| --- | --- | --- |
| 源码定义 | 常量、View/样式、布局表达式和调用位置 | 不等于父布局之后的可见尺寸 |
| 源码推导 | 依据固定字号、内外 padding、frame 和父布局计算 | 不等于所有设备和系统版本实测 |
| 现行登记 | 当前本 App 已采用的角色规格，写明紧凑例外 | 不把所有不同数值判成冲突 |
| 建议 | 待后续批准实施并验收的收敛方向 | 未实施的建议仍不作为现状 |
| 运行验证 | 有指定用例、模拟器结果包或截图支持的场景 | 不扩展为全页面、真机或真实登录成功 |

重新生成清单：`python3 scripts/audit-ui-dimensions.py`；核对源码及本文：`python3 scripts/audit-ui-dimensions.py --check`。扫描器读取 `App/**/*.swift`，记录全部源文件、类型、UI 构造/修饰调用、布局属性和共享类型的词法引用。它不执行 App，不展开循环为可见控件实例，不计算 SwiftUI 布局，也不把媒体像素、并发上限和 QA 数据计入“控件尺寸”。显式 QA 文件、QA 类型及可识别的正向 QA 分支独立分类；间接运行时 QA 条件仍可能存在，需人工复查。

## 覆盖统计

<!-- inventory-summary -->
已逐文件扫描 `App/` 下全部 **71 个 Swift 文件**，其中28个生产UI文件、3个QA/诊断UI文件、40个非UI文件。登记24个组件角色族、143项UI相关类型/扩展声明。源码调用数和分类以当前 ui-control-inventory.json 为准，不代表可见实例或运行时页面覆盖。
<!-- /inventory-summary -->

完整文件清单及未归为 UI 的文件也保留在 JSON 中。`MediaCanvas` 的 `CGRect/CGSize` 多为缩放、解码后展示和媒体坐标，不是按钮点击区。`ReaderPaging` 的手势阈值与 `ReaderImagePipeline` 的图片规格不能用来推导通用行高。字符串中的 HTML、注释和字符串插值内部不作为 Swift 控件调用扫描。嵌套同名类型（如 Coordinator、Controller）的引用按词法名称汇总，不做 Swift 类型绑定；`frame` 也包含 GeometryProxy 的同名读回，不能全部当作可见框写入。

## 本 App 的集中参数

来源为 [CompactMainTabs.swift](../App/CompactMainTabs.swift)、[AppChrome.swift](../App/AppChrome.swift)。当前用户明确固定系统文字档位为 `.large`；显式 QA 大字号分支保留用于诊断，不宣称发布版支持 Dynamic Type 自适应。

| 角色 | 现行源码值或推导 | 使用边界 |
| --- | --- | --- |
| 页面内容左右边 | 20 pt | `FeedChrome.contentInset`；与共用设计准则的 16 pt 起步示例分开 |
| 栏内四边与同栏横缝 | 4 pt | `panelSpacing`；不是把所有内容卡内距都改成 4 |
| 同组内容间距 | 8 pt | `contentSpacing`、`controlSpacing` |
| 内容组间距 | 12 pt | `sectionSpacing` |
| 首项与栏区内容间距 | 4 pt | `contentTopGap = 8 - 4`；须与栏可见边/占位边分别测量 |
| 普通栏布局/操作高度 | 44 pt | `rowHeight`；宽度随角色，不是所有控件都 44 宽 |
| 栏按钮可见面高度 | 34 pt | `rowSurfaceHeight` |
| 页标题两侧图标按钮 | 可见面 34 × 34；源码/AX 目标 34 × 44 | `pageActionWidth = 34`，是紧凑宽度例外，不声称点击宽 44 |
| 紧凑表单/条件行 | 最小 36 pt | `compactFormRowHeight`；多行内容仍可能撑高 |
| 表单具名行角色 | 紧凑36/footnote；常规44/subheadline | `FormRowRole`、`formRowLayout`；未使用的32参考常量已删除 |
| 单行栏外框可见高 | 42 pt | `34 + 2 × 4`；44 pt 行的外溢各 1；再加栏外留白 |
| 双行栏外框可见高 | 80 pt | `2 × 34 + 3 × 4`；不是 2 × 44 的可见面 |
| 双行栏行布局 | 2 × 44 pt | 上行内沿 top 8/bottom 2，下行 top 2/bottom 8；图文以 offset 校正 |
| 主底栏预留高度 | 47 pt | `bottomBarReservedHeight = 44 - 1 + 4`；不包含设备系统安全区 |
| 普通控件/卡片/栏外框圆角 | R8 / R12 / R12 | `AppShape.control/card`；栏 R8+4；不是所有父子框同一个 R |
| 通用嵌套 panel / segmented | R14 / R5 | `AppShape.panel = R8+6`、`segment = R8-3`；按内外偏移登记 |
| 边线 | 0.5 pt | 控件/卡片细线，不是间距 |
| 详情信息卡内容边 | 6 pt | `DetailCard.inset`；封面、列间距、信息与动作之间共用 |
| 标签可见面/布局目标 | 最小高 26 / 最小高 30 pt，目标最小宽 44 | `TagChipMetrics`；多行长标签可增长，不是定高 |
| 浮动背景 | 0.90 不透明度 | `FloatingChrome`；选中覆盖色和边框透明度另算，不是最终像素 alpha |

Apple 当前 HIG 列出的 iOS 控件默认值为 44 × 44 pt、最小值为 28 × 28 pt。ExHViewer 的常规行约定采用 44 pt，但已有 34 × 44、44 × 36、44 × 30 等紧凑目标，必须按用途、邻近间距与点按验证登记。不能因为可见面低于 44 就直接报错，也不能把布局 frame 当成真实触摸命中证明。[Apple Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility.md)

## 全组件规格目录

下表列现行角色族。控件的实例数由状态、列表数据、方向和系统菜单共同决定，源码调用数不等于屏幕实例数。表中未附运行证据的项目为源码检查。

| 类别 | 共享实现或入口 | 当前可核查规格 | 归类与后续 |
| --- | --- | --- | --- |
| 页面壳/固定栏 | `CompactMainTabs`、`FloatingFeedLayout`、`FloatingHeaderPanel` | 内容边 20；栏外/内 4；可见单/双行 42/80；固定主栏，阅读隐藏主底栏 | 保留集中来源；页面内容与占位区域分别量；侧栏不适用 |
| 标题/返回/完成 | `FloatingPageTitleRow`、`PageTitleLayout`、`FeedHeaderControlSurface` | 侧按钮宽 34、布局高 44、可见高 34；标题 footnote semibold，单行最小缩到 0.8 | 已登记紧凑例外；左右动作位等宽居中；长文案优先 icon + AX 名称 |
| 顶栏网格/菜单 | `FeedHeaderGrid`、`LibraryMenuLabel`、`LibraryFilterMenu` | 轨道按 spans 等分、横缝 4；图文间距 4；各栏操作高度 44；chevron caption2 | 按 3/4/其他列轨道比较，不能把某个总宽记作固定控件宽 |
| 分段切换 | `FeedScopePicker`、`CompactFormSegmentPicker` | 主 scope 44 布局/34 可见；紧凑 segment 最小 36、内沿 3、R5 选中面 | scope 与表单不是同一角色；App自有下拉项采用共享 AppMenu；分段控件仍按切换角色保留 |
| 主底栏/管理底栏 | `CompactMainTabs`、`FloatingBottomBar`、`LibraryBatchToolbar` | 主栏高 44，可见外框 42，横缝 4，图形占位高 16；footnote；批量动作在同槽位交叉渐变 | 管理态项数变化不改变列表列宽；多行工作进度提示是独立 overlay 例外 |
| 通用动作按钮 | `AppActionButtonStyle`、`AppToolbarItem` | 最小可见高 32、目标最小 44 × 44、水平 padding 12、R8、subheadline medium | 与顶栏图标不是同一尺寸；禁用/按下 alpha 为 0.38/0.65 |
| 条件输入/清除 | `DiscoveryComposerView`、`SearchComposerCardSurface` | 外层行最小高 44、可见面垂直内缩 4 得 36、水平内距 12；清除目标 44 | 单行、不接受换行；多行说明/错误不是输入框；右侧菜单值用共享行，不再整控件缩放 |
| 条件表单/分类 | `SearchFilterActionStyle`、`CompactFormValueRow` | 普通筛选/标签规则最小 36；子卡 R8，外卡 R12；分类两列缝 4；全选/反选同高 | 画廊分类名与图标保留独立列；不要靠额外整行标题撑高 |
| 添加标签/已选行 | `TagEntryView`、`SearchTagRuleRow`、`TagListRowLabel` | 已选行最小 36；匹配菜单宽 56，移除目标 44 × 36，图形 11；标签名 footnote | 9 pt 的下拉字形和 3/6 pt 内缝登记为光学例外；输入/来源覆盖入口与普通表单同类核对 |
| 常用/搜索历史卡 | `SearchPresetRow`、`SearchPresetsView` | 名称 footnote；概要 caption；卡行最小 44+8=52；名称/条件摘要分层、单行截断 | 不把 52 合并进 36 筛选行；编辑排序/载入分别登记 |
| 开关 | `LocalDataManagementView`、`DiscoveryComposerView` | 使用原生 Toggle，父行由 36 或 44 角色决定；最终滑块/触摸几何由系统及父提议决定 | 未读回的 UIKit 开关尺寸记 UNKNOWN，不能从截图猜固定宽高 |
| 数值滑块 | `LoadingValueSlider`、`LocalDataManagementView` | UIView 约定高 44；数字参考 13、封顶 22；thumb 绘制图像最小宽 40，faceHeight 最小 30，描边 0.5 | 滑块图片画布、可见胶囊和手指命中区分开；选项离散值与连续范围共用绘制 |
| 双列作品卡 | `GalleryRows`、`GalleryGridCell`、`CoverView` | 列缝/同列卡间距 8；标题 subheadline；封面 R8，比例由 GalleryCoverLayout 限制在 0.5–2.0；卡内 gap 8、元信息 gap 4 | 已复用 contentSpacing/panelSpacing；选中图形 28 圆面是状态，不是独立按钮 |
| 历史/下载通用卡 | `LibraryGalleryCard`、`LibraryCardRows` | 最小高 132=3×44；封面 72×108；内距/封面到文字 12；文字行距 8；外框 R12 | 标题最多两行，元信息 footnote；第三行为阅读/下载上下文；加载封面不改变预留大小 |
| 外分组容器 | `FormGroup`、`formRowSurface` | 子项间距4、外内距4、子面R8、外框R12 | 搜索与添加标签复用；原GalleryRow/list分支经调用检查无生产消费者，已移除 |
| 详情信息/动作 | `GalleryDetailView`、`GalleryFact` | 竖屏封面 84×126、紧凑高度横屏 80×120；标题 subheadline 最多两行，作者/上传 footnote；三按钮均分 | 卡内 6，信息列内 8；不是三列平均压缩标题；作者/上传缺项 N/A |
| 详情属性小块 | `GalleryDetailView` | 分数/类别/页数 footnote；标签与值间距 4；水平内距 6/垂直 2；最小高 22；R8 细线 | 信息属性不可点击，不按 44 目标判错；数字页数和英文冒号属于内容约定 |
| 标签/分组/流式布局 | `TagChipButtonStyle`、`TagWrapLayout`、`TagChipMetrics` | 可见面最小高 26、目标最小高 30/宽 44；横 8/纵 2 内距；详情外卡到组卡4；组卡目标横4/纵2，可见面净边4 | 组名使用同一 face/target；组名颜色区分语义；长标签允许换行，整组不横向并排 |
| 收藏管理/设置/表单 | `GalleryFavoriteEditorView`、`FavoriteSettingsView`、`AccountView` | 卡 R12，紧凑表单行 36、普通卡最小高 44；值与标题分色；原生组名菜单仅右侧可点 | 共享FormValueMenuRow固定footnote；左标题只读，右值独立Menu；菜单内部由系统决定 |
| 状态/空/错误 | `GalleryEmptyState`、`GalleryFeedStatus`、`GalleryContinuationFooter`、`StatusMessage` | 无作品 subheadline/secondary 内容区居中；冷加载 mini 延迟 250 ms；错误图形 28、gap12、padding28；已有列表错误 footnote | 未登录 ContentUnavailableView 仍是系统大空态例外；不同语义不统一成同一种空列表 |
| 官方网页/登录 | `OfficialWebView`、`SiteWebSurface` | 当前全页导航，共享单行顶栏和主底栏；关闭/完成各 34×44，域名 caption；网页避让主底栏 47 | Web 表单由站点决定，App 不登记网页元素为自有控件；完成动作用顶栏 checkmark |
| 阅读器/进度/菜单 | `ReaderView`、`ReaderSettingsPanel`、`ReaderLoadingPage` | 原图以全屏中心为准；阅读栏最大宽 460、左右页边 20、主行高 44；页码目标最小宽54；定位操作最小宽56 | 阅读器不显示主底栏；连续页 gap2，单页翻页进入目标黑底加载页，页码与目标一致；设置仍有原生 sheet |
| 媒体画布/手势 | `MediaCanvas`、`ReaderGestures` | UIScrollView/图像展示区域跟随 viewport；边缘返回起始宽20；缩放旋转/回弹/命中取决于画布 | 解码像素、旋转角度与拖动阈值不作为通用 UI token；动画时长单独登记 |
| 系统菜单/提示/分享 | `GalleryDownloadsView`、`LibraryBatchToolbar`、`ReaderView` | 原生 Menu/alert/confirmationDialog/分享 UI 无自定条目高度；主导航下载方式和BT同栈；阅读设置保留临时面板 | 不批量取消系统授权/分享弹层；业务页面与系统流程分别审视；逐条看返回路径 |

## 文字、图标、截断和颜色

| 文字角色 | 当前定义 | 使用范围/例外 |
| --- | --- | --- |
| 栏提示/按钮 | `FeedChrome.labelFont = .footnote.medium` | 发现、资料库、标题操作及主底栏标签共用；强调标题 semibold |
| 内容标题 | `.subheadline.medium/semibold` | 作品网格、详情、通用卡；常用组合名称用栏字号 |
| 属性/标签/紧凑表单 | `.footnote` | 详情 credits/facts、标签、筛选行；元信息不能跟主标题一起放大 |
| 次要概要 | `.caption`，局部 `.caption2` | 常用概要、类别辅助值、来源和标记；不冒充主操作文案 |
| 详情主动作 | `.footnote.medium`，34高可见面 | 三按钮均分，ViewThatFits从图文降为纯文字，后者可缩到0.5；需登记窄屏下的实际字形变化 |
| 独立图形 | SF Symbol + `.small`，局部 9/11/14/16/28 pt | 9 为下拉字形、11 为移除字形、14 为选中标记、28 为整页错误；不是这些数字大小的点击目标 |

语义字号记录为 SwiftUI TextStyle。本轮未全量导出 `UIFont.pointSize`，不能把语义字体写成所有系统版本的固定点数。固定 `.large` 使发布版不随系统大字号变化；这与 Apple 鼓励大字的建议不同，是用户已作出的项目选择，文档明确登记而不宣称完全满足动态字体支持。

默认长标题/摘要使用 `.lineLimit(1/2/3)` + `.truncationMode(.tail)`；栏目标题/主底栏局部允许 `.minimumScaleFactor(0.8/0.65)`，因此“字体声明一致”不保证压缩后的字形一样大。需在窄屏长分组名、长标题与中英文混排下测量。用户要求统一省略提示，通常使用系统尾部省略号；没有统一的淡出实现。全名由详情/VoiceOver 语义提供。

颜色使用系统主文字/secondary/强调色/破坏性红色；禁用透明度与背景透明度不能混用。`FloatingChrome.surfaceOpacity=0.90` 是背景填充设置，实际像素还受系统底色、叠层和选中覆盖色影响。本轮未测量对比度比值。

## 页面与状态覆盖表

所有页面族已按源文件和共享组件登记，运行证据仅限后面的明确场景。

| 页面族 | 盘点页面/状态 | 主要来源 |
| --- | --- | --- |
| 发现 | 最新、热门、内联阅读历史；双行/历史替换首行；常用入口；列表恢复；首屏/续载/失败/无作品 | DiscoverView、ReadingHistoryView、GalleryRows、GalleryContinuationFooter |
| 搜索 | 搜索首页、筛选展开收起、范围、分类、评分页数、清空、提交；键盘单行 | SearchView、SearchDraft、CompactFormValueRow |
| 常用/搜索历史 | 列表、载入、保存、编辑、排序、取消；概要/站点/日期 | SearchPresetsView、SaveSearchPage、SearchPresetRow |
| 标签与屏蔽 | 添加/查找、分类、匹配方式、已选/未验证、常用、词库来源覆盖、屏蔽管理 | TagEntryView、TagsView、TagSuggestions |
| 资料库 | 稍后再读、站点收藏及分组、阅读历史及时间/标题筛选、下载状态/排序 | LibraryViews、LibraryScopePicker、ReadingHistoryView |
| 多选管理 | 长按、全选反选、选择/退出、移动分组、收藏/稍后再读/下载/移除、队列状态 | LibraryBatchActions、LibrarySelectionStore |
| 详情 | 封面/长标题/N/A、属性、三主动作、标签分组选择、加入/创建搜索、原页/下载入口 | GalleryDetailView、DetailTagSearch、GalleryFact |
| 收藏 | 快速收藏、已收藏管理、分组/取消/刷新、默认分组、改名、同步队列/失效 | GalleryFavoriteEditorView、FavoriteSettingsView、FavoriteSyncStatusView |
| 下载 | 待下载/下载中/暂停/失败重试/完成/有新版；本机缓存、差分、BT 列表与系统分享 | GalleryDownloadsView、DownloadRowLabel、Downloads |
| 我的 | 账号/站点、登录管理、额度/赞助、标签屏蔽、阅读存储、收藏设置/同步、清理确认 | AccountView、AccountDetailsViews |
| 官方网页 | 收藏、账号首页、登录管理、EX 验证、详情官方原页；准备/载入/错误/关闭/完成 | OfficialWebView、SiteWebSurface |
| 阅读 | 连续/单页，四方向，在线/离线，快反向/等待/回弹，长按沉浸，边缘返回，进度/菜单 | ReaderView、ReaderGestures、ReaderPaging、MediaCanvas |
| 阅读内面板 | 设置、详情、收藏编辑、更新确认；与主导航的上下文隔离 | ReaderSettingsPanel、GalleryDetailPresentations |
| 全局适配 | 深浅色、横竖屏旋转/过渡、安全区/键盘、固定字号、减少动态效果、VoiceOver | ExViewerApp、CompactMainTabs、AppNavigationChrome |

数值滑块还有一层容易混淆的几何：默认数字大小13时，绘制图像为42×44，`faceHeight`变量为30，但真正描绘的胶囊矩形是36×22（宽减6、高减8）；圆角为11，阴影blur3。它不是“44高的可见旋钮”，也不能据此断言原生UISlider的手指命中只有22。这组值为源码推导，未单独做像素/触摸实测。

## 需要分开收敛的项

| 项目 | 已看到的事实 | 建议与验证边界 |
| --- | --- | --- |
| 通用准则起步值与项目实际 | 通用文档示例页边16、卡内12；本 App 页边20、详情内6 | 本文件以项目实际为准；共用文档是方法与起步值，不覆盖项目已确认的数值 |
| 可见面与目标宽度 | 顶栏 icon 可见34正方形，但目标宽34高44 | 保留已登记紧凑用途；如要提升横向命中，需避免侵入相邻标题，单独验点按，不机械扩宽外观 |
| 菜单字号补偿 | 已移除搜索scale0.82，默认组/管理组/搜索站点/评分复用FormValueMenuRow | 菜单label采用紧凑footnote；App自有弹出菜单采用共享 AppMenu，系统授权/确认/分享保持系统流程 |
| 不可达旧列表 | 三处生产GalleryRows调用均为grid，旧GalleryRow/list已删除 | 保留132高历史/下载卡和自适应双列卡两个职责，不强套为同一布局 |
| 标签可见行距 | 26面加上下各2命中区，目标至少30；水平缝4、行包络可见净缝至少4；组目标横padding4/纵2 | 多行长项同排顶部对齐，短项下方允许大于4；不重叠命中区，不强制所有标签等高 |
| 异常状态样式 | 请求失败 padding28/gap12；未登录是系统大空态；其他卡内错误是 caption/footnote | 可按阻断程度建立 small/inline/page 三个角色，下一轮再改文案和组件 |
| 非主 token 留白 | 网格已收敛8/4；账号分隔线12+20+8=40；选择标记padding6、分组选择padding5/10等 | 有用途与来源才保留；无法解释的项进入视觉复查，不把扫描到的数字直接合并 |
| 数据表单行最小高 | .frame(minHeight:36/44) 不保证始终定高；长文案/Picker/原生 Toggle 会撑高 | 区分单行值、可换行错误、滑块双行与媒体卡；不要统一所有最小高为44 |
| 业务 sheet 残留 | 官方网页和主导航下载方式已全页；阅读设置、阅读内详情与系统分享保留sheet | 逐条区分“业务整页/临时设置/系统流程”；用户要全页的页面单独迁移，不能全局替换 sheet |
| 图形与目标重复限制 | 底栏 label 同字体但 icon占位16、压缩0.65；标题也有0.8压缩 | 场景验收要量字形与实际省略，不只比较 .font 字面值 |
| 横屏非等宽媒体 | 普通内容填安全区可用宽；阅读栏有最大460；详情横屏封面80×120 | 阅读控制栏限宽是用途例外，不能误报成横屏不铺满；媒体画面仍按全屏中心 |

## 已有运行证据与未知范围

本轮复用刚完成的模拟器结果，不重复声称全 App 真机覆盖。测试使用 iPhone 模拟器、固定 `.large` 和指定 QA 内容；网页为 mock，没有真实账号登录。

| 证据 | 已验证内容 | 边界 |
| --- | --- | --- |
| `QA/Simulator-20261111T072325Z.xcresult` | 两个登录入口全页；44行顶栏；顶底栏同宽；完成/关闭等宽同基线；网页下沿与底栏上沿不重叠；横竖屏；切栏输入不丢；关闭回原页；详情原页与下载选项往返 | 2个UI用例；不是所有业务页面、真实网站或真机 |
| `QA/Simulator-20261111T071545Z.xcresult` 的 SiteSessionV18Tests | 23个会话/请求/缓存相关单元用例通过，包括完整会话保存验证 | 同结果包内早期UI返回用例曾失败，已在后续结果包修复；不把该包整体写为全通过 |
| `QA/Simulator-20261111T070229Z.xcresult` 的成功用例 | 四个资料库空态居中；登录所需/会话失效；下载筛选；横屏可达 | 同包有早期spinner selector失败，已修正选择器；不是包整体通过 |
| `QA/Simulator-20261111T070450Z.xcresult` | 冷启动mini转圈（用例约束高≤24pt）、错误重试在内容区、横屏按钮可达；已有缓存静默刷新/失败保留；续页不重复 | 3个UI用例；明确按label定位转圈，避免父AX标识覆盖导致假阴性 |
| `QA/login-full-page-final/` | 最终登录入口 portrait/landscape截图，顶底栏与checkmark完成动作 | 白色网页为本机HTML测试，不能当成官方登录表单截图 |

尚未在本轮实测：所有页面浅色和深色全矩阵、真实官网登录/验证码、真实BT下载器接收、所有弹层键盘、安全区所有机型、VoiceOver连续流程、颜色对比度、所有长多语言标签。用户固定字号，因此没有把大字号适配作为本轮交付。布局迁移到其他系统版本仍需复测。

## 给另外两个 App 的共同经验

1. 记录四层：字形、可见面、触摸目标、外部占位。ExHViewer 的34面/44行/42外框/47底栏预留分别解决不同问题，不能只报“栏高44”。
2. 系统菜单、网页表单、UISlider thumb和SwiftUI按钮的尺寸来源不同。原生系统尺寸未知就写UNKNOWN；不要从截图或构造名推定。
3. 内外圆角按偏移推导：本 App R8控件、R12卡、R12栏、R14通用panel、R5 segment有各自语义。数字不同不是天然缺陷。
4. 转场和状态也属于规格：管理态底栏保持原槽位；有缓存刷新静默；空列表、登录异常、请求失败分别处理；弹窗迁移成全页必须检查返回层级和底栏遮挡。
5. 自动清单先排QA、模型和媒体计算，再做人工角色归类。源码命中、共享类型、页面模板、实际控件实例四种数量不能混用。
6. 动态字号是本 App 当前用户选择的例外，不应复制给另外两个 App；各自记录自己的约束。

维护工具校验已通过：4组嵌套字符串/raw string/嵌套注释样本，调用括号过滤、70个文件哈希与覆盖集合、全部调用来源行、24族来源和本文本地链接。校验记录在 `QA/ui-dimension-validation.json`；`--check` 同时检查本文SHA和源清单是否一致。

本文是源码/证据盘点及本 App 规格登记，不是政策或导航实现改动。本轮新建文档和扫描器，不安装、不发布、不推送，也不修改其他 App 的文件。

## 本轮收敛后的所有权

表单采用FormRowRole（36/footnote、44/subheadline）、FormGroup和FormValueMenuRow三个小职责；具体菜单项、草稿与持久状态仍由业务层维护。账号图标槽20、间隔8、水平内距12，分隔线leading由三者相加得到40。

FloatingFeedLayout的GeometryReader固定frame会绕过Root新增安全区，现由共同viewport在主栏上下文显式避让47；阅读内localPageChrome不扣。内容尾距12由页级唯一负责，GalleryRows不再另加；有实际续载状态的非空footer与卡片留8。下载版本查询flight归model，避免主详情task离场取消后子页一直checking。

运行证据：081528结果包9项中8通过，尾部旧选择器失败；082512网格截图实际显示末项，但该项未进入AX树，几何不采用最后hittable项推断。详细修复及验证边界见[ui-consolidation-plan.md](ui-consolidation-plan.md)。本轮只进行本地模拟器验证，未覆盖手机。

最终082919结果包3项全通过：网格末端边界与截图、历史/下载确定末项12pt、详情网页与下载往返、收藏管理横竖屏及右值菜单/单次确认。082648中两个登录入口与四空态/横屏空态也通过。081528已有8项成功；生产代码之后未变，后续仅修测试定位。各失败包仍为失败包，不合并写为全绿；详细结果见实施方案。

继续收敛：批量操作内部图标与文字复用iconLabelSpacing4；标签管理添加改本页模式，沿用36输入与建议行，本地过滤文本与新增输入独立保存。收藏分组改名采用36行内编辑与44×36保存/取消目标，不另开页；编辑未结束时禁止切组覆盖草稿。赞助信息采用紧凑36最小行与自然增长正文，不把44正文再叠上下8变成60；组内分隔、官方入口独立。

### 标签管理最终交互（覆盖前述添加模式描述）

顶栏中间为常用/屏蔽切换，右侧动作按选择显示+/−。空搜索为36高输入行，右X清空并收候选；有输入同卡展开建议。下方独立卡完整显示当前已有标签，不随搜索过滤。候选多选与已有标签多选互斥：选择任一组先清另一组；+批量添加、−批量移除，失败保留选择，成功清选择。query/namespace变化清候选，scope/session变化清两组，外部列表变更对已有选择取交集。该动作不负责焦点或导航。

收藏同步任务卡采用36行：作品标题、具体操作/状态、必要错误与整行检查/重试，Divider无额外上下间距。检查只读取站点结果，重试沿用原状态机；Change增加的展示字段不进入存储。赞助与权益同样紧凑信息行，长正文自然增长，外链入口font footnote。

最终112119包的两项标签UI通过，覆盖分类菜单移入搜索行后的artifact；111601的两个持久化/同步展示单元通过，原地改名和内容预览成功。独立审核看过当前源码与同步/赞助实际mock图，未见新的确定P1/P2。最新验证仍为模拟器，不等于真机或真实账号状态验收。

### 固定分栏外壳

连体选择器的44pt命中范围、34pt可见面和原有内距保持不变。FloatingHeaderSurface 固定背景/边框/外留白，仅内部控件按布局标识做0.18秒渐变；单双行转场沿用原尺寸动画。内容的边缘跟手切页由 HeaderSectionPager 共用，预览只读本机列表和快照，明确隔离覆盖页、管理和焦点状态。标签搜索36独立卡，分类菜单选项36/间隔4；结果与已有项各一个FormGroup。行内改名保存/取消统一36×36。

124标签后续：搜索/结果/已有列表各自FormGroup，搜索总高44=行36+上下4；分类触发器36/R8/4pt图文距；结果/已有标题行36，共用TagManagementGroup与resultRows；两个分栏独立查询和分类，切页预览读取目标草稿，收藏设置排除。


## 125版菜单与循环切页

App自有下拉和长按操作统一通过AppMenu/AppContextMenu展示：菜单项36pt、间隔及内边4pt、普通面R8、容器R12、最大宽220pt。表单右侧值的命中区36pt、可见面28pt，使用footnote；左侧说明仍只读正文色。菜单容器归页面外壳管理，避免系统popover玻璃外框覆盖自身圆角。菜单显示时暂停边缘切页；关闭后释放，选项禁用/选中/危险操作语义由业务保留。阅读内详情等独立模态有自己的host，普通页共享主host。

源码核对：14处AppMenu定义和3处AppContextMenu调用；App下无原生Menu/Picker/contextMenu调用。此口径不展开循环，也不表示所有控件均为选择器；系统确认、分享和文本编辑仍使用各自系统交互。

发现、资料库、常用/屏蔽分栏的边缘内划支持首尾循环，拖动目标只预览，不写历史或发起搜索。转场方向由手势步长记录；选择块在固定Canvas绘制首尾衔接，避免离屏副本扩大顶栏辅助功能边界。顶底栏不随内容位移。

最终候选运行证据：QA/Simulator-20261111T150104Z.xcresult，8项UI全部通过，包含首尾循环与栏边界、默认分组只读caption/右值、搜索菜单横竖屏、长按和短按互斥、键盘关闭后切页、详情菜单返回、阅读内详情模态菜单。其他用例和手机安装以本轮交付记录为准，不把该集合扩展为全App全场景验收。

补充回归：QA/menus-final-secondary.xcresult四项UI全部通过，覆盖收藏全部分组/末组选择与横竖屏、收藏排序持久、阅读器内收藏分组与取消、下载/稍后再读排序独立。QA/cyclic-paging-animation-final.xcresult首尾循环重跑通过并保留录屏；录屏抽帧显示指示块首尾衔接，主栏不随内容位移。独立Sol high只读复审当前源码与三张最终菜单截图，未发现新实质P1/P2。合计15项单元、12项不同UI成功，循环UI另重复一次用于录屏。


## 126版刷新与收藏缓存

最新/热门与收藏下拉刷新等待同一个pager任务结束，重复首屏仍合并请求，保留已有列表。收藏和浏览缓存各12项，共享原20MB上限；key/owner/分组/排序隔离不变，普通搜索条数不再挤占收藏。冷收藏首屏metadata每批完成即落盘；有旧快照时整页完成才替换，防止完整缓存降级。批量操作硬失效只删除当前站点，epoch仍阻止迟到写入。

GalleryRows在正常加载时不显示未核实标签长说明，不绕过屏蔽规则；空首屏/未知标签/分页复用250ms延时mini指示。批量刷新中/成功notice不再占顶栏，失败与结果待确认保留动作。

最终证据：QA/Simulator-20261111T152420Z.xcresult，27项单元+2项UI全部通过；QA/refresh-loading-status-final.xcresult，冷加载/请求失败位置与横屏1项UI通过。含首屏增量持久、旧完整快照保护、搜索缓存淘汰隔离、跨站点硬失效、断网保留、最新与热门下拉各一次请求且固定栏不移动。独立只读复审发现并修复完整快照被中间批次覆盖的问题，最终增量审核无新实质问题。


## 127版阅读器目标加载页

单页阅读的点击和拖动提交均立即进入目标页；图片/页面信息未就绪时使用ReaderLoadingPage黑底占位，页码、进度与当前目标一致。邻页未就绪也按手势位移跟随，小拖仍回弹；迟到图片只更新自己的呈现记录，不再自动改变页码。删除pendingPage、底部等待条和等待解码后再提交的分支，MediaCanvas保留自身解码状态与重试。

主要运行证据：QA/Simulator-20261111T153245Z.xcresult，ReaderV11的9项UI全部通过，覆盖慢图、0/2/6预载、缓存画布身份、四方向回弹/反向、跳页、点击与metadata失败。两张目标加载页实图经独立只读审核确认无旧图/等待条残留，加载信息不遮挡底栏；其余补充检查以最终交付记录为准。

补充最终证据：QA/Simulator-20261111T153742Z.xcresult，2项历史持久化/旧上下文保护单元和5项UI全部通过，涵盖慢图片点击后跳页、metadata到达、失败不自动重试且手动可重试、黑底页面中的详情与沉浸手势、方向切换。两组结果共14项不同UI通过；旧“留在当前页+等待浮条”断言已按新目标页语义更新。

## 128版固定栏与标签分组

详情两侧边缘内划仅移动内容，固定顶底栏；短拖回弹，提交后返回。菜单、切页预览和非活动场景暂停该手势，旋转取消在途拖动；反向速度参与提交判断。阅读底栏采用等大34pt方形端钮：左为当前/总页数上下分数式，右为更多，中间为进度；标题居中，右侧详情按钮打开保留主底栏的完整详情页，返回保留阅读位置。中间双击切换沉浸，边缘双击缩放。

标签匹配方式在窄控件中使用图标，展开菜单保留完整文案；常用标签与已选条件复用TagSectionCard，各自分组，44pt前缀列和44pt尾部操作列对齐，使用标准行高及统一内距。搜索返回使用独立34pt方形可见面/44pt命中区。页面背景延伸到安全区，浮动栏背后不保留白色带。

下拉刷新保留系统刷新触发及回位，使用顶栏下方实际布局空间显示居中小指示器，不以offset修饰掩盖错误坐标；原生指示透明避免双重显示，探针仅绑定本页祖先滚动视图并在退出时还原。

最终运行证据：QA/Simulator-20261111T162225Z.xcresult，9项全部通过（1项边缘返回策略单元，8项UI）；包含阅读详情返回与标签栏导航、横屏阅读栏、搜索返回与历史分支、刷新实际渲染坐标及2pt回位容差、详情内菜单。QA/Simulator-20261111T161638Z.xcresult的2项标签选择UI通过，验证常用/已选分组和规则菜单；该结果中另一项旧提示文案断言失败已改为真实查询状态验证，并在最终结果通过。QA/chrome128-refresh-verified.mp4抽帧核对最新/热门刷新指示器位于顶栏下方、列表回位。独立只读增量审核修复反向速度与异步取消窗口问题后无剩余实质问题。此范围不等同全App全场景验收。

## 129版阅读器返回与标签两端控件

阅读器使用窗口坐标20pt边缘判定：左边缘向右、右边缘向左跟手退出，短拖回弹；整个阅读页连同顶底栏移动，上一页的内存预览从黑底渐显，提交后关闭系统默认退场动画。窗口pan和SwiftUI观察手势协同，实际连续滚动pan让出优先级；返回过程中及结束的短保护区禁止尾随点击/翻页，取消恢复。预览仅绑定一次阅读呈现且不落盘；旋转后宽度不同不拉伸旧截图。详情页复用返回协调器但保留固定栏。左上使用返回箭头和同一退出路径。

中心单击以0.16s透明度动画显示/隐藏顶底栏，不改变图片位置；中心双击无操作，边缘双击缩放和长按沉浸保留。自动沉浸在活动和返回期间不倒计时。

筛选页和添加标签页共用TagListRowLabel/SearchTagRuleRow：两端44pt列、36pt命中区、28pt背景可见面和R8边框；分类、匹配方式、添加/已添加/移除均有相同背景面。常用与已选条件分别使用TagSectionCard且外距一致，动作按钮单独成行。

专项证据：QA/Simulator-20261111T170117Z.xcresult，3项UI全部通过；四方向短回弹/大退出与反复打开页码不变、左上返回、中心单击显隐/双击无操作、详情往返、连续横向两侧短拖画布坐标2pt回位和续读。QA/chrome129-reader-accepted.mp4已抽帧核对方向、整页栏移动和背景过渡。此前诊断抓到窗口UIScreenEdge在横屏不开始、SwiftUI手势竞争、尾随图片操作，均以对应回归重新验证；不以早期失败产物宣称通过。

后台结束顺序：先冻结/上报当前授权的结束状态，再释放短时执行授权；系统到期/取消仍可能被iOS标为不成功，App的waiting不能被解释成系统成功保证。手机只读快照查到7项下载（6完成，1在299/353页因图源-1001超时），不能将其与三条历史系统卡逐条对应。截图本身不是三个画廊失败的证据。

129补充最终验证：QA/Simulator-20261111T170734Z.xcresult的3项UI全部通过，覆盖统一window退出宽度（进入时断言extent等于真实App窗口宽度）、左右/横竖退出与续读页码、固定栏详情回弹及常用/已选独立卡片标题和行距对齐。QA/Simulator-20261111T170358Z.xcresult中33项单元及详情/规则菜单UI通过；其中旧“常用行紧接按钮4pt”的断言因独立卡片结构失效，已替换为两组标题-行间距一致的结构断言并在170734Z通过。分批共33项单元、6项不同UI成功；系统后台卡片真实生命周期不由fake授权单元测试证明。

129搜索/字号补充：所有发现/嵌套结果统一频道在上、搜索在下；有搜索条件时频道不绘制选中块和selected语义，点击最新直接写入导航binding以清条件，保留返回历史。原conditionSummary重复入口已移除。DetailSearchFlow用本地可写history状态，嵌套历史有同一关闭回调的标准方形返回。accountSubpageContent统一footnote，避免继承subheadline的操作文本与compact行/menu值字号不一致。

QA/Simulator-20261111T171737Z.xcresult三项UI通过（neutral频道/最新/恢复搜索、搜索导航前进返回、规则菜单）；QA/Simulator-20261111T171957Z.xcresult嵌套搜索→历史→最新→历史→原详情通过；QA/Simulator-20261111T171544Z.xcresult的收藏改名/直接收藏/完整管理页通过，字号实图已核对。QA/Simulator-20261111T171040Z.xcresult连续阅读最终复测通过。合并本轮不同用例共33项单元、10项UI成功，静态独立审核的问题均已对应复验，不扩称全App所有场景实机验收。

129已同bundle/team覆盖手机；QA/phone-129-preservation/preservation-result.json读回三份记录JSON字节一致、1952条离线目录记录路径/size一致。apps.json读回1.0.0(129)。自动启动被设备锁屏拒绝（Locked），不将安装读回当成已启动或用户手感验收。


## 130：共享外框与完整页面导航

最新/热门使用单行「最新／热门／历史＋搜索」，不再保留空的第二行；历史使用双行。搜索由独立 `GallerySearchFlow` 管理，编辑与结果共用单行栏，取消返回原频道，普通频道的数据与位置不被搜索替换。

`FloatingHeaderSurface` 是共用外框，页面只提交内容、单/双行状态和内容身份。`ChromeMotion` 集中结构240ms、内容160ms、局部控件180ms。外框顶边固定，只改变下沿；返回按钮占位从0到38pt，搜索框右边缘保持固定。减弱动态效果时直接呈现目标布局。

Reader设置迁移为完整页面，与Reader详情一样保留媒体实例，完整子页恢复主底栏；内部搜索统一宿主内overlay。生产sheet仅保留BT系统分享，Reader本身保留fullScreenCover；详见 [页面与Chrome状态图](chrome-state-map.md)。以上是实现约定，具体运行验证以对应结果包为准。


## 131：四频道搜索与记录按钮

131按用户纠正替换130发现入口：最新／热门／历史／搜索四等分，搜索无图标空槽。最新/热门单行，历史/搜索双行，外框仍42/80；首次搜索下方为空，提交后在本频道显示并记忆结果。最近搜索操作采用标准34×44目标、34可见方框，载入和存常用并列，文本左侧限宽两行。赞助内容使用标准footnote、84pt标题列、余宽内容列，行最小36且多行上下4pt。详见chrome-state-map。

## 132：唯一栏高与内容占位

Pinned页面不再各自测量完整header作为占位；宿主以同一个Animatable clearance驱动可见外框和所有进入/退出内容。单行50pt、双行88pt包含既有外距，外框可见42/80pt不变。普通返回和边缘返回均走该路径；底栏锚点不动。QA中间值采样仅挂载于隔离测试模式，不参与布局回写。旋转以宽度变化清理边缘手势；键盘只改变高度时保留手势。

## 133：阅读器输入响应

阅读器单击不再等待已废弃的双击手势：Reader传入allowsDoubleTapZoom=false；普通独立图片预览保留原双击缩放。图片与黑色加载页都只处理单击和长按，阅读缩放使用双指捏合。翻页最小意图24pt，普通门槛为视口10%且限制28–56pt；同向快速拖动可使用预测距离。无邻页的阻尼和0.18s松手动画不变，松手后的额外屏蔽窗口收至相同0.18s。

133下载阶段明确分为resolvingPage、queued、connecting、transferring、ready。获取下载名额后到响应头前为connecting，失败/取消保留最后真实阶段。没有据旧日志断言最近排队卡死已修；已有500条上限的无敏感诊断增加queue-start、transfer-start和response-headers，便于下一次同路径采样。

## 134：收藏操作、确认框和移除后的网格

详情与Reader设置共用favoriteToggleTitle和SiteSession.toggleSiteFavorite；显式toggle意图允许最新本地选择覆盖同作品的旧pending，独立于批量addIfMissing保持原分组的合同。pending增加可选optimisticToggle标识，旧文件缺省nil，无迁移或清空操作；成功状态与待同步状态继续分开。分组管理只留在资料库，批量底栏为取消收藏/下载/移到分组，删除旧的管理再展开一层路径。

移到分组的右上角为标准单行方形确认；左右边缘确认，未选直接返回不写入。搜索未填条件边缘也只返回；有条件才执行。提交被拒绝仍回弹保留输入。

确认弹窗参照HG ActionDialog的320×180居中卡片、16pt内距、标准字体、88×44两侧角色按钮，在唯一AppMenuHost上呈现；页面只声明绑定和动作，不建立第二个窗口或业务半页。批量及单个收藏管理共用该模板。菜单/确认期间的手势锁沿用原pager presentation id协议。

纯删除时重新计算双列分配，并与已有幸存列比较估算高差，采用较紧排的方案；删除伴随重排必须遵守新服务端顺序，不能回用旧列顺序。图片比例渐进更新和分页追加仍保持列稳定。正常不同封面比例导致的尾部差异不承诺强行等高。

边缘成功退出保留最终位移至真实卸载，预览不在willDisappear提前清理；实际退出使用显式无动画事务，取消路径仍回弹。QA录屏与模拟器通过不替代真机手感验收。拖动中当前/邻图就绪两项专项未复现用户报告的中途失去跟手，已沿既有无敏感500条诊断增加start/release/interrupted/viewport-reset，不宣称该问题已被证实修复。


135转场布局规约：单行占位50pt、双行88pt由`FeedChrome.headerClearance(twoRows:)`计算。页面/目标预览按自身布局使用该值，固定栏外框单独插值，不让后台页面继承前台的当前帧高度。对应状态与证据见`chrome-state-map.md`的135节。

## 表单对齐补充：边框与文字分开管理

`FormLayoutMetrics` 管理表单文字与输入列，不把 `panelSpacing` 当作文字内距。

| 角色 | 参数 | 用途 |
| --- | --- | --- |
| 组框至子行、子行之间 | `FeedChrome.panelSpacing` = 4 pt | 外框之间的缝隙，交给容器管理 |
| 行边框至正文、输入边框至输入文字 | `FormLayoutMetrics.textInset` = 8 pt | 同层文字起点保持一致 |
| 同行短标签列 | `FormLayoutMetrics.fieldLabelWidth` = 44 pt | 名称、作者、上传者、页数共用；最多三个字 |
| 标签列至输入框 | `FormLayoutMetrics.labelToFieldGap` = 4 pt | 标签与值的紧密关联 |

在同一层级比较标签与文字起点；嵌套分组只增加一层容器内距。页面不要用额外 leading padding 校正单个字段。名称输入行不再覆盖默认行内距为4pt，改为普通表单行的8pt。此补充已应用到搜索/组合编辑的共用输入行，不能据此宣称全App已逐页实测。

依据：Carbon要求标签和字段容器对齐网格、由父布局管理组间距；PatternFly要求标签方向一致，并用field group表达可折叠层级。引用原则，保留本App的紧凑尺寸与圆角，不照搬桌面24/32px组距或移动端上置标签。
- https://www.carbondesignsystem.com/building-blocks/core/components/form/guidelines
- https://www.carbondesignsystem.com/building-blocks/foundations/spacing/overview
- https://www.patternfly.org/components/forms/form/design-guidelines/
