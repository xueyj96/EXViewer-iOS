# ExViewer 工程架构

ExViewer 是支持 iOS 17 及以上版本的原生客户端。Xcode 的 App target 负责 SwiftUI、平台交互、会话与本机数据。`ExViewerCore` 是独立的 Swift Package，承载站点模型、查询、解析及规则。本文按代码职责描述依赖关系，控件规格和转场状态见 [App 设计准则](app-design-guidelines.md)、[控件与尺寸](ui-dimensions.md) 与 [页面和 Chrome 状态图](chrome-state-map.md)。

## 模块职责

| 模块 | 持有的状态与职责 | 代码入口 |
| --- | --- | --- |
| 应用外壳 | `ExViewerApp` 组装会话、资料库和下载管理器，并处理前后台与账号切换。`RootView` 管理主分栏、各自返回栈和详情发起的搜索覆盖层。`GalleryNavigation` 管理画廊路线。 | [应用入口](../App/ExViewerApp.swift) · [画廊导航](../App/GalleryNavigation.swift) · [详情搜索](../App/DetailTagSearch.swift) |
| 搜索与发现 | `SearchDraft` 持有待编辑条件。`DiscoveryNavigation` 持有已提交条件、结果路径、前进／返回和入口身份。`GalleryPager` 持有有序结果、游标、请求和错误状态。`FeedSnapshotCache` 持有账号与请求路径对应的列表快照。界面发出提交、刷新和预取意图。 | [搜索草稿](../App/SearchDraft.swift) · [发现导航](../App/DiscoveryNavigation.swift) · [分页](../App/GalleryPager.swift) · [列表快照](../App/FeedSnapshotCache.swift) |
| 阅读 | `ReaderView` 负责当前页、缩放、手势和呈现时机。`ReaderModel` 负责页表、页表分页、离线副本接入及续读恢复。`ReaderMediaStore` 负责当前页和预取窗口的请求生命周期。 | [阅读界面](../App/ReaderView.swift) · [页表](../App/ReaderModel.swift) · [阅读媒体任务](../App/ReaderMediaStore.swift) |
| 媒体与存储 | `PageMediaLoader` 串起普通图片页解析与图片文件获取。`MediaRepository` 统一持有浏览缓存、文件传输合并和清理，并串行调用 `ReaderResumeCache` 读写续读索引。`ReaderImagePipeline` 解码媒体，`MediaCanvas` 负责呈现。 | [媒体加载入口](../App/RequestFailure.swift) · [媒体仓库](../App/MediaRepository.swift) · [续读索引](../App/ReaderResumeCache.swift) · [图片解码](../App/ReaderImagePipeline.swift) · [呈现](../App/MediaCanvas.swift) |
| 会话与调度 | `SiteSession` 持有会话、授权范围、连接与在途请求合并，执行站点读写。`SiteRequestScheduler` 按请求优先级、并发容量和各类别发起间隔分配站点请求。图片传输容量由媒体侧调度。 | [站点会话](../App/SiteSession.swift) · [站点调度](../App/SiteRequestScheduler.swift) · [媒体优先级变动](../App/MediaRequestDemand.swift) |
| 资料库与收藏 | `LibraryStore` 持有账号下的阅读进度、常用组合、近期搜索和离线记录。`LibraryHistoryWriter` 串行写入阅读历史。`DownloadManager` 管理下载生命周期。站点收藏将浏览查询、显示状态、编辑意图和写入确认分别交由 `FavoriteBrowsingSession`、`SiteFavoriteCache`、编辑模型和已有提交服务负责。 | [资料库](../App/LibraryStore.swift) · [历史写入](../App/LibraryHistoryWriter.swift) · [下载](../App/Downloads.swift) · [收藏浏览](../App/FavoriteBrowsingSession.swift) · [收藏状态](../App/SiteFavoriteCache.swift) · [收藏编辑](../App/GalleryFavoriteEditorModel.swift) |
| 公用界面 | 共用组件负责栏尺寸、材质、菜单、Toast 和转场呈现。业务入口持有提交状态、导航意图与错误语义。手势期间的被动预览只消费当前快照，正式切换后由目标功能启动加载。 | [控件和反馈](../App/AppChrome.swift) · [菜单](../App/AppMenus.swift) · [分栏手势](../App/HeaderSectionPaging.swift) · [详情与阅读转场](../App/DetailEdgeBack.swift) |
| Core | 可测试的站点协议、查询与校验、HTML 和元数据解析、标签与评分规则。App 注入输入和环境，Core 返回值或结构化错误。 | [包清单](../Core/Package.swift) · [查询](../Core/Sources/ExViewerCore/Search.swift) · [HTML 解析](../Core/Sources/ExViewerCore/HTMLParser.swift) · [评分规则](../Core/Sources/ExViewerCore/GalleryRatingFilter.swift) |

## 依赖方向与隔离

- 界面向对应功能模型发出动作。功能模型协调已有服务并发布可以渲染的状态。会话、仓库和 Core 的输入输出使用业务值、文件引用或结构化错误。
- 需要同步决定当前界面状态的模型在 `MainActor` 上更新。页表请求和解码可异步执行，解析结果提交前核对会话代次、账号、任务或路由身份。导航提交与视觉过渡结束按各自状态处理。
- `MediaRepository`、`FeedSnapshotCache`、`LibraryHistoryWriter` 各自串行处理共享状态。磁盘索引由所属仓库统一写入，清理与写入通过同一所有者协调。一个消费者改优先级或取消时，由请求所有者决定共享工作是否继续。
- 可清理的媒体文件、续读索引和列表快照属于缓存。阅读进度、搜索记录、常用组合与离线副本分别持久化，缓存淘汰时仍可按用户记录重新加载。跨账号恢复按所有者隔离，完成回调还需通过当前会话身份检查。

## 代码评审检查

| 变更位置 | 优先检查 |
| --- | --- |
| 搜索与导航 | 草稿和已提交查询是否仍分离。来源页面、滚动锚点、结果和游标在返回时是否对应同一入口。 |
| 调度与缓存 | 服务是否仍是同一资源的唯一写入点。取消、重试、升级优先级是否可能重复发请求。缓存身份、过期、淘汰和清理是否与直接请求一致。 |
| 阅读与下载 | 当前页是否优先。同一文件的多个消费者能否独立离开。损坏、限流和账号切换时，已有进度和离线记录能否正确恢复。 |
| Core 与界面 | 查询、解析和筛选规则优先由 Core 的现有单测保护。交互和返回从正式入口跑 App 回归。新增 Swift 文件由 [工程生成脚本](../scripts/generate-project.py) 纳入对应 target。 |

[搜索与阅读加载设计](search-reader-performance.md)记录性能决策、失败回退与验证方式。
